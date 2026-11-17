import Combine
import Foundation
import UIKit

// Replay step bounds: each packet is broadcast for the recorded gap to the next one, clamped
// so that advertising it is practical.
private let replayMinStepMs: Int64 = 60
private let replayMaxStepMs: Int64 = 10_000
private let replayTailMs: Int64 = 800

private struct ReplayStep: Sendable {
    let hex: String
    let durationMs: Int
}

private enum ReplayPlan: Sendable {
    case noMatchingPackets
    case nothingToSend
    case steps([ReplayStep])
}

/// Filters a log and turns it into replay steps, oldest first. Not tied to the main actor, so
/// a large log is prepared on a background task.
private func makeReplayPlan(
    packets: [LoggedPacket],
    categories: Set<String>,
    address: String,
    bandOnly: Bool
) -> ReplayPlan {
    let wantedAddress = address.lowercased()
    var filtered: [LoggedPacket] = []
    for packet in packets {
        if !categories.isEmpty && !categories.contains(packet.category) { continue }
        if !address.isEmpty && packet.sourceAddress.lowercased() != wantedAddress { continue }
        if bandOnly && !packet.isBand { continue }
        filtered.append(packet)
    }
    if filtered.isEmpty { return .noMatchingPackets }

    // Oldest first; packets logged in the same millisecond keep their order in the file.
    let order: [Int] = Array(filtered.indices).sorted { (a: Int, b: Int) -> Bool in
        let ta: Int64 = filtered[a].timestampMs
        let tb: Int64 = filtered[b].timestampMs
        if ta != tb { return ta < tb }
        return a < b
    }

    var steps: [ReplayStep] = []
    steps.reserveCapacity(order.count)
    for position in 0..<order.count {
        let current = filtered[order[position]]
        let hex = HexUtils.canonicalHex(current.hex)
        if hex.isEmpty { continue }
        var gap: Int64 = replayTailMs
        if position < order.count - 1 {
            let next = filtered[order[position + 1]]
            let difference = next.timestampMs.subtractingReportingOverflow(current.timestampMs)
            gap = difference.overflow ? replayMaxStepMs : difference.partialValue
        }
        let clamped: Int64 = min(max(gap, replayMinStepMs), replayMaxStepMs)
        steps.append(ReplayStep(hex: hex, durationMs: Int(clamped)))
    }
    if steps.isEmpty { return .nothingToSend }
    return .steps(steps)
}

/// Everything that sends: single packets, response stacks, the TX and wand loops, the random
/// light show and log replay. An iPhone cannot broadcast these packets itself, so every send is
/// handed to the linked relay through `radioSend`, one at a time.
/// Port of `queueSend`, the radio queue, the loops and replay in Android's
/// `MagicMakerForegroundService.kt`, with the burst lengths of `MagicTransmitter.kt`.
@MainActor
final class TxEngine: ObservableObject {
    /// Status shown when a send was asked for with no relay linked.
    static let notLinkedStatus = "No relay linked — nothing sent"
    /// Status shown when the relay did not take a packet.
    static let sendFailedStatus = "Transmit failed — check relay"

    private static let minIntervalMs = 500
    private static let maxIntervalMs = 60_000
    /// A send the relay never answers is given up on this long after its burst should have ended.
    private static let sendWatchdogMs = 15_000

    /// True when a relay is linked and can take a packet.
    var radioReady: () -> Bool = { false }
    /// True while the relay streams the keep-awake ping; a single send then ends on that status.
    var keepAwakeOn: () -> Bool = { false }
    /// Send one packet for durationMs through the linked relay; completion(false) when it could not be sent.
    var radioSend: (_ hex: String, _ durationMs: Int, _ completion: @escaping (Bool) -> Void) -> Void = { _, _, done in done(false) }
    /// A replay step: the packet alone for exactly durationMs, with no wake preamble. Nil when the
    /// relay cannot do that; steps then go through `radioSend`.
    var radioBurst: ((_ hex: String, _ durationMs: Int, _ completion: @escaping (Bool) -> Void) -> Void)? = nil
    /// The palette index of a wand colour that is being sent.
    var onWandColor: ((Int) -> Void)?
    /// Whether the user has scanning switched on: "Scanning" or "Idle" once a replay ends, and
    /// the screen is kept awake while it is on.
    var scanWanted: () -> Bool = { true }

    @Published private(set) var status: String = "Idle"
    @Published private(set) var lastTransmitHex: String = ""
    /// The label given with the last single packet handed to `transmit`.
    @Published private(set) var lastTransmitLabel: String = ""
    @Published private(set) var isTransmitting: Bool = false
    @Published private(set) var txLoopEnabled: Bool = false
    @Published private(set) var txLoopPacketId: Int64 = -1
    @Published private(set) var txLoopIntervalMs: Int = 3000
    @Published private(set) var txLoopLabel: String = "none"
    @Published private(set) var starlightLoopEnabled: Bool = false
    @Published private(set) var starlightLoopPacketId: Int64 = -1
    @Published private(set) var starlightIntervalMs: Int = 3000
    @Published private(set) var starlightLoopLabel: String = "none"
    @Published private(set) var randomShowEnabled: Bool = false
    @Published private(set) var randomShowIntervalMs: Int = 3000
    @Published private(set) var randomShowLabel: String = ""
    @Published private(set) var replayActive: Bool = false
    @Published private(set) var replayProgress: Int = 0
    @Published private(set) var replayTotal: Int = 0
    @Published private(set) var replayLabel: String = ""

    private let store: MagicStore

    /// What a queued job is for, so a loop's unsent burst can be taken back out of the queue.
    private enum JobTag {
        case manual
        case stack
        case vibrate
        case txLoop
        case wandLoop
        case randomShow
        case replay
    }

    private struct RadioJob {
        let tag: JobTag
        let run: () -> Void
        /// Called when a manual send clears the job out of the queue before it ran.
        let onDropped: (() -> Void)?
    }
    private var txQueue: [RadioJob] = []
    private var txRunning = false
    /// Set by a manual send: a response stack that is running stops after the packet on air.
    private var cancelRequested = false

    // The one send that is waiting for the relay's answer.
    private var sendSerial = 0
    private var openSendSerial = 0
    private var sendWatchdog: Task<Void, Never>?

    private enum BurstKind {
        case starlight
        case ping
        case band
    }

    /// One repeating sender. `generation` changes whenever it is started or stopped, so work
    /// left over from an earlier run cannot keep it going; `jobPending` is true while one of
    /// its bursts is queued or on air, so it never has two at once.
    private struct LoopClock {
        var timer: Task<Void, Never>?
        var generation = 0
        var jobPending = false
    }
    private var txClock = LoopClock()
    private var starlightClock = LoopClock()
    private var randomClock = LoopClock()
    private var pendingRandomLabel = ""

    private var replaying = false
    private var replayLoading = false
    private var replayAbortLoad = false
    private var replayCancel = false
    private var replaySteps: [ReplayStep] = []
    private var replayRun = 0

    private var started = false
    private var idleTimerHeld = false
    private var idleTimerWasDisabled = false

    init(store: MagicStore) {
        self.store = store
        loadPrefs()
    }

    // MARK: - Preferences

    private func loadPrefs() {
        starlightLoopPacketId = TxEngine.longPref("starlight_loop_packet_id", fallback: -1)
        starlightIntervalMs = TxEngine.intervalPref("starlight_interval_ms")
        txLoopPacketId = TxEngine.longPref("tx_loop_packet_id", fallback: -1)
        txLoopIntervalMs = TxEngine.intervalPref("tx_loop_interval_ms")
        randomShowIntervalMs = TxEngine.intervalPref("random_show_interval_ms")
        refreshLoopLabels()
    }

    private func savePrefs() {
        let defaults = UserDefaults.standard
        defaults.set(starlightLoopEnabled, forKey: "starlight_loop_enabled")
        defaults.set(NSNumber(value: starlightLoopPacketId), forKey: "starlight_loop_packet_id")
        defaults.set(starlightIntervalMs, forKey: "starlight_interval_ms")
        defaults.set(txLoopEnabled, forKey: "tx_loop_enabled")
        defaults.set(NSNumber(value: txLoopPacketId), forKey: "tx_loop_packet_id")
        defaults.set(txLoopIntervalMs, forKey: "tx_loop_interval_ms")
        defaults.set(randomShowEnabled, forKey: "random_show_enabled")
        defaults.set(randomShowIntervalMs, forKey: "random_show_interval_ms")
    }

    private static func boolPref(_ key: String, fallback: Bool) -> Bool {
        let value: Any? = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return fallback
    }

    private static func longPref(_ key: String, fallback: Int64) -> Int64 {
        let value: Any? = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String, let parsed = Int64(text) { return parsed }
        return fallback
    }

    private static func intervalPref(_ key: String) -> Int {
        let stored: Int64 = longPref(key, fallback: 3000)
        return clampInterval(Int(clamping: stored))
    }

    private static func clampInterval(_ ms: Int) -> Int {
        min(max(ms, minIntervalMs), maxIntervalMs)
    }

    // MARK: - Start

    /// Picks up the loop that was running when the app was last open, as Android does when its
    /// service starts.
    func start() {
        if started { return }
        started = true
        // The status line reads "Scanning" from launch while the scan is on, as on Android.
        if status == "Idle" && scanWanted() {
            status = "Scanning"
        }
        refreshIdleTimer()
        let wandLoop = TxEngine.boolPref("starlight_loop_enabled", fallback: false)
        let txLoop = TxEngine.boolPref("tx_loop_enabled", fallback: false)
        let randomShow = TxEngine.boolPref("random_show_enabled", fallback: false)
        if !wandLoop && !txLoop && !randomShow { return }
        // Only one of them runs at a time.
        if wandLoop {
            startStarlightLoop()
        } else if txLoop {
            startTxLoop()
        } else {
            startRandomShow()
        }
        savePrefs()
        refreshLoopLabels()
        refreshIdleTimer()
    }

    // MARK: - Single sends

    /// One packet, ahead of anything queued. Its time on air follows the kind of packet and the
    /// timing settings.
    func transmit(hex: String, label: String) {
        let txHex = HexUtils.canonicalHex(hex)
        let starlight = HexUtils.isStarlightPacket(txHex)
        if starlight {
            let learned: Int? = MagicClassifier.starlightLearnColorIndex(txHex)
            let index: Int = learned ?? MagicClassifier.starlightColorIndex(txHex)
            onWandColor?(index)
        }
        if lastTransmitLabel != label { lastTransmitLabel = label }

        let doneStatus: String
        if txLoopEnabled {
            doneStatus = "TX loop"
        } else if randomShowEnabled {
            doneStatus = "Random show"
        } else if starlight && starlightLoopEnabled {
            doneStatus = "Wand loop"
        } else {
            doneStatus = "Scanning"
        }
        runRadioJob(
            .manual,
            status: starlight ? "Wand TX…" : "TX…",
            onCompleteStatus: keepAwakeOn() ? "Keeping band awake" : doneStatus,
            // A tap supersedes whatever is queued, so it goes out as soon as the air is free.
            preempt: true,
            send: { [weak self] done in
                guard let self else { return }
                self.sendPacket(txHex, durationMs: nil, done)
            },
            afterComplete: { [weak self] in
                guard let self else { return }
                // The show goes back on the clock, so a manual send never silently ends it.
                if self.randomShowEnabled {
                    self.scheduleRandomShowBurst(immediate: false)
                }
            }
        )
    }

    /// Several packets in order, as one job behind whatever is already queued. `label` is the
    /// status shown while they go out (an auto-response passes "Auto→<trigger>").
    func transmitSequence(_ hexes: [String], label: String) {
        var list: [String] = []
        for hex in hexes {
            let canonical = HexUtils.canonicalHex(hex)
            if !canonical.isEmpty { list.append(canonical) }
        }
        if list.isEmpty { return }
        // One stack waiting behind the send on air is enough. A trigger that keeps being heard
        // would otherwise queue responses faster than they can go out.
        if txQueue.contains(where: { $0.tag == .stack }) { return }
        let packets: [String] = list
        status = "\(label) (\(hexes.count))"
        runRadioJob(
            .stack,
            status: label,
            onCompleteStatus: "Scanning",
            send: { [weak self] done in
                guard let self else { return }
                self.sendSequence(packets, at: 0, firstFailure: nil, done)
            }
        )
    }

    func vibrate() {
        let hex = PacketBuilder.vibrateBand()
        runRadioJob(
            .vibrate,
            status: "Vibrate…",
            onCompleteStatus: "Scanning",
            send: { [weak self] done in
                guard let self else { return }
                self.sendPacket(hex, durationMs: nil, done)
            }
        )
    }

    private func sendSequence(
        _ list: [String],
        at index: Int,
        firstFailure: String?,
        _ done: @escaping (String?) -> Void
    ) {
        if cancelRequested || index >= list.count {
            done(firstFailure)
            return
        }
        sendPacket(list[index]) { [weak self] failure in
            guard let self else { return }
            self.sendSequence(list, at: index + 1, firstFailure: firstFailure ?? failure, done)
        }
    }

    // MARK: - TX loop

    func setTxLoop(enabled: Bool, packetId: Int64?, intervalMs: Int?) {
        if let packetId, txLoopPacketId != packetId {
            txLoopPacketId = packetId
        }
        if let intervalMs {
            let clamped = TxEngine.clampInterval(intervalMs)
            if txLoopIntervalMs != clamped { txLoopIntervalMs = clamped }
        }
        if enabled {
            stopStarlightLoop()
            stopRandomShow()
            startTxLoop()
        } else {
            stopTxLoop()
        }
        savePrefs()
        refreshLoopLabels()
        refreshIdleTimer()
    }

    private func txLoopHex() -> String? {
        if txLoopPacketId < 0 { return nil }
        guard let packet = store.findTransmitPacket(id: txLoopPacketId) else { return nil }
        return HexUtils.canonicalHex(packet.hex)
    }

    private func currentTxLoopLabel() -> String {
        if txLoopPacketId < 0 { return "none" }
        return store.findTransmitPacket(id: txLoopPacketId)?.label ?? "unknown"
    }

    private func startTxLoop() {
        stopTxLoopSchedule()
        if !txLoopEnabled { txLoopEnabled = true }
        txClock.generation += 1
        txClock.jobPending = false
        purgeQueued(.txLoop)
        scheduleTxBurst(immediate: true)
    }

    private func stopTxLoop() {
        if txLoopEnabled { txLoopEnabled = false }
        txClock.generation += 1
        txClock.jobPending = false
        purgeQueued(.txLoop)
        stopTxLoopSchedule()
    }

    private func stopTxLoopSchedule() {
        txClock.timer?.cancel()
        txClock.timer = nil
    }

    private func scheduleTxBurst(immediate: Bool) {
        stopTxLoopSchedule()
        let generation = txClock.generation
        let delayMs: Int = immediate ? 0 : txLoopIntervalMs
        txClock.timer = makeTimer(delayMs: delayMs) { [weak self] in
            self?.txLoopTick(generation)
        }
    }

    private func txLoopTick(_ generation: Int) {
        if !txLoopEnabled || generation != txClock.generation { return }
        // The burst already queued or on air re-arms the loop when it ends.
        if txClock.jobPending { return }
        guard let hex = txLoopHex() else {
            status = "TX loop: pick a library row"
            stopTxLoop()
            refreshLoopLabels()
            refreshIdleTimer()
            return
        }
        txClock.jobPending = true
        runRadioJob(
            .txLoop,
            status: "TX loop…",
            onCompleteStatus: "TX loop",
            onDropped: { [weak self] in
                self?.txLoopJobEnded(generation)
            },
            send: { [weak self] done in
                guard let self else { return }
                self.sendPacket(hex, durationMs: nil, done)
            },
            afterComplete: { [weak self] in
                self?.txLoopJobEnded(generation)
            }
        )
    }

    /// A loop burst finished, or a manual send cleared it out of the queue: the next one goes
    /// out one interval from now.
    private func txLoopJobEnded(_ generation: Int) {
        if generation != txClock.generation { return }
        txClock.jobPending = false
        refreshLoopLabels()
        if txLoopEnabled {
            scheduleTxBurst(immediate: false)
        }
    }

    // MARK: - Wand loop

    func setStarlightLoop(enabled: Bool, packetId: Int64?, intervalMs: Int?) {
        if let packetId, starlightLoopPacketId != packetId {
            starlightLoopPacketId = packetId
        }
        if let intervalMs {
            let clamped = TxEngine.clampInterval(intervalMs)
            if starlightIntervalMs != clamped { starlightIntervalMs = clamped }
        }
        if enabled {
            stopTxLoop()
            stopRandomShow()
            startStarlightLoop()
        } else {
            stopStarlightLoop()
        }
        savePrefs()
        refreshLoopLabels()
        refreshIdleTimer()
    }

    private func starlightLoopHex() -> String? {
        if starlightLoopPacketId < 0 { return nil }
        guard let packet = store.findLearnedStarlight(id: starlightLoopPacketId) else { return nil }
        return HexUtils.canonicalHex(packet.hex)
    }

    private func currentStarlightLoopLabel() -> String {
        if starlightLoopPacketId < 0 { return "none" }
        return store.findLearnedStarlight(id: starlightLoopPacketId)?.label ?? "unknown"
    }

    private func startStarlightLoop() {
        stopStarlightLoopSchedule()
        if !starlightLoopEnabled { starlightLoopEnabled = true }
        starlightClock.generation += 1
        starlightClock.jobPending = false
        purgeQueued(.wandLoop)
        scheduleStarlightBurst(immediate: true)
    }

    private func stopStarlightLoop() {
        if starlightLoopEnabled { starlightLoopEnabled = false }
        starlightClock.generation += 1
        starlightClock.jobPending = false
        purgeQueued(.wandLoop)
        stopStarlightLoopSchedule()
    }

    private func stopStarlightLoopSchedule() {
        starlightClock.timer?.cancel()
        starlightClock.timer = nil
    }

    private func scheduleStarlightBurst(immediate: Bool) {
        stopStarlightLoopSchedule()
        let generation = starlightClock.generation
        let delayMs: Int = immediate ? 0 : starlightIntervalMs
        starlightClock.timer = makeTimer(delayMs: delayMs) { [weak self] in
            self?.starlightLoopTick(generation)
        }
    }

    private func starlightLoopTick(_ generation: Int) {
        if !starlightLoopEnabled || generation != starlightClock.generation { return }
        if starlightClock.jobPending { return }
        guard let hex = starlightLoopHex() else {
            status = "Wand: pick a learned color"
            stopStarlightLoop()
            refreshLoopLabels()
            refreshIdleTimer()
            return
        }
        starlightClock.jobPending = true
        runRadioJob(
            .wandLoop,
            status: "Wand loop…",
            onCompleteStatus: "Wand loop",
            onDropped: { [weak self] in
                self?.starlightLoopJobEnded(generation)
            },
            send: { [weak self] done in
                guard let self else { return }
                self.sendPacket(hex, durationMs: nil, done)
            },
            afterComplete: { [weak self] in
                self?.starlightLoopJobEnded(generation)
            }
        )
    }

    private func starlightLoopJobEnded(_ generation: Int) {
        if generation != starlightClock.generation { return }
        starlightClock.jobPending = false
        refreshLoopLabels()
        if starlightLoopEnabled {
            scheduleStarlightBurst(immediate: false)
        }
    }

    private func refreshLoopLabels() {
        let txLabel = currentTxLoopLabel()
        if txLoopLabel != txLabel { txLoopLabel = txLabel }
        let wandLabel = currentStarlightLoopLabel()
        if starlightLoopLabel != wandLabel { starlightLoopLabel = wandLabel }
    }

    // MARK: - Random light show

    func setRandomShow(enabled: Bool, intervalMs: Int?) {
        if let intervalMs {
            let clamped = TxEngine.clampInterval(intervalMs)
            if randomShowIntervalMs != clamped { randomShowIntervalMs = clamped }
        }
        if enabled {
            stopStarlightLoop()
            stopTxLoop()
            startRandomShow()
        } else {
            stopRandomShow()
        }
        savePrefs()
        refreshLoopLabels()
        refreshIdleTimer()
    }

    private func startRandomShow() {
        stopRandomShowSchedule()
        if !randomShowEnabled { randomShowEnabled = true }
        randomClock.generation += 1
        randomClock.jobPending = false
        purgeQueued(.randomShow)
        scheduleRandomShowBurst(immediate: true)
    }

    private func stopRandomShow() {
        if randomShowEnabled { randomShowEnabled = false }
        randomClock.generation += 1
        randomClock.jobPending = false
        purgeQueued(.randomShow)
        stopRandomShowSchedule()
    }

    private func stopRandomShowSchedule() {
        randomClock.timer?.cancel()
        randomClock.timer = nil
    }

    /// A fresh surprise packet every burst, until stopped.
    private func scheduleRandomShowBurst(immediate: Bool) {
        stopRandomShowSchedule()
        let generation = randomClock.generation
        let delayMs: Int = immediate ? 0 : randomShowIntervalMs
        randomClock.timer = makeTimer(delayMs: delayMs) { [weak self] in
            self?.randomShowTick(generation)
        }
    }

    private func randomShowTick(_ generation: Int) {
        if !randomShowEnabled || generation != randomClock.generation { return }
        if randomClock.jobPending { return }
        let step = LabPacketBuilder.buildRandomShowStep()
        let label: String = step.label
        let hex: String = step.hex
        pendingRandomLabel = label
        randomClock.jobPending = true
        runRadioJob(
            .randomShow,
            status: "\(label)…",
            onCompleteStatus: "Random show",
            onDropped: { [weak self] in
                self?.randomShowJobEnded(generation)
            },
            send: { [weak self] done in
                guard let self else { return }
                self.sendPacket(hex, durationMs: nil, done)
            },
            afterComplete: { [weak self] in
                self?.randomShowJobEnded(generation)
            }
        )
    }

    private func randomShowJobEnded(_ generation: Int) {
        if generation != randomClock.generation { return }
        randomClock.jobPending = false
        if randomShowLabel != pendingRandomLabel { randomShowLabel = pendingRandomLabel }
        if randomShowEnabled {
            scheduleRandomShowBurst(immediate: false)
        }
    }

    // MARK: - Replay

    /// Sends a capture log again: each packet stays on air for the recorded gap to the next
    /// one. Only rows that pass the filters are sent (an empty filter passes everything).
    func startReplay(path: String, categories: Set<String>, address: String, bandOnly: Bool) {
        if replaying || replayLoading { return }
        replayLoading = true
        replayAbortLoad = false
        Task { @MainActor [weak self] in
            let plan: ReplayPlan = await Task.detached(priority: .userInitiated) { () -> ReplayPlan in
                SessionLogFiles.flushPendingRows()
                let packets: [LoggedPacket] = SessionLogFiles.readLog(path: path)
                return makeReplayPlan(
                    packets: packets,
                    categories: categories,
                    address: address,
                    bandOnly: bandOnly
                )
            }.value
            guard let self else { return }
            self.replayLoading = false
            self.beginReplay(plan, path: path)
        }
    }

    /// The replay ends once the packet on air has finished.
    func stopReplay() {
        if replayLoading { replayAbortLoad = true }
        if replaying { replayCancel = true }
    }

    private func beginReplay(_ plan: ReplayPlan, path: String) {
        if replayAbortLoad {
            replayAbortLoad = false
            return
        }
        switch plan {
        case .noMatchingPackets:
            status = "Replay: no matching packets"
        case .nothingToSend:
            status = "Replay: nothing to send"
        case .steps(let steps):
            var name = path
            if let slash = path.lastIndex(of: "/") {
                name = String(path[path.index(after: slash)...])
            }
            replaying = true
            replayCancel = false
            replaySteps = steps
            replayRun += 1
            replayActive = true
            replayTotal = steps.count
            replayProgress = 0
            replayLabel = name
            status = "Replaying"
            refreshIdleTimer()
            runReplayStep(0)
        }
    }

    private func runReplayStep(_ startIndex: Int) {
        // A packet too long to advertise is passed over, as the advertiser does.
        var cursor = startIndex
        while cursor < replaySteps.count,
              HexUtils.legacyAdvertiseRejectReason(replaySteps[cursor].hex) != nil {
            cursor += 1
        }
        let index = cursor
        if replayCancel || index >= replaySteps.count {
            finishReplay(failure: nil)
            return
        }
        if replayProgress != index + 1 { replayProgress = index + 1 }
        let step = replaySteps[index]
        let run = replayRun
        enqueueRadioWork(
            .replay,
            preempt: false,
            onDropped: { [weak self] in
                // A manual send cleared the queue: this step goes back in behind it.
                guard let self, self.replaying, self.replayRun == run else { return }
                self.runReplayStep(index)
            },
            { [weak self] in
                guard let self else { return }
                if !self.replaying || self.replayRun != run {
                    self.finishRadioWork()
                    return
                }
                if self.replayCancel {
                    self.finishReplay(failure: nil)
                    self.finishRadioWork()
                    return
                }
                if self.status != "Replaying" { self.status = "Replaying" }
                self.sendPacket(step.hex, durationMs: step.durationMs, raw: true) { [weak self] failure in
                    guard let self else { return }
                    if self.replaying && self.replayRun == run {
                        if let failure, failure == TxEngine.notLinkedStatus {
                            // No relay linked: the rest would fail the same way.
                            self.finishReplay(failure: failure)
                        } else {
                            // A failed burst is passed over, as the advertiser does.
                            self.runReplayStep(index + 1)
                        }
                    }
                    self.finishRadioWork()
                }
            }
        )
    }

    private func finishReplay(failure: String?) {
        if !replaying { return }
        replaying = false
        replayCancel = false
        replaySteps = []
        replayActive = false
        if let failure {
            status = failure
        } else {
            status = scanWanted() ? "Scanning" : "Idle"
        }
        refreshIdleTimer()
    }

    // MARK: - Stop

    /// Stops the loops, the show and the replay and empties the queue. A packet already handed
    /// to the relay still finishes its burst.
    func stopAll() {
        stopTxLoop()
        stopStarlightLoop()
        stopRandomShow()
        savePrefs()
        if replayLoading { replayAbortLoad = true }
        if replaying { replayCancel = true }
        cancelRequested = true
        let dropped = txQueue
        txQueue.removeAll()
        for job in dropped {
            job.onDropped?()
        }
        refreshIdleTimer()
        if !txRunning {
            status = scanWanted() ? "Scanning" : "Idle"
        }
    }

    // MARK: - Radio queue

    /// Sends are serialised: the one in progress finishes before the next starts. A manual
    /// send (`preempt`) drops the queued backlog and goes next.
    private func enqueueRadioWork(
        _ tag: JobTag,
        preempt: Bool,
        onDropped: (() -> Void)?,
        _ work: @escaping () -> Void
    ) {
        var dropped: [RadioJob] = []
        if preempt {
            dropped = txQueue
            txQueue.removeAll()
            cancelRequested = true
        }
        txQueue.append(RadioJob(tag: tag, run: work, onDropped: onDropped))
        // Told only now, so anything a dropped job puts back lands behind the new work.
        for job in dropped {
            job.onDropped?()
        }
        drainRadioQueue()
    }

    private func drainRadioQueue() {
        if txRunning || txQueue.isEmpty { return }
        txRunning = true
        cancelRequested = false
        if !isTransmitting { isTransmitting = true }
        let job = txQueue.removeFirst()
        job.run()
    }

    private func finishRadioWork() {
        txRunning = false
        drainRadioQueue()
        if !txRunning && isTransmitting { isTransmitting = false }
    }

    /// Takes a loop's unsent burst back out of the queue when the loop is stopped or restarted.
    private func purgeQueued(_ tag: JobTag) {
        txQueue.removeAll { $0.tag == tag }
    }

    /// Queues one radio job: `send` puts it on air and reports nil when it went out, or why it
    /// did not.
    private func runRadioJob(
        _ tag: JobTag,
        status startStatus: String,
        onCompleteStatus: String,
        preempt: Bool = false,
        onDropped: (() -> Void)? = nil,
        send: @escaping (_ onDone: @escaping (String?) -> Void) -> Void,
        afterComplete: (() -> Void)? = nil
    ) {
        enqueueRadioWork(tag, preempt: preempt, onDropped: onDropped) { [weak self] in
            guard let self else { return }
            self.status = startStatus
            send { [weak self] failure in
                guard let self else { return }
                self.status = failure ?? onCompleteStatus
                afterComplete?()
                self.finishRadioWork()
            }
        }
    }

    // MARK: - One packet

    private func burstKind(_ canonical: String) -> BurstKind {
        if HexUtils.isStarlightPacket(canonical) { return .starlight }
        if canonical == PacketBuilder.wakeupPing { return .ping }
        if let classified = MagicClassifier.classify(canonical), classified.typeInfo == "ping" {
            return .ping
        }
        return .band
    }

    /// Time on air: a wand colour gets the Starlight burst, a ping sent alone its fixed burst,
    /// every band command the command burst.
    private func burstMs(_ kind: BurstKind) -> Int {
        switch kind {
        case .starlight:
            return store.getStarlightBurstMs()
        case .ping:
            return TransmitTiming.pingBurstMs
        case .band:
            return store.getCommandBurstMs()
        }
    }

    /// How long the relay is still busy with a packet after the burst time it was given: the
    /// short settle it takes before every burst and, ahead of a band command, its own wake ping.
    private func relayLeadMs(_ kind: BurstKind) -> Int {
        let settleMs = Int(TransmitTiming.radioSettleMs)
        switch kind {
        case .band:
            return store.getWakeupPreambleMs() + settleMs
        case .starlight, .ping:
            return settleMs
        }
    }

    /// Hands one packet to the relay and waits for its burst to end. `done` always arrives on
    /// a later turn of the main actor: nil when the packet went out, otherwise why it did not.
    /// `fixedMs` puts the packet on air for exactly that long (replay); without it the time
    /// follows the kind of packet.
    private func sendPacket(_ hex: String, durationMs fixedMs: Int? = nil, raw: Bool = false, _ done: @escaping (String?) -> Void) {
        let canonical = HexUtils.canonicalHex(hex)
        if let reason = HexUtils.legacyAdvertiseRejectReason(canonical) {
            finishSend(done, failure: reason, afterMs: 0)
            return
        }
        if !radioReady() {
            finishSend(done, failure: TxEngine.notLinkedStatus, afterMs: 0)
            return
        }
        let kind = burstKind(canonical)
        let durationMs: Int = fixedMs ?? burstMs(kind)
        let holdMs: Int = fixedMs == nil ? relayLeadMs(kind) : 0
        if lastTransmitHex != canonical { lastTransmitHex = canonical }

        sendSerial += 1
        let serial = sendSerial
        openSendSerial = serial
        sendWatchdog?.cancel()
        let watchdogNs = UInt64(max(durationMs, 0) + TxEngine.sendWatchdogMs) * 1_000_000
        sendWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: watchdogNs)
            if Task.isCancelled { return }
            guard let self, self.openSendSerial == serial else { return }
            self.openSendSerial = 0
            done(TxEngine.sendFailedStatus)
        }
        let sender: (String, Int, @escaping (Bool) -> Void) -> Void
        if raw, let burst = radioBurst {
            sender = burst
        } else {
            sender = radioSend
        }
        sender(canonical, durationMs) { [weak self] sent in
            guard let self, self.openSendSerial == serial else { return }
            self.openSendSerial = 0
            self.sendWatchdog?.cancel()
            self.sendWatchdog = nil
            if sent {
                self.finishSend(done, failure: nil, afterMs: holdMs)
            } else {
                self.finishSend(done, failure: TxEngine.sendFailedStatus, afterMs: 0)
            }
        }
    }

    private func finishSend(_ done: @escaping (String?) -> Void, failure: String?, afterMs: Int) {
        let waitNs = UInt64(max(afterMs, 0)) * 1_000_000
        Task { @MainActor in
            if waitNs > 0 {
                try? await Task.sleep(nanoseconds: waitNs)
            }
            done(failure)
        }
    }

    // MARK: - Timers and screen lock

    private func makeTimer(delayMs: Int, _ fire: @escaping () -> Void) -> Task<Void, Never> {
        let waitNs = UInt64(max(delayMs, 0)) * 1_000_000
        return Task { @MainActor in
            if waitNs > 0 {
                try? await Task.sleep(nanoseconds: waitNs)
            }
            if Task.isCancelled { return }
            fire()
        }
    }

    /// The loops, the show and a replay are timers in this app, and the scan only hears adverts
    /// in the foreground, so the screen is kept from locking while scanning or while one of them
    /// runs, and the earlier setting is put back afterwards. Call again when the scan switch changes.
    func refreshIdleTimer() {
        let wanted = txLoopEnabled || starlightLoopEnabled || randomShowEnabled || replayActive || scanWanted()
        if wanted == idleTimerHeld { return }
        idleTimerHeld = wanted
        if wanted {
            idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
        }
    }
}
