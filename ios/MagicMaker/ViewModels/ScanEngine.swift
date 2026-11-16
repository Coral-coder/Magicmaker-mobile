import Combine
import Foundation

/// The iPhone's scan pipeline: every heard advertisement is classified, shown in the live feed,
/// learned into the library, written to the capture log and offered to the auto-response rules.
/// Port of `handleHeard` and the scan / log control in Android's `MagicMakerForegroundService.kt`,
/// and of the live feed, seen-address list and source statistics in `ServiceState.kt`.
@MainActor
final class ScanEngine: ObservableObject {
    private static let maxLive = 120
    private static let maxAddresses = 80
    private static let maxSources = 300
    private static let maxSourceStats = 500
    /// The state below is announced to the views at most this often while packets arrive.
    private static let publishIntervalMs: Int64 = 200
    /// The Sources list is rebuilt at most this often; it does not need per-packet freshness.
    private static let sourcesRebuildMs: Int64 = 500
    private static let heardUiIntervalMs: Int64 = 250
    private static let autoCooldownMs: Int64 = 800
    private static let priorityCategories: Set<String> = ["SHOW", "ANIMATION", "COLOR"]
    private static let memoLimit = 512

    /// The response stack of a triggered rule and the status text for it ("Auto→<trigger>").
    var onAutoResponses: ((_ hexes: [String], _ label: String) -> Void)?
    /// Asks for the local BLE scan to be started or stopped.
    var onScanWanted: ((Bool) -> Void)?
    /// The palette index of a wand colour that was just heard.
    var onWandColorHeard: ((Int) -> Void)?

    /// Goes up each time the state below is announced. Nothing else here is published: the
    /// lists and counters change on every heard packet.
    @Published private(set) var revision: Int = 0

    /// Unique by `dedupeKey`, newest first.
    private(set) var livePackets: [LivePacket] = []
    /// Every heard packet, newest first.
    private(set) var rawLivePackets: [LivePacket] = []
    private(set) var seenAddresses: [SeenAddress] = []
    private(set) var sources: [SourceStat] = []
    private(set) var packetsHeard: Int = 0
    private(set) var lightsHeard: Int = 0
    private(set) var lastHeardHex: String = ""
    private(set) var lastHeardLabel: String = ""
    /// The last heard packet that lights the band (see `BandEffectModel.lightsBand`).
    private(set) var lastLightHex: String = ""
    private(set) var lastLightLabel: String = ""
    /// The user wants scanning.
    private(set) var scanActive: Bool = true
    private(set) var recordSessionActive: Bool = false
    private(set) var activeSessionName: String = ""
    private(set) var autoEnabled: Bool = true
    private(set) var autoResponsesSent: Int = 0
    /// "Bluetooth ready", "Turn on Bluetooth", "Allow Bluetooth in Settings" or "Bluetooth unavailable".
    private(set) var bluetoothStatus: String = "Bluetooth unavailable"

    /// Scan filter: only real show-control packets reach the feed, the library and the log.
    var showControlOnly: Bool {
        get { store.getShowControlOnly() }
        set {
            store.saveShowControlOnly(newValue)
            publish(immediate: true)
        }
    }

    private let store: MagicStore
    private let location: LocationTracker

    /// Whether heard packets are written to the capture log.
    private var recordSession = true
    private var lastAutoAt: Int64 = 0
    private var lastHeardUiAt: Int64 = 0
    private var lastPublishMs: Int64 = 0
    private var publishPending = false
    private var lastFeedStampMs: Int64 = 0

    private struct SourceTally {
        var count: Int
        var bestRssi: Int
        var lastRssi: Int
        var lastSeenMs: Int64
        var categories: Set<String>
        /// Position in the order the sources were first heard; settles ties when sorting.
        let order: Int
    }
    private var sourceStats: [String: SourceTally] = [:]
    private var nextSourceOrder = 0
    private var cachedSources: [SourceStat] = []
    private var lastSourcesBuildMs: Int64 = 0

    /// What is worked out once per distinct packet. The same packet repeats many times a
    /// second while its source is in range, and all of this runs on the main actor.
    private struct FeedFacts {
        let canonical: String
        let classified: ClassifiedPacket?
        let dedupeKey: String
        let lights: Bool
    }
    private var feedMemo: [String: FeedFacts] = [:]
    private var showControlMemo: [String: Bool] = [:]

    init(store: MagicStore, location: LocationTracker) {
        self.store = store
        self.location = location
        loadPrefs()
    }

    // MARK: - Preferences

    private func loadPrefs() {
        autoEnabled = ScanEngine.boolPref("auto_enabled", fallback: true)
        recordSession = ScanEngine.boolPref("record_session", fallback: true)
        scanActive = ScanEngine.boolPref("scan_active", fallback: true)
    }

    private func savePrefs() {
        let defaults = UserDefaults.standard
        defaults.set(autoEnabled, forKey: "auto_enabled")
        defaults.set(recordSession, forKey: "record_session")
        defaults.set(scanActive, forKey: "scan_active")
    }

    private static func boolPref(_ key: String, fallback: Bool) -> Bool {
        let value: Any? = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return fallback
    }

    // MARK: - Scan and log control

    /// Applies the saved switches: starts the scan, and with it the capture log, if the user
    /// left scanning on.
    func start() {
        loadPrefs()
        recordSessionActive = recordSession
        if let newest = store.scanSessions.first {
            activeSessionName = newest.name
        }
        if scanActive {
            onScanWanted?(true)
            ensureLoggingStarted()
        } else {
            onScanWanted?(false)
        }
        publish(immediate: true)
    }

    func setScan(_ on: Bool) {
        scanActive = on
        savePrefs()
        if on {
            onScanWanted?(true)
            // Always-on capture while scanning.
            ensureLoggingStarted()
        } else {
            onScanWanted?(false)
            stopLogging()
        }
        publish(immediate: true)
    }

    func setRecording(_ on: Bool) {
        recordSession = on
        if on {
            let file = store.beginScanSession()
            recordSessionActive = true
            activeSessionName = file.lastPathComponent
        } else {
            let name: String? = store.endScanSession()
            recordSessionActive = false
            activeSessionName = name ?? ""
        }
        // Not saved by itself, as on Android: the choice is written with the next change to
        // the scan or auto switch, and starting a scan always turns logging back on.
        publish(immediate: true)
    }

    func setAuto(_ on: Bool) {
        autoEnabled = on
        savePrefs()
        publish(immediate: true)
    }

    func noteBluetoothStatus(_ status: String) {
        if bluetoothStatus == status { return }
        bluetoothStatus = status
        publish(immediate: true)
    }

    /// Makes sure a log session is open while scanning.
    private func ensureLoggingStarted() {
        recordSession = true
        if !store.sessionActive {
            let file = store.beginScanSession()
            activeSessionName = file.lastPathComponent
        }
        recordSessionActive = true
    }

    private func stopLogging() {
        let name: String? = store.endScanSession()
        recordSessionActive = false
        activeSessionName = name ?? ""
    }

    // MARK: - Heard packets

    /// One advertisement from the scanner. Runs for every advert, so it only does what cannot
    /// wait: the feed, the library and log (through the store), the counters and the rules.
    func handleHeard(hex: String, rssi: Int, address: String) {
        // With scanning switched off nothing is heard, as on Android where the scanner is stopped.
        if !scanActive { return }

        // Show-control filter: MagicBand and device noise and the stationary beacon families
        // are dropped (no live entry, no record) unless the user turned the filter off to
        // hunt raw packets. They are still counted.
        if store.getShowControlOnly() && !isShowControl(hex) {
            packetsHeard += 1
            publish()
            return
        }

        let facts = feedFacts(hex)
        let classified: ClassifiedPacket? = facts.classified
        let isBand = store.isBandAddress(address)
        let now = ScanEngine.nowMs()

        // The visible feed comes first, so nothing below can keep a heard packet off the screen.
        appendLive(
            facts: facts,
            label: classified?.label ?? "?",
            rssi: rssi,
            note: "Heard",
            address: address,
            isBand: isBand,
            now: now
        )

        let fix = location.latest
        let event: RecordEvent? = store.processHeardPacket(
            hex: hex,
            rssi: rssi,
            persistToSession: recordSession,
            address: address,
            lat: fix?.lat,
            lng: fix?.lng,
            accuracy: fix?.accuracy
        )

        // The Scan strip follows only packets that light the band. Pings, beacons and wand
        // colours arrive far more often than effects and would push the last real effect off it.
        let lights = facts.lights
        var lightLabel: String = classified?.label ?? "?"
        if let event {
            lightLabel = event.packet.label
        }

        packetsHeard += 1
        if lights {
            lastLightHex = hex
            lastLightLabel = lightLabel
            lightsHeard += 1
        }
        if now - lastHeardUiAt > ScanEngine.heardUiIntervalMs {
            lastHeardUiAt = now
            lastHeardHex = hex
            lastHeardLabel = lightLabel
            if let classified, classified.typeInfo == "starlight" {
                let learned: Int? = MagicClassifier.starlightLearnColorIndex(hex)
                let index: Int = learned ?? MagicClassifier.starlightColorIndex(facts.canonical)
                onWandColorHeard?(index)
            }
        }
        publish()

        guard autoEnabled, let trigger = classified else { return }
        if now - lastAutoAt < ScanEngine.autoCooldownMs { return }
        guard let responses = store.findAutoResponses(classified: trigger, rawHex: hex) else { return }
        lastAutoAt = now
        autoResponsesSent += 1
        publish(immediate: true)
        onAutoResponses?(responses, "Auto→\(trigger.label)")
    }

    private func isShowControl(_ hex: String) -> Bool {
        if let known = showControlMemo[hex] { return known }
        let value = MagicClassifier.isShowControl(hex)
        if showControlMemo.count >= ScanEngine.memoLimit {
            showControlMemo.removeAll(keepingCapacity: true)
        }
        showControlMemo[hex] = value
        return value
    }

    private func feedFacts(_ hex: String) -> FeedFacts {
        if let known = feedMemo[hex] { return known }
        let canonical = HexUtils.canonicalHex(hex)
        let classified: ClassifiedPacket? = MagicClassifier.classify(canonical)
        let facts = FeedFacts(
            canonical: canonical,
            classified: classified,
            dedupeKey: LivePacketSort.liveDedupeKey(hex: hex, classified: classified),
            lights: BandEffectModel.from(hex).lightsBand
        )
        if feedMemo.count >= ScanEngine.memoLimit {
            feedMemo.removeAll(keepingCapacity: true)
        }
        feedMemo[hex] = facts
        return facts
    }

    // MARK: - Live feed

    private func appendLive(
        facts: FeedFacts,
        label: String,
        rssi: Int,
        note: String,
        address: String,
        isBand: Bool,
        now: Int64
    ) {
        let classified: ClassifiedPacket? = facts.classified
        let dedupeKey = facts.dedupeKey
        // Adverts are delivered in bursts. Each feed row gets its own millisecond, so a row's
        // id (time plus key) stays unique and removing one raw row removes only that row.
        var stamp = now
        if stamp <= lastFeedStampMs && lastFeedStampMs - stamp < 5000 {
            stamp = lastFeedStampMs + 1
        }
        lastFeedStampMs = stamp
        let packet = LivePacket(
            hex: classified?.hex ?? facts.canonical,
            label: classified?.label ?? label,
            rssi: rssi,
            note: note,
            category: classified?.category ?? .unknown,
            typeInfo: classified?.typeInfo ?? "raw",
            dedupeKey: dedupeKey,
            timestampMs: stamp,
            address: address,
            isBand: isBand
        )

        if !address.isEmpty {
            noteSource(address: address, rssi: rssi, category: packet.category.rawValue, now: now)
            noteSeenAddress(address: address, rssi: rssi, now: now)
        }
        sources = sourcesThrottled(now)

        livePackets.removeAll { $0.dedupeKey == dedupeKey }
        livePackets.insert(packet, at: 0)
        if livePackets.count > ScanEngine.maxLive {
            livePackets.removeLast(livePackets.count - ScanEngine.maxLive)
        }
        rawLivePackets.insert(packet, at: 0)
        if rawLivePackets.count > ScanEngine.maxLive {
            rawLivePackets.removeLast(rawLivePackets.count - ScanEngine.maxLive)
        }
    }

    private func noteSeenAddress(address: String, rssi: Int, now: Int64) {
        var previousCount = 0
        if let index = seenAddresses.firstIndex(where: { $0.address == address }) {
            previousCount = seenAddresses[index].count
            seenAddresses.remove(at: index)
        }
        let updated = SeenAddress(address: address, rssi: rssi, lastSeenMs: now, count: previousCount + 1)
        // Most recently seen first. The entry just heard goes to the front unless the clock
        // went backwards and an older entry carries a later time.
        var position = 0
        while position < seenAddresses.count && seenAddresses[position].lastSeenMs > now {
            position += 1
        }
        seenAddresses.insert(updated, at: position)
        if seenAddresses.count > ScanEngine.maxAddresses {
            seenAddresses.removeLast(seenAddresses.count - ScanEngine.maxAddresses)
        }
    }

    // MARK: - Source statistics

    private func noteSource(address: String, rssi: Int, category: String, now: Int64) {
        var tally: SourceTally
        if let existing = sourceStats[address] {
            tally = existing
        } else {
            tally = SourceTally(
                count: 0,
                bestRssi: Int.min,
                lastRssi: rssi,
                lastSeenMs: now,
                categories: Set<String>(),
                order: nextSourceOrder
            )
            nextSourceOrder += 1
        }
        tally.count += 1
        tally.lastRssi = rssi
        if rssi > tally.bestRssi { tally.bestRssi = rssi }
        tally.lastSeenMs = now
        if !tally.categories.contains(category) {
            tally.categories.insert(category)
        }
        sourceStats[address] = tally
    }

    private func sourcesThrottled(_ now: Int64) -> [SourceStat] {
        if !cachedSources.isEmpty && now - lastSourcesBuildMs < ScanEngine.sourcesRebuildMs {
            return cachedSources
        }
        lastSourcesBuildMs = now
        trimSourceStats()
        cachedSources = buildSourcesList()
        return cachedSources
    }

    /// Rotating private addresses make this table grow without bound in a crowd, so the
    /// stalest entries are evicted.
    private func trimSourceStats() {
        let over = sourceStats.count - ScanEngine.maxSourceStats
        if over <= 0 { return }
        var entries: [(address: String, lastSeenMs: Int64, order: Int)] = []
        entries.reserveCapacity(sourceStats.count)
        for (address, tally) in sourceStats {
            entries.append((address: address, lastSeenMs: tally.lastSeenMs, order: tally.order))
        }
        entries.sort { (a: (address: String, lastSeenMs: Int64, order: Int), b: (address: String, lastSeenMs: Int64, order: Int)) -> Bool in
            if a.lastSeenMs != b.lastSeenMs { return a.lastSeenMs < b.lastSeenMs }
            return a.order < b.order
        }
        for entry in entries.prefix(over) {
            sourceStats[entry.address] = nil
        }
    }

    /// Sources that sent show control, animations or colours first, then the busiest, then the
    /// strongest; equal ones stay in the order they were first heard.
    private func buildSourcesList() -> [SourceStat] {
        var rows: [(stat: SourceStat, order: Int)] = []
        rows.reserveCapacity(sourceStats.count)
        for (address, tally) in sourceStats {
            let categories: [String] = tally.categories.sorted()
            var priority = false
            for name in categories where ScanEngine.priorityCategories.contains(name) {
                priority = true
            }
            let stat = SourceStat(
                address: address,
                count: tally.count,
                bestRssi: tally.bestRssi,
                lastRssi: tally.lastRssi,
                lastSeenMs: tally.lastSeenMs,
                priority: priority,
                categories: categories
            )
            rows.append((stat: stat, order: tally.order))
        }
        rows.sort { (a: (stat: SourceStat, order: Int), b: (stat: SourceStat, order: Int)) -> Bool in
            if a.stat.priority != b.stat.priority { return a.stat.priority }
            if a.stat.count != b.stat.count { return a.stat.count > b.stat.count }
            if a.stat.bestRssi != b.stat.bestRssi { return a.stat.bestRssi > b.stat.bestRssi }
            return a.order < b.order
        }
        var out: [SourceStat] = []
        out.reserveCapacity(min(rows.count, ScanEngine.maxSources))
        for row in rows.prefix(ScanEngine.maxSources) {
            out.append(row.stat)
        }
        return out
    }

    // MARK: - Feed editing

    func clearLive() {
        sourceStats.removeAll()
        cachedSources = []
        livePackets = []
        rawLivePackets = []
        sources = []
        publish(immediate: true)
    }

    /// Removes the unique row with this key and every raw row with it.
    func removeLive(dedupeKey: String) {
        livePackets.removeAll { $0.dedupeKey == dedupeKey }
        rawLivePackets.removeAll { $0.dedupeKey == dedupeKey }
        publish(immediate: true)
    }

    func removeRawLive(timestampMs: Int64, hex: String) {
        rawLivePackets.removeAll { $0.timestampMs == timestampMs && $0.hex == hex }
        publish(immediate: true)
    }

    // MARK: - Publishing

    /// Tells the views that something above changed: at once for a user action, otherwise at
    /// most every 200 ms, with the last change of a burst still announced.
    private func publish(immediate: Bool = false) {
        let now = ScanEngine.nowMs()
        let elapsed = now - lastPublishMs
        if immediate || elapsed >= ScanEngine.publishIntervalMs || elapsed < 0 {
            lastPublishMs = now
            revision &+= 1
            return
        }
        if publishPending { return }
        publishPending = true
        let waitMs: Int64 = max(ScanEngine.publishIntervalMs - elapsed, 1)
        let waitNs = UInt64(waitMs) * 1_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: waitNs)
            guard let self else { return }
            self.publishPending = false
            self.lastPublishMs = ScanEngine.nowMs()
            self.revision &+= 1
        }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
