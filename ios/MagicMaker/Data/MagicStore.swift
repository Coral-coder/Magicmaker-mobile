import Foundation

@MainActor
final class MagicStore: ObservableObject {
    @Published private(set) var presets: [MagicPacket] = []
    @Published private(set) var learnedColors: [MagicPacket] = []
    @Published private(set) var learnedLibrary: [MagicPacket] = []
    @Published private(set) var learnedRaw: [MagicPacket] = []
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var autoRules: [AutoResponseRule] = []
    @Published private(set) var scanSessions: [ScanSessionFile] = []

    private var nextPacketId: Int64 = 1
    private var nextRecordingId: Int64 = 1
    private var nextRuleId: Int64 = 1
    private var activeSessionURL: URL?
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    // Store writes run here, off the main thread, so a large save never janks the UI.
    private static let saveQueue = DispatchQueue(label: "com.magicmaker.store.save", qos: .utility)

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var storeURL: URL { documentsURL.appendingPathComponent("magicmaker_store.json") }
    private var sessionsDir: URL { documentsURL.appendingPathComponent("scan_sessions", isDirectory: true) }

    struct PersistedState: Codable {
        var presets: [MagicPacket]
        var learnedColors: [MagicPacket]
        var learnedLibrary: [MagicPacket]
        var learnedRaw: [MagicPacket]?
        var recordings: [Recording]
        var autoRules: [AutoResponseRule]
        var nextPacketId: Int64
        var nextRecordingId: Int64
        var nextRuleId: Int64
        var starlightSerial: String
        var labHex: String
        var labLabel: String?
    }

    var allLearnedPackets: [MagicPacket] {
        learnedColors + learnedLibrary + learnedRaw
    }

    private var isPrepared = false

    init() {}

    func prepareIfNeeded() {
        guard !isPrepared else { return }
        isPrepared = true
        try? fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        load()
        if presets.isEmpty {
            presets = PresetCatalog.allPresets().enumerated().map { offset, packet in
                var p = packet
                p.id = Int64(offset + 1)
                return p
            }
            nextPacketId = Int64(presets.count + 1)
            save()
        }
        refreshSessions()
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let state = try? decoder.decode(PersistedState.self, from: data) else { return }
        presets = state.presets
        learnedColors = state.learnedColors
        learnedLibrary = state.learnedLibrary
        learnedRaw = state.learnedRaw ?? []
        recordings = state.recordings
        autoRules = state.autoRules
        nextPacketId = state.nextPacketId
        nextRecordingId = state.nextRecordingId
        nextRuleId = state.nextRuleId
        UserDefaults.standard.set(state.starlightSerial, forKey: "starlight_serial")
        UserDefaults.standard.set(state.labHex, forKey: "lab_hex")
        UserDefaults.standard.set(state.labLabel ?? "", forKey: "lab_label")
    }

    func save() {
        let state = PersistedState(
            presets: presets,
            learnedColors: learnedColors,
            learnedLibrary: learnedLibrary,
            learnedRaw: learnedRaw,
            recordings: recordings,
            autoRules: autoRules,
            nextPacketId: nextPacketId,
            nextRecordingId: nextRecordingId,
            nextRuleId: nextRuleId,
            starlightSerial: getStarlightSerial(),
            labHex: getLabHex(),
            labLabel: getLabLabel()
        )
        // Encode the value-type snapshot here, then write on a background queue — the disk I/O
        // is what stalls the main thread, and atomic writes coalesce fine when they overlap.
        guard let data = try? encoder.encode(state) else { return }
        let url = storeURL
        Self.saveQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    func packets(for category: MagicCategory) -> [MagicPacket] {
        switch category {
        case .color: return learnedColors
        case .show: return presets.filter { $0.category == .show } + learnedLibrary.filter { $0.category == .show }
        case .animation: return presets.filter { $0.category == .animation } + learnedLibrary.filter { $0.category == .animation }
        case .unknown: return learnedRaw
        }
    }

    func getStarlightSerial() -> String {
        UserDefaults.standard.string(forKey: "starlight_serial") ?? StarlightSerial.defaultSerial
    }

    func getLabHex() -> String {
        UserDefaults.standard.string(forKey: "lab_hex") ?? PresetCatalog.wakeupPing
    }

    func getLabLabel() -> String {
        UserDefaults.standard.string(forKey: "lab_label") ?? ""
    }

    func saveLabHex(_ hex: String) {
        UserDefaults.standard.set(hex.uppercased(), forKey: "lab_hex")
        save()
    }

    func saveLabLabel(_ label: String) {
        UserDefaults.standard.set(label, forKey: "lab_label")
        save()
    }

    func loadIntoLab(hex: String, label: String = "") {
        saveLabHex(hex)
        saveLabLabel(label)
    }

    func renameLearnedRaw(id: Int64, label: String) {
        guard let i = learnedRaw.firstIndex(where: { $0.id == id }) else { return }
        learnedRaw[i].label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rawPacketLabel(hex: learnedRaw[i].hex)
            : label.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func applyLabLabelToMatchingRaw() {
        let hex = HexUtils.canonicalHex(getLabHex())
        guard let i = learnedRaw.firstIndex(where: { HexUtils.canonicalHex($0.hex) == hex }) else { return }
        let label = getLabLabel().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        learnedRaw[i].label = label
        save()
    }

    func processHeardPacket(hex: String, rssi: Int, persistToSession: Bool) -> RecordEvent? {
        let canonical = HexUtils.canonicalHex(hex)
        guard HexUtils.isDisneyBlePacket(canonical) else { return nil }

        let event: RecordEvent
        if let classified = MagicClassifier.classify(canonical) {
            event = addClassifiedToLibrary(classified, rawHex: hex, rssi: rssi)
            if persistToSession {
                persistRecording(classified, rssi: rssi, note: event.reason)
            }
        } else {
            event = hearRawPacket(canonical, rssi: rssi)
            if persistToSession {
                let pseudo = ClassifiedPacket(
                    hex: canonical,
                    label: event.packet.label,
                    category: .unknown,
                    typeInfo: "raw",
                    colors: "",
                    simKey: event.packet.simKey
                )
                persistRecording(pseudo, rssi: rssi, note: event.reason)
            }
        }
        return event
    }

    func tryAddRecorded(hex: String, rssi: Int) -> RecordEvent? {
        processHeardPacket(hex: hex, rssi: rssi, persistToSession: true)
    }

    private func addClassifiedToLibrary(_ classified: ClassifiedPacket, rawHex: String, rssi: Int) -> RecordEvent {
        switch classified.category {
        case .color:
            if classified.typeInfo == "starlight" {
                return addStarlightToLibrary(classified, rssi: rssi, rawHex: rawHex)
            }
            return addColorToLibrary(classified, rssi: rssi)
        case .show, .animation:
            return addShowAnimToLibrary(classified, rssi: rssi)
        case .unknown:
            return hearRawPacket(classified.hex, rssi: rssi, label: classified.label)
        }
    }

    /// Raw / unclassified packets appear in scan and record sessions only — not the library.
    private func hearRawPacket(_ hex: String, rssi: Int, label: String? = nil) -> RecordEvent {
        let canonical = HexUtils.canonicalHex(hex)
        let displayLabel = label ?? rawPacketLabel(hex: canonical)
        let packet = MagicPacket(
            hex: canonical,
            label: displayLabel,
            category: .unknown,
            typeInfo: "raw",
            colors: "",
            simKey: "RAW:\(canonical)",
            userRecorded: false,
            rssi: rssi
        )
        return RecordEvent(packet: packet, added: false, reason: "Heard raw (not saved to library)")
    }

    private func addStarlightToLibrary(_ classified: ClassifiedPacket, rssi: Int, rawHex: String) -> RecordEvent {
        let stored = libraryPacketFrom(classified, rawHex: rawHex)
        let key = MagicClassifier.libraryDedupeKey(classified)
        if learnedColors.contains(where: { MagicClassifier.libraryDedupeKey($0.toClassified()) == key }) {
            updateLearnedColor(stored, verified: true)
            return RecordEvent(packet: stored, added: false, reason: "Verified \(stored.colors)")
        }
        var packet = stored
        packet.id = nextPacketId
        nextPacketId += 1
        learnedColors.append(packet)
        save()
        return RecordEvent(packet: packet, added: true, reason: "Learned \(packet.colors) → Colors")
    }

    private func addColorToLibrary(_ classified: ClassifiedPacket, rssi: Int) -> RecordEvent {
        if isDuplicateOfPreset(classified) {
            return RecordEvent(packet: classified.toPacket(), added: false, reason: "Recorded (built-in color)")
        }
        let key = MagicClassifier.libraryDedupeKey(classified)
        if let existing = learnedColors.first(where: { MagicClassifier.libraryDedupeKey($0.toClassified()) == key }) {
            return RecordEvent(packet: existing, added: false, reason: "Verified \(classified.colors)")
        }
        var packet = classified.toPacket(userRecorded: true)
        packet.id = nextPacketId
        nextPacketId += 1
        learnedColors.append(packet)
        save()
        return RecordEvent(packet: packet, added: true, reason: "Learned \(packet.colors) → Colors")
    }

    private func addShowAnimToLibrary(_ classified: ClassifiedPacket, rssi: Int) -> RecordEvent {
        let key = MagicClassifier.libraryDedupeKey(classified)
        if let existing = learnedLibrary.first(where: { MagicClassifier.libraryDedupeKey($0.toClassified()) == key }) {
            let updated = MagicPacket(
                id: existing.id,
                hex: classified.hex,
                label: classified.label,
                category: existing.category,
                typeInfo: existing.typeInfo,
                colors: existing.colors,
                simKey: existing.simKey,
                userRecorded: existing.userRecorded,
                rssi: existing.rssi,
                wandVerified: existing.wandVerified
            )
            if updated.hex != existing.hex || updated.label != existing.label {
                if let i = learnedLibrary.firstIndex(where: { $0.id == existing.id }) {
                    learnedLibrary[i] = updated
                    learnedLibrary.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
                    save()
                }
            }
            return RecordEvent(packet: updated, added: false, reason: "Verified \(classified.label)")
        }
        var packet = classified.toPacket(userRecorded: true)
        packet.id = nextPacketId
        nextPacketId += 1
        learnedLibrary.append(packet)
        learnedLibrary.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        save()
        let section: String
        if classified.label.localizedCaseInsensitiveContains("Show Control") {
            section = "Control"
        } else if classified.category == .show {
            section = "Shows"
        } else {
            section = "Anim"
        }
        let note = isDuplicateOfPreset(classified)
            ? "Learned \(classified.label) → \(section) (heard confirmed)"
            : "Learned \(classified.label) → \(section)"
        return RecordEvent(packet: packet, added: true, reason: note)
    }

    private func rawPacketLabel(hex: String) -> String {
        let h = HexUtils.canonicalHex(hex)
        if h.count <= 20 { return "Raw: \(h)" }
        return "Raw: \(h.prefix(16))…\(h.suffix(4))"
    }

    private func isDuplicateOfPreset(_ classified: ClassifiedPacket) -> Bool {
        let key = MagicClassifier.libraryDedupeKey(classified)
        return presets.contains { MagicClassifier.libraryDedupeKey($0.toClassified()) == key }
    }

    private func libraryPacketFrom(_ classified: ClassifiedPacket, rawHex: String) -> MagicPacket {
        if classified.typeInfo == "starlight" {
            let canonical = HexUtils.canonicalHex(rawHex)
            let heard = StarlightSerial.extractSerial(canonical)
            if let heard, let valid = StarlightSerial.normalizeSerial(heard) {
                UserDefaults.standard.set(valid, forKey: "starlight_serial")
            }
            return MagicPacket(
                hex: classified.hex,
                label: classified.label,
                category: .color,
                typeInfo: "starlight",
                colors: classified.colors,
                simKey: classified.simKey,
                userRecorded: true,
                rssi: nil,
                wandVerified: heard != nil
            )
        }
        return classified.toPacket(userRecorded: true)
    }

    private func updateLearnedColor(_ packet: MagicPacket, verified: Bool) {
        if let i = learnedColors.firstIndex(where: { $0.simKey == packet.simKey }) {
            learnedColors[i].hex = packet.hex
            learnedColors[i].wandVerified = verified
            save()
        }
    }

    private func persistRecording(_ classified: ClassifiedPacket, rssi: Int, note: String) {
        if activeSessionURL == nil { _ = beginScanSession() }
        let rec = Recording(
            id: nextRecordingId,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            hex: classified.hex,
            rssi: rssi,
            label: classified.label,
            category: classified.category,
            typeInfo: classified.typeInfo,
            colors: classified.colors,
            libraryNote: note
        )
        nextRecordingId += 1
        recordings.insert(rec, at: 0)
        appendToSession(rec)
        save()
    }

    func findAutoResponse(classified: ClassifiedPacket, rawHex: String) -> String? {
        let enabled = autoRules.filter(\.enabled)
        let learned = allLearnedPackets
        for rule in enabled {
            if PacketPatterns.matchesTriggerId(rule.triggerPatternId, classified: classified, rawHex: rawHex, learned: learned) {
                return PacketPatterns.resolveResponseHex(rule: rule, learned: learned)
            }
        }
        return nil
    }

    func addAutoRule(name: String, triggerId: String, responseId: String, responseHex: String) {
        let rule = AutoResponseRule(id: nextRuleId, name: name, triggerPatternId: triggerId, responsePatternId: responseId, responseHex: responseHex, enabled: true)
        nextRuleId += 1
        autoRules.append(rule)
        save()
    }

    func setAutoRuleEnabled(id: Int64, enabled: Bool) {
        guard let i = autoRules.firstIndex(where: { $0.id == id }) else { return }
        guard autoRules[i].enabled != enabled else { return }
        autoRules[i].enabled = enabled
        save()
    }

    func deleteAutoRule(id: Int64) {
        autoRules.removeAll { $0.id == id }
        save()
    }

    func deleteLearnedColor(id: Int64) {
        learnedColors.removeAll { $0.id == id }
        save()
    }

    func deleteLearnedLibrary(id: Int64) {
        learnedLibrary.removeAll { $0.id == id }
        save()
    }

    func deleteLearnedRaw(id: Int64) {
        learnedRaw.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func beginScanSession() -> URL {
        let name = "scan_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).csv"
        let url = sessionsDir.appendingPathComponent(name)
        try? "timestamp_ms,hex,rssi,label,category,type_info,colors,note\n".write(to: url, atomically: true, encoding: .utf8)
        activeSessionURL = url
        refreshSessions()
        return url
    }

    @discardableResult
    func endScanSession() -> String? {
        defer { activeSessionURL = nil; refreshSessions() }
        return activeSessionURL?.lastPathComponent
    }

    func refreshSessions() {
        guard let files = try? fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            scanSessions = []
            return
        }
        scanSessions = files.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { ScanSessionFile(url: $0) }
    }

    private func appendToSession(_ rec: Recording) {
        guard let url = activeSessionURL else { return }
        let line = "\(rec.timestampMs),\(rec.hex),\(rec.rssi),\(rec.label),\(rec.category.rawValue),\(rec.typeInfo),\(rec.colors),\(rec.libraryNote)\n"
        if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
