import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Library file

/// One preference value, type-tagged the way Android's library file stores a SharedPreferences
/// entry: `b` Boolean, `i` Int, `l` Long, `f` Float, `s` String, `ss` string set.
struct PrefEntry: Codable, Equatable {
    var type: String
    var value: String?
    /// The members of a string set (`ss`). The JSON key is `set`.
    var strings: [String]?

    init(type: String, value: String? = nil, strings: [String]? = nil) {
        self.type = type
        self.value = value
        self.strings = strings
    }

    enum CodingKeys: String, CodingKey {
        case type
        case value
        case strings = "set"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag: String? = try? c.decodeIfPresent(String.self, forKey: .type)
        type = tag ?? "s"
        value = PrefEntry.scalarText(c)
        let members: [String]? = try? c.decodeIfPresent([String].self, forKey: .strings)
        strings = members
    }

    /// The value as text. Android always writes a string; a hand-edited file may not.
    private static func scalarText(_ c: KeyedDecodingContainer<CodingKeys>) -> String? {
        let text: String? = try? c.decodeIfPresent(String.self, forKey: .value)
        if let text { return text }
        let flag: Bool? = try? c.decodeIfPresent(Bool.self, forKey: .value)
        if let flag { return flag ? "true" : "false" }
        let whole: Int64? = try? c.decodeIfPresent(Int64.self, forKey: .value)
        if let whole { return "\(whole)" }
        let real: Double? = try? c.decodeIfPresent(Double.self, forKey: .value)
        if let real { return "\(real)" }
        return nil
    }
}

/// The library file. It has the same top-level keys as Android's `MagicStore.PersistedState`,
/// so either app reads a file written by the other.
struct StorePersistedState: Codable {
    var presets: [MagicPacket]
    var learnedColors: [MagicPacket]
    var learnedLibrary: [MagicPacket]
    var learnedRaw: [MagicPacket]
    /// Always written empty: the CSV session log is the durable record of what was heard.
    var recordings: [Recording]
    var autoRules: [AutoResponseRule]
    var nextPacketId: Int64
    var nextRecordingId: Int64
    var nextRuleId: Int64
    var starlightSerial: String
    var labHex: String
    var labLabel: String
    /// Every app preference, type-tagged, so the file restores the settings as well.
    var settings: [String: PrefEntry]?
    var uiSettings: [String: PrefEntry]?

    init(
        presets: [MagicPacket] = [],
        learnedColors: [MagicPacket] = [],
        learnedLibrary: [MagicPacket] = [],
        learnedRaw: [MagicPacket] = [],
        recordings: [Recording] = [],
        autoRules: [AutoResponseRule] = [],
        nextPacketId: Int64 = 1,
        nextRecordingId: Int64 = 1,
        nextRuleId: Int64 = 1,
        starlightSerial: String = StarlightSerial.defaultSerial,
        labHex: String = PacketBuilder.wakeupPing,
        labLabel: String = "",
        settings: [String: PrefEntry]? = nil,
        uiSettings: [String: PrefEntry]? = nil
    ) {
        self.presets = presets
        self.learnedColors = learnedColors
        self.learnedLibrary = learnedLibrary
        self.learnedRaw = learnedRaw
        self.recordings = recordings
        self.autoRules = autoRules
        self.nextPacketId = nextPacketId
        self.nextRecordingId = nextRecordingId
        self.nextRuleId = nextRuleId
        self.starlightSerial = starlightSerial
        self.labHex = labHex
        self.labLabel = labLabel
        self.settings = settings
        self.uiSettings = uiSettings
    }

    enum CodingKeys: String, CodingKey {
        case presets, learnedColors, learnedLibrary, learnedRaw, recordings, autoRules
        case nextPacketId, nextRecordingId, nextRuleId
        case starlightSerial, labHex, labLabel, settings, uiSettings
    }

    /// Tolerant on purpose: a missing key takes its default and a bad row is skipped, so an
    /// older iPhone file or an Android file still loads. It throws only when the text is not
    /// a library at all, and the caller then keeps what it has.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let libraryKeys: [CodingKeys] = [.presets, .learnedColors, .learnedLibrary, .learnedRaw, .autoRules]
        var hasLibrary = false
        for key in libraryKeys where c.contains(key) {
            hasLibrary = true
        }
        if !hasLibrary {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Not a MagicMaker library file"
            )
            throw DecodingError.dataCorrupted(context)
        }

        presets = try StorePersistedState.list(c, .presets, MagicPacket.self)
        learnedColors = try StorePersistedState.list(c, .learnedColors, MagicPacket.self)
        learnedLibrary = try StorePersistedState.list(c, .learnedLibrary, MagicPacket.self)
        learnedRaw = try StorePersistedState.list(c, .learnedRaw, MagicPacket.self)
        let heard: [Recording]? = try? StorePersistedState.list(c, .recordings, Recording.self)
        recordings = heard ?? []
        autoRules = try StorePersistedState.list(c, .autoRules, AutoResponseRule.self)

        nextPacketId = StorePersistedState.counter(c, .nextPacketId)
        nextRecordingId = StorePersistedState.counter(c, .nextRecordingId)
        nextRuleId = StorePersistedState.counter(c, .nextRuleId)

        let serial: String? = try? c.decodeIfPresent(String.self, forKey: .starlightSerial)
        starlightSerial = serial ?? StarlightSerial.defaultSerial
        let hex: String? = try? c.decodeIfPresent(String.self, forKey: .labHex)
        labHex = hex ?? PacketBuilder.wakeupPing
        let label: String? = try? c.decodeIfPresent(String.self, forKey: .labLabel)
        labLabel = label ?? ""

        let main: [String: PrefEntry]? = try? c.decodeIfPresent([String: PrefEntry].self, forKey: .settings)
        settings = main
        let ui: [String: PrefEntry]? = try? c.decodeIfPresent([String: PrefEntry].self, forKey: .uiSettings)
        uiSettings = ui
    }

    /// The rows under `key`. A missing or null key is an empty list; a row that does not decode
    /// is dropped; anything that is not a list is an error.
    private static func list<T: Decodable>(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ type: T.Type
    ) throws -> [T] {
        if !c.contains(key) { return [] }
        let isNull: Bool? = try? c.decodeNil(forKey: key)
        if isNull == true { return [] }
        let wrapped: LossyList<T> = try c.decode(LossyList<T>.self, forKey: key)
        return wrapped.items
    }

    /// An id counter: at least 1, whether the file holds a whole number or a decimal one.
    private static func counter(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64 {
        let whole: Int64? = try? c.decodeIfPresent(Int64.self, forKey: key)
        if let whole { return max(whole, 1) }
        let real: Double? = try? c.decodeIfPresent(Double.self, forKey: key)
        if let real, real.isFinite, real >= 1, real < 9e15 { return Int64(real) }
        return 1
    }
}

/// A JSON array read row by row: a row that fails to decode is skipped instead of failing
/// the whole list.
private struct LossyList<Element: Decodable>: Decodable {
    let items: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        if let count = container.count { out.reserveCapacity(count) }
        while !container.isAtEnd {
            let before = container.currentIndex
            let item: Element? = try? container.decode(Element.self)
            if let item {
                out.append(item)
                continue
            }
            // A failed decode leaves the cursor on the bad row; step over it.
            if container.currentIndex == before {
                _ = try? container.decode(JSONSkip.self)
            }
            if container.currentIndex == before { break }
        }
        items = out
    }
}

/// Decodes from any JSON value and keeps nothing.
private struct JSONSkip: Decodable {
    init(from decoder: Decoder) throws {}
}

private func encodeStoreState(_ state: StorePersistedState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(state)
}

private func decodeStoreState(_ raw: Data) throws -> StorePersistedState {
    let data = sanitizeNonFiniteJSON(raw)
    return try JSONDecoder().decode(StorePersistedState.self, from: data)
}

/// Runs on the save queue: encodes a value snapshot and replaces the store file.
private func writeStoreSnapshot(_ state: StorePersistedState, to url: URL) {
    do {
        let data = try encodeStoreState(state)
        try data.write(to: url, options: .atomic)
    } catch {
        CrashLog.record(error, "MagicStore.save")
    }
}

/// An Android-written file can hold bare `NaN` / `Infinity` tokens, which are not JSON.
/// Outside string literals they are replaced by `null`.
private func sanitizeNonFiniteJSON(_ data: Data) -> Data {
    let nanToken: [UInt8] = Array("NaN".utf8)
    let infinityToken: [UInt8] = Array("Infinity".utf8)
    let nullToken: [UInt8] = Array("null".utf8)
    let hasNaN = data.range(of: Data(nanToken)) != nil
    let hasInfinity = data.range(of: Data(infinityToken)) != nil
    if !hasNaN && !hasInfinity { return data }

    let bytes = [UInt8](data)
    let n = bytes.count
    var out: [UInt8] = []
    out.reserveCapacity(n)
    var inString = false
    var escaped = false
    var changed = false
    var i = 0
    while i < n {
        let b = bytes[i]
        if inString {
            out.append(b)
            if escaped {
                escaped = false
            } else if b == 0x5C {
                escaped = true
            } else if b == 0x22 {
                inString = false
            }
            i += 1
            continue
        }
        if b == 0x22 {
            inString = true
            out.append(b)
            i += 1
            continue
        }
        if b == 0x4E && jsonBytes(bytes, at: i, startWith: nanToken) {
            out.append(contentsOf: nullToken)
            i += nanToken.count
            changed = true
            continue
        }
        if b == 0x49 && jsonBytes(bytes, at: i, startWith: infinityToken) {
            out.append(contentsOf: nullToken)
            i += infinityToken.count
            changed = true
            continue
        }
        if b == 0x2D && jsonBytes(bytes, at: i + 1, startWith: infinityToken) {
            out.append(contentsOf: nullToken)
            i += infinityToken.count + 1
            changed = true
            continue
        }
        out.append(b)
        i += 1
    }
    return changed ? Data(out) : data
}

private func jsonBytes(_ bytes: [UInt8], at index: Int, startWith token: [UInt8]) -> Bool {
    if index < 0 || index + token.count > bytes.count { return false }
    var k = 0
    while k < token.count {
        if bytes[index + k] != token[k] { return false }
        k += 1
    }
    return true
}

// MARK: - Log files on disk

/// Where capture logs live and how they are read. Nothing here is tied to the main actor, so a
/// screen can list or read logs from a background task.
enum SessionLogFiles {
    struct Entry {
        let url: URL
        let sizeBytes: Int64
        let modifiedMs: Int64
    }

    static func documentsDirectory() -> URL {
        let found: [URL] = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return found.first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// New logs are written here.
    static func logsDirectory() -> URL {
        documentsDirectory().appendingPathComponent("logs", isDirectory: true)
    }

    /// Every place a log has ever been written, so captures made by older versions stay
    /// listed: the current directory, the old session directory (8 columns) and the old
    /// backup-scan directory (3 columns).
    static func allDirectories() -> [URL] {
        let docs = documentsDirectory()
        return [
            docs.appendingPathComponent("logs", isDirectory: true),
            docs.appendingPathComponent("scan_sessions", isDirectory: true),
            docs.appendingPathComponent("iscan_backup", isDirectory: true),
        ]
    }

    /// The csv files in every log directory, newest first.
    static func entries(includeSidecars: Bool) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let keySet: Set<URLResourceKey> = Set(keys)
        var found: [Entry] = []
        for dir in allDirectories() {
            let listed: [URL]? = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
            for url in listed ?? [] {
                let name = url.lastPathComponent
                if !name.hasSuffix(".csv") { continue }
                if !includeSidecars && SessionLog.isSidecar(name) { continue }
                let values: URLResourceValues? = try? url.resourceValues(forKeys: keySet)
                let size: Int = values?.fileSize ?? 0
                let modified: Date = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                let modifiedMs = Int64(modified.timeIntervalSince1970 * 1000)
                found.append(Entry(url: url, sizeBytes: Int64(size), modifiedMs: modifiedMs))
            }
        }
        // Newest first; files with the same time keep the order they were listed in.
        let numbered = Array(found.enumerated())
        let sorted = numbered.sorted { a, b in
            if a.element.modifiedMs != b.element.modifiedMs {
                return a.element.modifiedMs > b.element.modifiedMs
            }
            return a.offset < b.offset
        }
        return sorted.map { $0.element }
    }

    /// Number of packets in a log file (its lines, less the header).
    static func rowCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return 0 }
        return SessionLog.rowCount(data)
    }

    /// Chronological session logs from every directory, without the two sidecars, newest first.
    static func listLogs() -> [LogFile] {
        var out: [LogFile] = []
        for entry in entries(includeSidecars: false) {
            out.append(LogFile(
                path: entry.url.path,
                name: entry.url.lastPathComponent,
                sizeBytes: entry.sizeBytes,
                modifiedMs: entry.modifiedMs,
                packetCount: rowCount(at: entry.url)
            ))
        }
        return out
    }

    static func readLog(path: String) -> [LoggedPacket] {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return SessionLog.parseLog(data)
    }

    /// Position-tagged observations from every chronological log, for the map.
    static func forEachLoggedLocation(
        _ action: (_ lat: Double, _ lng: Double, _ rssi: Int, _ address: String, _ label: String, _ category: String) -> Void
    ) {
        for entry in entries(includeSidecars: false) {
            guard let data = try? Data(contentsOf: entry.url, options: .mappedIfSafe) else { continue }
            SessionLog.forEachLocation(in: [UInt8](data), action)
        }
    }

    /// Waits until every row handed to the writer so far is in its file.
    static func flushPendingRows() {
        storeLogWriter.flush()
    }
}

/// Appends session rows off the main thread through file handles that stay open for the
/// session. Everything it owns is touched only on its own queue.
private final class SessionLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.magicmaker.store.log", qos: .utility)
    private var sessionHandle: FileHandle?
    private var bandHandle: FileHandle?
    private var bandPath: String?

    /// Starts a session file with its header. The band-only file is created with its first row.
    func open(path: String, bandPath: String, header: String) {
        queue.sync {
            self.closeHandles()
            FileManager.default.createFile(atPath: path, contents: Data(header.utf8))
            let handle = FileHandle(forWritingAtPath: path)
            if let handle {
                _ = try? handle.seekToEnd()
            }
            self.sessionHandle = handle
            self.bandPath = bandPath
        }
    }

    func append(_ row: String, band: Bool, header: String) {
        queue.async {
            let data = Data(row.utf8)
            if let handle = self.sessionHandle {
                try? handle.write(contentsOf: data)
            }
            if band {
                self.appendToBand(data, header: header)
            }
        }
    }

    /// Closes the session files once everything queued has been written, then writes the
    /// unique-packet export if there is one.
    func close(uniquePath: String?, uniqueText: String?) {
        queue.sync {
            self.closeHandles()
            self.bandPath = nil
            if let path = uniquePath, let text = uniqueText {
                try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func appendToBand(_ data: Data, header: String) {
        if bandHandle == nil, let path = bandPath {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: Data(header.utf8))
            }
            let handle = FileHandle(forWritingAtPath: path)
            if let handle {
                _ = try? handle.seekToEnd()
            }
            bandHandle = handle
        }
        if let handle = bandHandle {
            try? handle.write(contentsOf: data)
        }
    }

    private func closeHandles() {
        if let handle = sessionHandle {
            try? handle.close()
        }
        if let handle = bandHandle {
            try? handle.close()
        }
        sessionHandle = nil
        bandHandle = nil
    }
}

private let storeLogWriter = SessionLogWriter()

// MARK: - Store

/// The iPhone's own packet library, preferences and capture logs.
/// Port of Android `data/MagicStore.kt`.
@MainActor
final class MagicStore: ObservableObject {
    typealias PersistedState = StorePersistedState

    /// Safety cap on auto-learned raw packets so a relentless flood cannot exhaust memory.
    private static let maxRawLibrary = 20000
    /// In memory only (the CSV log is the durable record), so it stays bounded.
    private static let maxRecordings = 500
    /// Raw packets are learned in floods; their saves are spaced at least this far apart.
    private static let rawSaveIntervalMs: Int64 = 2500
    /// Packets learned while scanning announce themselves at most this often.
    private static let revisionIntervalMs: Int64 = 1000
    /// A burst of edits waits this long and is then written once.
    private static let saveDebounceNs: UInt64 = 250_000_000

    /// Android keeps these in its second preferences file, so they go under `uiSettings`.
    private static let uiPrefKeys: Set<String> = [
        "scan_collapsed_sections", "tx_collapsed_sections", "lab_tx_settings_collapsed",
        "tx_loop_settings_collapsed", "band_menu_collapsed", "lab_extended",
    ]
    /// Android reads these with `getLong`, so they are tagged `l` whatever their size.
    private static let longPrefKeys: Set<String> = [
        "tx_loop_packet_id", "tx_loop_interval_ms", "starlight_loop_packet_id",
        "starlight_interval_ms", "random_show_interval_ms",
    ]

    /// Goes up whenever the library, the rules, a preference or the log list changes. The
    /// lists below are not published (they change on every heard packet); views read them
    /// again when this changes.
    @Published private(set) var revision: Int = 0

    private(set) var presets: [MagicPacket] = [] {
        didSet { transmitCache = nil }
    }
    private(set) var learnedColors: [MagicPacket] = [] {
        didSet {
            colorIndexValid = false
            transmitCache = nil
            learnedCache = nil
        }
    }
    private(set) var learnedLibrary: [MagicPacket] = [] {
        didSet {
            libraryIndexValid = false
            transmitCache = nil
            learnedCache = nil
        }
    }
    private(set) var learnedRaw: [MagicPacket] = [] {
        didSet {
            transmitCache = nil
            learnedCache = nil
        }
    }
    private(set) var recordings: [Recording] = []
    private(set) var autoRules: [AutoResponseRule] = []
    /// Every csv file in the log directories (sidecars included), newest first.
    private(set) var scanSessions: [ScanSessionFile] = []

    private var nextPacketId: Int64 = 1
    private var nextRecordingId: Int64 = 1
    private var nextRuleId: Int64 = 1
    private var activeSessionURL: URL?
    private var activeBandURL: URL?
    /// Running tally of the session's distinct packets, written out when the session ends.
    private var sessionUnique = SessionLog.UniqueTally()

    /// Canonical hex of every learnedRaw row — an O(1) duplicate check on the scan path.
    private var rawHexIndex = Set<String>()
    /// How many learnedRaw rows are band telemetry or pings; kept in step with `rawHexIndex`.
    private var rawNoiseCount = 0
    private var lastRawSaveMs: Int64 = 0
    private var rawSavePending = false

    // A packet repeats many times a second while its source is in range, and all of this runs
    // on the main actor. These lookups are rebuilt only after the list they index has changed.
    private var colorIndexValid = false
    private var colorIndexByHex: [String: Int] = [:]
    private var starlightHexes = Set<String>()
    private var starlightIndexBySimKey: [String: Int] = [:]
    private var libraryIndexValid = false
    private var libraryIndexByHex: [String: Int] = [:]
    private var transmitCache: [MagicPacket]?
    private var learnedCache: [MagicPacket]?

    // A bulk import sorts the library once at the end instead of after every row.
    private var deferLibrarySort = false
    private var librarySortPending = false

    private var bandCacheRaw: String?
    private var bandCacheList: [String] = []
    private var bandCacheSet = Set<String>()

    private struct LogCount {
        let sizeBytes: Int64
        let modifiedMs: Int64
        let rows: Int
    }
    private var logCountCache: [String: LogCount] = [:]

    private var saveScheduled = false
    private var writeInFlight = false
    private var changedWhileWriting = false
    /// Set when the store file could be neither read nor moved aside; it is then left alone.
    private var storeWriteBlocked = false

    private var lastRevisionMs: Int64 = 0
    private var revisionPending = false

    private var isPrepared = false
    /// Nothing is written before the store file has been read: an empty store must never
    /// replace a library that simply was not loaded yet.
    private var hasLoaded = false
    private var backgroundObserver: NSObjectProtocol?
    #if canImport(UIKit)
    /// Keeps the app running after it is backgrounded until the pending store write is on disk.
    private var saveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    // Store writes run here, off the main thread, so a large save never janks the UI.
    private static let saveQueue = DispatchQueue(label: "com.magicmaker.store.save", qos: .utility)

    private var storeURL: URL {
        SessionLogFiles.documentsDirectory().appendingPathComponent("magicmaker_store.json")
    }
    private var corruptStoreURL: URL {
        SessionLogFiles.documentsDirectory().appendingPathComponent("magicmaker_store.corrupt.json")
    }
    private var libraryFileURL: URL {
        SessionLogFiles.documentsDirectory().appendingPathComponent("magicmaker_library.json")
    }

    /// Where `exportLibrary()` writes; visible in the Files app.
    var libraryFilePath: String { libraryFileURL.path }

    init() {}

    // MARK: - Setup

    /// Loads the library, then seeds the built-in presets or merges in any new ones. Idempotent.
    func prepareIfNeeded() {
        if isPrepared { return }
        isPrepared = true
        keepPreUpgradeCopy()
        load()
        if presets.isEmpty {
            var seeded: [MagicPacket] = []
            for (index, packet) in PresetCatalog.asMagicPackets().enumerated() {
                var copy = packet
                copy.id = Int64(index + 1)
                seeded.append(copy)
            }
            presets = seeded
            nextPacketId = max(Int64(presets.count + 1), highestPacketId() + 1)
            save()
        } else {
            mergeBuiltInPresets()
        }
        refreshSessions()
        observeBackgrounding()
        bumpRevision()
    }

    private func mergeBuiltInPresets() {
        let built: [MagicPacket] = PresetCatalog.asMagicPackets()
        var knownHex = Set<String>()
        for packet in presets {
            knownHex.insert(packet.hex.uppercased())
        }
        var additions: [MagicPacket] = []
        for packet in built where !knownHex.contains(packet.hex.uppercased()) {
            var copy = packet
            copy.id = nextPacketId
            nextPacketId += 1
            additions.append(copy)
        }
        if additions.isEmpty { return }
        presets.append(contentsOf: additions)
        save()
    }

    /// The short wait that coalesces saves must never cost an edit: whatever is pending is
    /// written when the app leaves the foreground.
    private func observeBackgrounding() {
        if backgroundObserver != nil { return }
        let name = Notification.Name("UIApplicationDidEnterBackgroundNotification")
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushForBackground()
            }
        }
    }

    private func flushForBackground() {
        #if canImport(UIKit)
        if saveBackgroundTask == .invalid {
            // The handler runs on the main thread and must end the task before it returns.
            saveBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "store-save") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.endSaveBackgroundTask()
                }
            }
        }
        #endif
        // A raw packet learned in the last few seconds is still waiting for its spaced save.
        if rawSavePending { save() }
        flushSave()
        endSaveBackgroundTaskIfIdle()
    }

    /// Releases the background time once no write is running, queued or scheduled.
    private func endSaveBackgroundTaskIfIdle() {
        if writeInFlight || changedWhileWriting || saveScheduled { return }
        endSaveBackgroundTask()
    }

    private func endSaveBackgroundTask() {
        #if canImport(UIKit)
        if saveBackgroundTask == .invalid { return }
        let id: UIBackgroundTaskIdentifier = saveBackgroundTask
        saveBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(id)
        #endif
    }

    // MARK: - Derived lists

    var allLearnedPackets: [MagicPacket] {
        if let cached = learnedCache { return cached }
        var all: [MagicPacket] = []
        all.reserveCapacity(learnedColors.count + learnedLibrary.count + learnedRaw.count)
        all.append(contentsOf: learnedColors)
        all.append(contentsOf: learnedLibrary)
        all.append(contentsOf: learnedRaw)
        learnedCache = all
        return all
    }

    var customPresets: [MagicPacket] {
        presets.filter { $0.userRecorded }
    }

    /// Presets + learned library, deduped by canonical hex (presets win).
    func allTransmitPackets() -> [MagicPacket] {
        if let cached = transmitCache { return cached }
        var seen = Set<String>()
        var out: [MagicPacket] = []
        let lists: [[MagicPacket]] = [presets, learnedColors, learnedLibrary, learnedRaw]
        for list in lists {
            for packet in list {
                let key = Self.canonical(packet.hex)
                if seen.insert(key).inserted {
                    out.append(packet)
                }
            }
        }
        transmitCache = out
        return out
    }

    func packets(for category: MagicCategory) -> [MagicPacket] {
        switch category {
        case .color:
            return learnedColors
        case .show, .animation:
            var out: [MagicPacket] = presets.filter { $0.category == category }
            out.append(contentsOf: learnedLibrary.filter { $0.category == category })
            return out
        case .unknown:
            return learnedRaw
        }
    }

    func learnedStarlightPackets() -> [MagicPacket] {
        let starlight: [MagicPacket] = learnedColors.filter { $0.typeInfo == "starlight" }
        return Self.sortedByLabel(starlight, ignoringCase: false)
    }

    /// The second, generated wand type (CF0B code range) — kept separate from Starlight.
    func newWandPackets() -> [MagicPacket] {
        NewWandCatalog.packets
    }

    func findLearnedStarlight(id: Int64) -> MagicPacket? {
        if NewWandCatalog.isNewWandId(id) {
            return NewWandCatalog.byId(id)
        }
        return learnedColors.first(where: { $0.id == id && $0.typeInfo == "starlight" })
    }

    /// A packet from `allTransmitPackets()`, or a generated New Wand code, by id.
    func findTransmitPacket(id: Int64) -> MagicPacket? {
        if let found = allTransmitPackets().first(where: { $0.id == id }) {
            return found
        }
        if NewWandCatalog.isNewWandId(id) {
            return NewWandCatalog.byId(id)
        }
        return nil
    }

    // MARK: - Preferences

    func getStarlightSerial() -> String {
        defaults.string(forKey: "starlight_serial") ?? StarlightSerial.defaultSerial
    }

    func getLabHex() -> String {
        defaults.string(forKey: "lab_hex") ?? PacketBuilder.wakeupPing
    }

    func getLabLabel() -> String {
        defaults.string(forKey: "lab_label") ?? ""
    }

    // The Lab scratch hex and label live in the preferences only. Saving the library here
    // would rewrite the whole file on every byte the user edits in the inspector.
    func saveLabHex(_ hex: String) {
        defaults.set(hex.uppercased(), forKey: "lab_hex")
    }

    func saveLabLabel(_ label: String) {
        defaults.set(label, forKey: "lab_label")
    }

    func loadIntoLab(hex: String, label: String = "") {
        saveLabHex(hex)
        saveLabLabel(label)
    }

    func getWakeupPreambleMs() -> Int {
        let stored = intPref("wakeup_preamble_ms", fallback: TransmitTiming.defaultWakeupPreludeMs)
        return Self.clamp(stored, TransmitTiming.minWakeupPreludeMs, TransmitTiming.maxWakeupPreludeMs)
    }

    func saveWakeupPreambleMs(_ ms: Int) {
        let clamped = Self.clamp(ms, TransmitTiming.minWakeupPreludeMs, TransmitTiming.maxWakeupPreludeMs)
        defaults.set(clamped, forKey: "wakeup_preamble_ms")
        bumpRevision()
    }

    func getCommandBurstMs() -> Int {
        let stored = intPref("command_burst_ms", fallback: TransmitTiming.commandBurstMs)
        return Self.clamp(stored, TransmitTiming.minCommandBurstMs, TransmitTiming.maxCommandBurstMs)
    }

    func saveCommandBurstMs(_ ms: Int) {
        let clamped = Self.clamp(ms, TransmitTiming.minCommandBurstMs, TransmitTiming.maxCommandBurstMs)
        defaults.set(clamped, forKey: "command_burst_ms")
        bumpRevision()
    }

    func getStarlightBurstMs() -> Int {
        let stored = intPref("starlight_burst_ms", fallback: TransmitTiming.starlightBurstMs)
        return Self.clamp(stored, TransmitTiming.minStarlightBurstMs, TransmitTiming.maxStarlightBurstMs)
    }

    func saveStarlightBurstMs(_ ms: Int) {
        let clamped = Self.clamp(ms, TransmitTiming.minStarlightBurstMs, TransmitTiming.maxStarlightBurstMs)
        defaults.set(clamped, forKey: "starlight_burst_ms")
        bumpRevision()
    }

    /// Broadcast strength 0...3 = ultra low / low / medium / high advertise TX power. Lower is
    /// shorter range (fewer nearby bands react). Default high (3).
    func getTxPowerLevel() -> Int {
        Self.clamp(intPref("tx_power_level", fallback: 3), 0, 3)
    }

    func saveTxPowerLevel(_ level: Int) {
        defaults.set(Self.clamp(level, 0, 3), forKey: "tx_power_level")
        bumpRevision()
    }

    /// TX mode: true = 1:1 wake/command interleave (lighter, good in-park); false = sustained
    /// wake stream then command stream (stronger wake). Default sustained.
    func getTxInterleave() -> Bool {
        boolPref("tx_interleave", fallback: false)
    }

    func saveTxInterleave(_ on: Bool) {
        defaults.set(on, forKey: "tx_interleave")
        bumpRevision()
    }

    /// Scan filter: true = only surface real show-control packets (pings / E9 effects /
    /// starlight / show blocks), dropping MagicBand and device noise. Default on.
    func getShowControlOnly() -> Bool {
        boolPref("show_control_only", fallback: true)
    }

    func saveShowControlOnly(_ on: Bool) {
        defaults.set(on, forKey: "show_control_only")
        bumpRevision()
    }

    private func intPref(_ key: String, fallback: Int) -> Int {
        let value: Any? = defaults.object(forKey: key)
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let parsed = Int(text) { return parsed }
        return fallback
    }

    private func boolPref(_ key: String, fallback: Bool) -> Bool {
        let value: Any? = defaults.object(forKey: key)
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return fallback
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    // MARK: - Library editing

    func applyLabLabelToMatchingRaw() {
        let hex = HexUtils.canonicalHex(getLabHex())
        let tag = getLabLabel().trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.isEmpty { return }
        guard let index = learnedRaw.firstIndex(where: { Self.canonical($0.hex) == hex }) else { return }
        learnedRaw[index].label = tag
        save()
        bumpRevision()
    }

    /// Saves the Lab hex as a user preset, available in the TX tab and in the Auto response
    /// stack. Returns why it was refused, or nil when it was saved.
    @discardableResult
    func saveCustomPreset(label: String, hex: String) -> String? {
        let canonical = HexUtils.canonicalHex(hex)
        if let reason = HexUtils.legacyAdvertiseRejectReason(canonical) { return reason }
        if !HexUtils.isDisneyBlePacket(canonical) { return "Invalid Disney packet" }

        let classified: ClassifiedPacket? = MagicClassifier.classify(canonical)
        var displayLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if displayLabel.isEmpty {
            displayLabel = classified?.label ?? rawPacketLabel(canonical)
        }
        var packet: MagicPacket
        if let classified {
            packet = classified.toPacket(userRecorded: true)
            packet.label = displayLabel
        } else {
            packet = MagicPacket(
                hex: canonical,
                label: displayLabel,
                category: .unknown,
                typeInfo: "raw",
                colors: "",
                simKey: "USER:\(canonical)",
                userRecorded: true
            )
        }
        packet.id = nextPacketId
        nextPacketId += 1

        var kept: [MagicPacket] = presets.filter { !($0.userRecorded && Self.canonical($0.hex) == canonical) }
        kept.append(packet)
        presets = kept
        saveLabHex(canonical)
        saveLabLabel(displayLabel)
        save()
        bumpRevision()
        return nil
    }

    func deleteCustomPreset(id: Int64) {
        guard let target = presets.first(where: { $0.id == id && $0.userRecorded }) else { return }
        presets = presets.filter { $0.id != target.id }
        save()
        bumpRevision()
    }

    func recategorizePacket(id: Int64, category: MagicCategory) {
        let change: (inout MagicPacket) -> Void = { (packet: inout MagicPacket) in
            packet.category = category
        }
        if !applyToPacket(id: id, change) { return }
        save()
        bumpRevision()
    }

    /// Renames a captured or library packet. Only the label changes.
    func renamePacket(id: Int64, newLabel: String) {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { return }
        let change: (inout MagicPacket) -> Void = { (packet: inout MagicPacket) in
            packet.label = label
        }
        if !applyToPacket(id: id, change) { return }
        save()
        bumpRevision()
    }

    /// Applies `change` to the rows with this id in the first list that has one — colours,
    /// library, raw, then presets. False when no list has the id.
    private func applyToPacket(id: Int64, _ change: (inout MagicPacket) -> Void) -> Bool {
        if learnedColors.contains(where: { $0.id == id }) {
            learnedColors = Self.updating(learnedColors, id: id, change)
        } else if learnedLibrary.contains(where: { $0.id == id }) {
            learnedLibrary = Self.updating(learnedLibrary, id: id, change)
        } else if learnedRaw.contains(where: { $0.id == id }) {
            learnedRaw = Self.updating(learnedRaw, id: id, change)
        } else if presets.contains(where: { $0.id == id }) {
            presets = Self.updating(presets, id: id, change)
        } else {
            return false
        }
        return true
    }

    private static func updating(
        _ list: [MagicPacket], id: Int64, _ change: (inout MagicPacket) -> Void
    ) -> [MagicPacket] {
        var out = list
        for index in out.indices where out[index].id == id {
            change(&out[index])
        }
        return out
    }

    func deletePacketById(_ id: Int64) {
        if presets.contains(where: { $0.id == id && $0.userRecorded }) {
            deleteCustomPreset(id: id)
        } else if learnedColors.contains(where: { $0.id == id }) {
            deleteLearnedColor(id: id)
        } else if learnedLibrary.contains(where: { $0.id == id }) {
            deleteLearnedLibrary(id: id)
        } else if learnedRaw.contains(where: { $0.id == id }) {
            deleteLearnedRaw(id: id)
        }
    }

    func deleteLearnedColor(id: Int64) {
        learnedColors = learnedColors.filter { $0.id != id }
        save()
        bumpRevision()
    }

    func deleteLearnedLibrary(id: Int64) {
        learnedLibrary = learnedLibrary.filter { $0.id != id }
        save()
        bumpRevision()
    }

    func deleteLearnedRaw(id: Int64) {
        learnedRaw = learnedRaw.filter { $0.id != id }
        rebuildRawIndex()
        save()
        bumpRevision()
    }

    func clearLearnedStarlight() {
        learnedColors = learnedColors.filter { $0.typeInfo != "starlight" }
        save()
        bumpRevision()
    }

    /// Older name for relabelling a raw row; a blank label restores the generated one.
    func renameLearnedRaw(id: Int64, label: String) {
        guard let index = learnedRaw.firstIndex(where: { $0.id == id }) else { return }
        var newLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if newLabel.isEmpty {
            newLabel = MagicClassifier.rawLabel(learnedRaw[index].hex)
        }
        learnedRaw[index].label = newLabel
        save()
        bumpRevision()
    }

    /// Bulk-imports hexes (for example every distinct packet of a saved log): classified
    /// packets go to their own section, everything else to Unknown. The raw additions are
    /// batched (one save) so importing thousands of packets stays cheap. Returns the number
    /// of new entries.
    @discardableResult
    func importHexesToLibrary(_ hexes: [String]) -> Int {
        var existingRaw = Set<String>()
        for packet in learnedRaw {
            existingRaw.insert(Self.canonical(packet.hex))
        }
        var newRaw: [MagicPacket] = []
        var added = 0
        deferLibrarySort = true
        for h in hexes {
            let canonical = HexUtils.canonicalHex(h)
            if canonical.isEmpty { continue }
            if MagicClassifier.isLibraryNoise(canonical) { continue }
            let classified: ClassifiedPacket? = MagicClassifier.classify(canonical)
            if let classified, classified.category != .unknown {
                if addClassifiedToLibrary(classified, rawHex: canonical, rssi: 0).added {
                    added += 1
                }
            } else if existingRaw.insert(canonical).inserted {
                newRaw.append(MagicPacket(
                    id: nextPacketId,
                    hex: canonical,
                    label: MagicClassifier.rawLabel(canonical),
                    category: .unknown,
                    typeInfo: "raw",
                    simKey: "RAW:\(canonical)",
                    userRecorded: true
                ))
                nextPacketId += 1
                added += 1
            }
        }
        deferLibrarySort = false
        if librarySortPending {
            librarySortPending = false
            learnedLibrary = Self.sortedByLabel(learnedLibrary, ignoringCase: true)
        }
        if !newRaw.isEmpty {
            learnedRaw.append(contentsOf: newRaw)
        }
        if added > 0 {
            rebuildRawIndex()
            save()
            bumpRevision()
        }
        return added
    }

    // MARK: - My MagicBand (source tagging)
    // A phone only hears advertisements, which carry the address of their source and never a
    // destination, so packets can be tagged as coming FROM a chosen source. On the iPhone the
    // address is the CoreBluetooth peripheral identifier, which also changes when the band
    // rotates its private address, so the band may have to be picked again from the seen list.

    private func normalizeAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func refreshBandCache() {
        let raw: String = defaults.string(forKey: "band_addresses") ?? ""
        if raw == bandCacheRaw { return }
        var list: [String] = []
        var seen = Set<String>()
        for part in raw.components(separatedBy: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if seen.insert(trimmed).inserted {
                list.append(trimmed)
            }
        }
        bandCacheRaw = raw
        bandCacheList = list
        bandCacheSet = seen
    }

    func bandAddresses() -> Set<String> {
        refreshBandCache()
        return bandCacheSet
    }

    /// The tagged sources in the order they were tagged, for showing as a list.
    func bandAddressList() -> [String] {
        refreshBandCache()
        return bandCacheList
    }

    func isBandAddress(_ address: String) -> Bool {
        if address.isEmpty { return false }
        refreshBandCache()
        if bandCacheSet.isEmpty { return false }
        return bandCacheSet.contains(normalizeAddress(address))
    }

    func addBandAddress(_ address: String) {
        let a = normalizeAddress(address)
        if a.isEmpty { return }
        refreshBandCache()
        var list = bandCacheList
        if !bandCacheSet.contains(a) {
            list.append(a)
        }
        defaults.set(list.joined(separator: ","), forKey: "band_addresses")
        bumpRevision()
    }

    func removeBandAddress(_ address: String) {
        let a = normalizeAddress(address)
        refreshBandCache()
        let list: [String] = bandCacheList.filter { $0 != a }
        defaults.set(list.joined(separator: ","), forKey: "band_addresses")
        bumpRevision()
    }

    /// How many guest-band telemetry packets (8301C0… / 83010F11…) are sitting in the library.
    func savedBandCount() -> Int {
        rawNoiseCount
    }

    /// Manual bulk cleanup: removes all guest-band telemetry from the library. Returns the
    /// number of rows removed.
    @discardableResult
    func deleteSavedBands() -> Int {
        let before = learnedRaw.count
        let kept: [MagicPacket] = learnedRaw.filter { !MagicClassifier.isLibraryNoise($0.hex) }
        let removed = before - kept.count
        if removed > 0 {
            learnedRaw = kept
            rebuildRawIndex()
            save()
            bumpRevision()
        }
        return removed
    }

    // MARK: - Scan pipeline

    /// Classifies a heard packet, learns it into the library and, when asked, appends it to
    /// the session log. Nil when the hex is not a Disney packet.
    func processHeardPacket(
        hex: String,
        rssi: Int,
        persistToSession: Bool,
        address: String,
        lat: Double?,
        lng: Double?,
        accuracy: Double?
    ) -> RecordEvent? {
        let canonical = Self.canonical(hex)
        if !HexUtils.isDisneyBlePacket(canonical) { return nil }

        let classified: ClassifiedPacket? = MagicClassifier.classify(canonical)
        let event: RecordEvent
        if let classified {
            event = addClassifiedToLibrary(classified, rawHex: hex, rssi: rssi)
            if persistToSession {
                persistRecording(
                    classified, rssi: rssi, note: event.reason,
                    address: address, lat: lat, lng: lng, accuracy: accuracy
                )
            }
        } else {
            // Telemetry from a source the user tagged as their own band is whitelisted
            // (saved); every other guest band stays filtered out.
            let allowNoise = isBandAddress(address)
            event = hearRawPacket(canonical, rssi: rssi, label: nil, allowNoise: allowNoise)
            if persistToSession {
                let pseudo = ClassifiedPacket(
                    hex: canonical,
                    label: event.packet.label,
                    category: .unknown,
                    typeInfo: "raw",
                    colors: "",
                    simKey: event.packet.simKey
                )
                persistRecording(
                    pseudo, rssi: rssi, note: event.reason,
                    address: address, lat: lat, lng: lng, accuracy: accuracy
                )
            }
        }
        return event
    }

    /// Older entry point: no source address and no location.
    func processHeardPacket(hex: String, rssi: Int, persistToSession: Bool) -> RecordEvent? {
        processHeardPacket(
            hex: hex, rssi: rssi, persistToSession: persistToSession,
            address: "", lat: nil, lng: nil, accuracy: nil
        )
    }

    func tryAddRecorded(hex: String, rssi: Int) -> RecordEvent? {
        processHeardPacket(hex: hex, rssi: rssi, persistToSession: true)
    }

    private func addClassifiedToLibrary(_ classified: ClassifiedPacket, rawHex: String, rssi: Int) -> RecordEvent {
        // Pings are background noise — keep them live and in logs, but never in the library.
        if classified.typeInfo == "ping" {
            return RecordEvent(packet: classified.toPacket(), added: false, reason: "Ping (not saved)")
        }
        switch classified.category {
        case .color:
            if classified.typeInfo == "starlight" {
                return addStarlightToLibrary(classified, rssi: rssi, rawHex: rawHex)
            }
            return addColorToLibrary(classified, rssi: rssi)
        case .show, .animation:
            return addShowAnimToLibrary(classified, rssi: rssi)
        case .unknown:
            return hearRawPacket(classified.hex, rssi: rssi, label: classified.label, allowNoise: false)
        }
    }

    /// Raw / unclassified packets are saved by full hex — every distinct packet is kept
    /// (deduped only against the exact same hex). Learned on first sight; repeats are O(1)
    /// no-ops. Saves are coalesced and the count is capped so a flood cannot stall the app.
    private func hearRawPacket(_ hex: String, rssi: Int, label: String?, allowNoise: Bool) -> RecordEvent {
        let canonical = Self.canonical(hex)
        let displayLabel: String = label ?? MagicClassifier.rawLabel(canonical)
        let noise = MagicClassifier.isLibraryNoise(canonical)
        if !allowNoise && noise {
            let preview = rawPreview(canonical, label: displayLabel, rssi: rssi)
            return RecordEvent(packet: preview, added: false, reason: "Band/ping (not saved)")
        }
        if rawHexIndex.contains(canonical) {
            let preview = rawPreview(canonical, label: displayLabel, rssi: rssi)
            return RecordEvent(packet: preview, added: false, reason: "Known raw")
        }
        if learnedRaw.count >= Self.maxRawLibrary {
            let preview = rawPreview(canonical, label: displayLabel, rssi: rssi)
            return RecordEvent(packet: preview, added: false, reason: "Raw library full (\(Self.maxRawLibrary))")
        }
        let packet = MagicPacket(
            id: nextPacketId,
            hex: canonical,
            label: displayLabel,
            category: .unknown,
            typeInfo: "raw",
            simKey: "RAW:\(canonical)",
            userRecorded: false,
            rssi: rssi
        )
        nextPacketId += 1
        learnedRaw.append(packet)
        rawHexIndex.insert(canonical)
        if noise { rawNoiseCount += 1 }
        coalesceRawSave()
        bumpRevisionThrottled()
        return RecordEvent(packet: packet, added: true, reason: "Learned raw → Unknown")
    }

    private func rawPreview(_ canonical: String, label: String, rssi: Int) -> MagicPacket {
        MagicPacket(
            id: 0,
            hex: canonical,
            label: label,
            category: .unknown,
            typeInfo: "raw",
            simKey: "RAW:\(canonical)",
            userRecorded: false,
            rssi: rssi
        )
    }

    private func addStarlightToLibrary(_ classified: ClassifiedPacket, rssi: Int, rawHex: String) -> RecordEvent {
        let canonical = HexUtils.canonicalHex(rawHex)
        let stored = libraryPacketFrom(classified, rawHex: rawHex)
        if MagicClassifier.starlightLearnColorIndex(canonical) == nil {
            return RecordEvent(
                packet: stored, added: false,
                reason: "Heard \(stored.colors) (unrecognized wand format)"
            )
        }
        let key = Self.canonical(stored.hex)
        ensureColorIndex()
        if starlightHexes.contains(key) {
            updateLearnedColor(stored, verified: true)
            return RecordEvent(packet: stored, added: false, reason: "Verified \(stored.colors)")
        }
        var packet = stored
        packet.id = nextPacketId
        nextPacketId += 1
        learnedColors.append(packet)
        save()
        bumpRevisionThrottled()
        return RecordEvent(packet: packet, added: true, reason: "Learned \(packet.colors) → Wand")
    }

    private func addColorToLibrary(_ classified: ClassifiedPacket, rssi: Int) -> RecordEvent {
        if isDuplicateOfPreset(classified) {
            return RecordEvent(packet: classified.toPacket(), added: false, reason: "Recorded (built-in color)")
        }
        let key = Self.canonical(classified.hex)
        ensureColorIndex()
        if let index = colorIndexByHex[key], index < learnedColors.count {
            return RecordEvent(packet: learnedColors[index], added: false, reason: "Verified \(classified.colors)")
        }
        var packet = classified.toPacket(userRecorded: true)
        packet.id = nextPacketId
        nextPacketId += 1
        learnedColors.append(packet)
        save()
        bumpRevisionThrottled()
        return RecordEvent(packet: packet, added: true, reason: "Learned \(packet.colors) → Colors")
    }

    private func addShowAnimToLibrary(_ classified: ClassifiedPacket, rssi: Int) -> RecordEvent {
        // Per distinct packet: keep every identified packet whose exact hex has not been seen,
        // rather than collapsing by function code.
        let key = Self.canonical(classified.hex)
        ensureLibraryIndex()
        if let index = libraryIndexByHex[key], index < learnedLibrary.count {
            let existing = learnedLibrary[index]
            var updated = existing
            updated.hex = classified.hex
            updated.label = classified.label
            if updated != existing {
                learnedLibrary = Self.updating(learnedLibrary, id: existing.id) { (packet: inout MagicPacket) in
                    packet = updated
                }
                resortLibrary()
                save()
                bumpRevisionThrottled()
            }
            return RecordEvent(packet: updated, added: false, reason: "Verified \(classified.label)")
        }
        var packet = classified.toPacket(userRecorded: true)
        packet.id = nextPacketId
        nextPacketId += 1
        learnedLibrary.append(packet)
        resortLibrary()
        save()
        bumpRevisionThrottled()

        let section: String
        if classified.label.range(of: "Show Control", options: .caseInsensitive) != nil {
            section = "Control"
        } else if classified.category == .show {
            section = "Shows"
        } else {
            section = "Anim"
        }
        var note = "Learned \(classified.label) → \(section)"
        if isDuplicateOfPreset(classified) {
            note += " (heard confirmed)"
        }
        return RecordEvent(packet: packet, added: true, reason: note)
    }

    /// Fallback label for a preset saved without one.
    private func rawPacketLabel(_ hex: String) -> String {
        let h = HexUtils.canonicalHex(hex)
        if h.count <= 20 { return "Raw: \(h)" }
        let head = String(h.prefix(16))
        let tail = String(h.suffix(4))
        return "Raw: \(head)…\(tail)"
    }

    private func isDuplicateOfPreset(_ classified: ClassifiedPacket) -> Bool {
        let key = MagicClassifier.libraryDedupeKey(classified)
        return presets.contains { MagicClassifier.libraryDedupeKey($0.toClassified()) == key }
    }

    private func libraryPacketFrom(_ classified: ClassifiedPacket, rawHex: String) -> MagicPacket {
        if classified.typeInfo == "starlight" {
            let canonical = HexUtils.canonicalHex(rawHex)
            let heard: String? = StarlightSerial.extractSerial(canonical)
            if let heard, let valid = StarlightSerial.normalizeSerial(heard) {
                if defaults.string(forKey: "starlight_serial") != valid {
                    defaults.set(valid, forKey: "starlight_serial")
                }
            }
            return MagicPacket(
                hex: classified.hex,
                label: classified.label,
                category: .color,
                typeInfo: "starlight",
                colors: classified.colors,
                simKey: classified.simKey,
                userRecorded: true,
                wandVerified: heard != nil
            )
        }
        return classified.toPacket(userRecorded: true)
    }

    private func updateLearnedColor(_ packet: MagicPacket, verified: Bool) {
        ensureColorIndex()
        guard let index = starlightIndexBySimKey[packet.simKey], index < learnedColors.count else { return }
        let existing = learnedColors[index]
        var updated = existing
        updated.hex = packet.hex
        updated.label = packet.label
        updated.colors = packet.colors
        updated.wandVerified = verified || existing.wandVerified
        // A wand broadcasts the same packet continuously; without this guard every repeat
        // would rewrite the entire library.
        if updated != existing {
            learnedColors[index] = updated
            save()
            bumpRevisionThrottled()
        }
    }

    private func persistRecording(
        _ classified: ClassifiedPacket,
        rssi: Int,
        note: String,
        address: String,
        lat: Double?,
        lng: Double?,
        accuracy: Double?
    ) {
        if activeSessionURL == nil {
            beginScanSession()
        }
        let band = isBandAddress(address)
        let rec = Recording(
            id: nextRecordingId,
            timestampMs: Self.nowMs(),
            hex: classified.hex,
            rssi: rssi,
            label: classified.label,
            category: classified.category,
            typeInfo: classified.typeInfo,
            colors: classified.colors,
            libraryNote: note,
            sourceAddress: address,
            isBand: band,
            lat: lat,
            lng: lng,
            accuracy: accuracy
        )
        nextRecordingId += 1
        // The CSV session log is the durable record, so the in-memory list only feeds the UI:
        // it is capped, and the library is NOT saved here. An uncapped list plus a full
        // rewrite of the library per packet is a write storm that stalls a long session.
        recordings.insert(rec, at: 0)
        if recordings.count > Self.maxRecordings {
            recordings.removeLast(recordings.count - Self.maxRecordings)
        }
        // The full chronological log (the replay source), plus the band-only log for a tagged band.
        storeLogWriter.append(SessionLog.row(rec), band: band, header: SessionLog.header)
        accumulateUnique(rec)
    }

    /// Adds to the per-session unique tally behind the deduped export.
    private func accumulateUnique(_ rec: Recording) {
        sessionUnique.add(rec)
    }

    // MARK: - Auto rules

    /// The response stack of the first enabled rule this packet triggers, or nil.
    func findAutoResponses(classified: ClassifiedPacket, rawHex: String) -> [String]? {
        let enabled: [AutoResponseRule] = autoRules.filter { $0.enabled }
        if enabled.isEmpty { return nil }
        let learned = allLearnedPackets
        let userPresets = customPresets
        for rule in enabled {
            let triggered = PacketPatterns.matchesTriggerId(
                rule.triggerPatternId,
                classified: classified,
                rawHex: rawHex,
                userPresets: userPresets,
                learned: learned
            )
            if !triggered { continue }
            let hexes = PacketPatterns.resolveResponseHexes(rule: rule, userPresets: userPresets, learned: learned)
            if !hexes.isEmpty { return hexes }
        }
        return nil
    }

    /// Older single-response lookup: the first packet of the stack.
    func findAutoResponse(classified: ClassifiedPacket, rawHex: String) -> String? {
        findAutoResponses(classified: classified, rawHex: rawHex)?.first
    }

    func addAutoRule(name: String, triggerId: String, responseIds: [String], responseHexes: [String]) {
        let ids: [String] = responseIds.isEmpty ? ["resp_vibrate"] : responseIds
        let hexes: [String] = responseHexes.isEmpty ? [PacketBuilder.vibrateBand()] : responseHexes
        let rule = AutoResponseRule(
            id: nextRuleId,
            name: name,
            triggerPatternId: triggerId,
            responsePatternId: ids.first ?? "resp_vibrate",
            responseHex: hexes.first ?? "",
            responseHexes: hexes,
            enabled: true
        )
        nextRuleId += 1
        autoRules.append(rule)
        save()
        bumpRevision()
    }

    /// Older single-response form.
    func addAutoRule(name: String, triggerId: String, responseId: String, responseHex: String) {
        addAutoRule(name: name, triggerId: triggerId, responseIds: [responseId], responseHexes: [responseHex])
    }

    func setAutoRuleEnabled(id: Int64, enabled: Bool) {
        guard let index = autoRules.firstIndex(where: { $0.id == id }) else { return }
        if autoRules[index].enabled == enabled { return }
        autoRules[index].enabled = enabled
        save()
        bumpRevision()
    }

    func deleteAutoRule(id: Int64) {
        autoRules = autoRules.filter { $0.id != id }
        save()
        bumpRevision()
    }

    // MARK: - Capture logs

    var sessionActive: Bool { activeSessionURL != nil }

    /// File name of the session log being written, or nil when no session is open.
    var activeSessionName: String? { activeSessionURL?.lastPathComponent }

    @discardableResult
    func beginScanSession() -> URL {
        let dir = SessionLogFiles.logsDirectory()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = SessionLog.fileName(for: Date())
        let url = dir.appendingPathComponent(name)
        // The band-only log shares the stamp so the files of a session sort together.
        let bandURL = dir.appendingPathComponent(SessionLog.bandFileName(for: name))
        storeLogWriter.open(path: url.path, bandPath: bandURL.path, header: SessionLog.header)
        activeSessionURL = url
        activeBandURL = bandURL
        sessionUnique.removeAll()
        refreshSessions()
        bumpRevision()
        return url
    }

    /// Ends the session: everything queued is written, then the deduped unique-packet list
    /// (one row per distinct hex). Returns the session file's name, or nil when none was open.
    @discardableResult
    func endScanSession() -> String? {
        let name: String? = activeSessionURL?.lastPathComponent
        var uniquePath: String? = nil
        var uniqueText: String? = nil
        if let active = activeSessionURL, !sessionUnique.isEmpty {
            let uniqueName = SessionLog.uniqueFileName(for: active.lastPathComponent)
            uniquePath = active.deletingLastPathComponent().appendingPathComponent(uniqueName).path
            uniqueText = sessionUnique.csv()
        }
        storeLogWriter.close(uniquePath: uniquePath, uniqueText: uniqueText)
        activeSessionURL = nil
        activeBandURL = nil
        sessionUnique.removeAll()
        refreshSessions()
        if name != nil {
            bumpRevision()
        }
        return name
    }

    func refreshSessions() {
        var out: [ScanSessionFile] = []
        for entry in SessionLogFiles.entries(includeSidecars: true) {
            out.append(ScanSessionFile(url: entry.url))
        }
        scanSessions = out
    }

    /// Chronological session logs from every log directory (so old captures stay accessible),
    /// without the _band / _unique sidecars, newest first.
    func listLogs() -> [LogFile] {
        storeLogWriter.flush()
        var out: [LogFile] = []
        var counts: [String: LogCount] = [:]
        for entry in SessionLogFiles.entries(includeSidecars: false) {
            let path = entry.url.path
            var rows = 0
            if let cached = logCountCache[path],
               cached.sizeBytes == entry.sizeBytes,
               cached.modifiedMs == entry.modifiedMs {
                rows = cached.rows
            } else {
                rows = SessionLogFiles.rowCount(at: entry.url)
            }
            counts[path] = LogCount(sizeBytes: entry.sizeBytes, modifiedMs: entry.modifiedMs, rows: rows)
            out.append(LogFile(
                path: path,
                name: entry.url.lastPathComponent,
                sizeBytes: entry.sizeBytes,
                modifiedMs: entry.modifiedMs,
                packetCount: rows
            ))
        }
        logCountCache = counts
        return out
    }

    func readLog(path: String) -> [LoggedPacket] {
        storeLogWriter.flush()
        return SessionLogFiles.readLog(path: path)
    }

    /// Deletes a log and its two sidecars. True when the log itself was removed.
    @discardableResult
    func deleteLog(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        var isActive = false
        if let active = activeSessionURL {
            isActive = active.standardizedFileURL.path == url.standardizedFileURL.path
        }
        if isActive {
            storeLogWriter.close(uniquePath: nil, uniqueText: nil)
        }
        var removed = true
        do {
            try fileManager.removeItem(at: url)
        } catch {
            removed = false
        }
        try? fileManager.removeItem(at: dir.appendingPathComponent(SessionLog.bandFileName(for: name)))
        try? fileManager.removeItem(at: dir.appendingPathComponent(SessionLog.uniqueFileName(for: name)))
        logCountCache[path] = nil
        if isActive, let active = activeSessionURL, let band = activeBandURL {
            // The log being written was deleted: the session goes on in a fresh file of the
            // same name.
            storeLogWriter.open(path: active.path, bandPath: band.path, header: SessionLog.header)
            sessionUnique.removeAll()
        }
        refreshSessions()
        bumpRevision()
        return removed
    }

    /// Position-tagged observations from every chronological log — for the map, which only
    /// needs these six values. Rows without a readable lat/lng are skipped.
    func forEachLoggedLocation(
        _ action: (_ lat: Double, _ lng: Double, _ rssi: Int, _ address: String, _ label: String, _ category: String) -> Void
    ) {
        storeLogWriter.flush()
        SessionLogFiles.forEachLoggedLocation(action)
    }

    // MARK: - Library file

    /// Writes the current library to `Documents/magicmaker_library.json` and returns it, or
    /// nil when it could not be written.
    func exportLibrary() -> URL? {
        prepareIfNeeded()
        let url = libraryFileURL
        let state = buildState()
        do {
            let data = try encodeStoreState(state)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Replaces the library and the preferences with the contents of a library file written
    /// by either app. False (and nothing changed) when the file is not a library.
    @discardableResult
    func importLibrary(from url: URL) -> Bool {
        prepareIfNeeded()
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let state: StorePersistedState
        do {
            let data = try Data(contentsOf: url)
            state = try decodeStoreState(data)
        } catch {
            return false
        }
        applyState(state, overwritePrefs: true)
        storeWriteBlocked = false
        save()
        mergeBuiltInPresets()
        bumpRevision()
        return true
    }

    /// Adds the packets of a linked Android phone's library that are not here yet, matched by
    /// canonical hex. Nothing is replaced or removed. Returns the number of rows added.
    @discardableResult
    func importAndroidCatalog(_ catalog: AndroidRemoteCatalog) -> Int {
        var known = Set<String>()
        for packet in presets {
            known.insert(Self.canonical(packet.hex))
        }
        for packet in allLearnedPackets {
            known.insert(Self.canonical(packet.hex))
        }
        var newColors: [MagicPacket] = []
        var newLibrary: [MagicPacket] = []
        var newRaw: [MagicPacket] = []
        var rows: [AndroidRemotePreset] = catalog.transmitPresets
        rows.append(contentsOf: catalog.wandColors)

        for row in rows {
            let canonical = HexUtils.canonicalHex(row.hex)
            if !HexUtils.isDisneyBlePacket(canonical) { continue }
            // Pings are never kept in the library.
            if row.typeInfo == "ping" { continue }
            if known.contains(canonical) { continue }

            let category: MagicCategory = MagicCategory(rawValue: row.category.uppercased()) ?? .unknown
            var label = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label == "?" { label = "" }

            if category == .unknown {
                if MagicClassifier.isLibraryNoise(canonical) { continue }
                if learnedRaw.count + newRaw.count >= Self.maxRawLibrary { continue }
                if label.isEmpty { label = MagicClassifier.rawLabel(canonical) }
                newRaw.append(MagicPacket(
                    id: nextPacketId,
                    hex: canonical,
                    label: label,
                    category: .unknown,
                    typeInfo: "raw",
                    simKey: "RAW:\(canonical)",
                    userRecorded: row.userRecorded
                ))
            } else {
                // The BLE catalog sync drops the colours and the match key; the classifier
                // gives them back for any packet it knows.
                let classified: ClassifiedPacket? = MagicClassifier.classify(canonical)
                if label.isEmpty { label = classified?.label ?? "Imported" }
                var typeInfo = row.typeInfo
                if typeInfo.isEmpty || typeInfo == "raw" { typeInfo = classified?.typeInfo ?? "imported" }
                var colors = row.colors
                if colors.isEmpty { colors = classified?.colors ?? "" }
                let packet = MagicPacket(
                    id: nextPacketId,
                    hex: canonical,
                    label: label,
                    category: category,
                    typeInfo: typeInfo,
                    colors: colors,
                    simKey: classified?.simKey ?? "",
                    userRecorded: row.userRecorded,
                    wandVerified: row.wandVerified
                )
                if category == .color {
                    newColors.append(packet)
                } else {
                    newLibrary.append(packet)
                }
            }
            nextPacketId += 1
            known.insert(canonical)
        }

        let added = newColors.count + newLibrary.count + newRaw.count
        if added == 0 { return 0 }
        if !newColors.isEmpty {
            learnedColors.append(contentsOf: newColors)
        }
        if !newLibrary.isEmpty {
            var merged = learnedLibrary
            merged.append(contentsOf: newLibrary)
            learnedLibrary = Self.sortedByLabel(merged, ignoringCase: true)
        }
        if !newRaw.isEmpty {
            learnedRaw.append(contentsOf: newRaw)
        }
        rebuildRawIndex()
        save()
        bumpRevision()
        return added
    }

    // MARK: - Persistence

    /// Reads `Documents/magicmaker_store.json`. A file that cannot be read as a library is
    /// never overwritten: it is set aside as `magicmaker_store.corrupt.json` and the store
    /// starts again from the built-in presets.
    func load() {
        hasLoaded = true
        let url = storeURL
        if !fileManager.fileExists(atPath: url.path) { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // The file is there but could not be read just now (locked, I/O error). It may be
            // a good library, so it is neither moved nor written over during this run.
            CrashLog.record(error, "MagicStore.load read")
            storeWriteBlocked = true
            return
        }
        let state: StorePersistedState
        do {
            state = try decodeStoreState(data)
        } catch {
            CrashLog.record(error, "MagicStore.load")
            setAsideUnreadableStore()
            return
        }
        // The preferences on this phone are at least as new as the copy in the file, so at
        // launch the file only fills in what is missing. An import replaces them.
        applyState(state, overwritePrefs: false)
    }

    /// Once, before this store first reads the library file an earlier iOS build wrote, keep a
    /// copy of it (`magicmaker_store.before-upgrade.json`, visible in the Files app), so nothing
    /// the earlier build saved can be lost however it is read here. The marker key starts with a
    /// capital so it is not exported with the settings.
    private func keepPreUpgradeCopy() {
        let marker = "MMStorePreUpgradeCopy"
        if defaults.bool(forKey: marker) { return }
        let source = storeURL
        if fileManager.fileExists(atPath: source.path) {
            let copy = SessionLogFiles.documentsDirectory().appendingPathComponent("magicmaker_store.before-upgrade.json")
            if !fileManager.fileExists(atPath: copy.path) {
                do {
                    try fileManager.copyItem(at: source, to: copy)
                } catch {
                    // Try again next launch rather than carry on without the copy marked done.
                    CrashLog.record(error, "MagicStore.keepPreUpgradeCopy")
                    return
                }
            }
        }
        defaults.set(true, forKey: marker)
    }

    private func setAsideUnreadableStore() {
        let aside = corruptStoreURL
        try? fileManager.removeItem(at: aside)
        do {
            try fileManager.moveItem(at: storeURL, to: aside)
        } catch {
            storeWriteBlocked = true
        }
    }

    private func applyState(_ state: StorePersistedState, overwritePrefs: Bool) {
        presets = state.presets
        learnedColors = state.learnedColors
        learnedLibrary = state.learnedLibrary
        learnedRaw = state.learnedRaw
        rebuildRawIndex()
        recordings = Array(state.recordings.prefix(Self.maxRecordings))
        autoRules = state.autoRules
        // The counters never fall behind the ids already in use, whatever the file says.
        nextPacketId = max(state.nextPacketId, highestPacketId() + 1)
        nextRecordingId = max(state.nextRecordingId, 1)
        var highestRule: Int64 = 0
        for rule in autoRules where rule.id > highestRule {
            highestRule = rule.id
        }
        nextRuleId = max(state.nextRuleId, highestRule + 1)
        // The explicit fields first (they cover older files without the settings maps), then
        // the full snapshots, which override them and fill in everything else.
        restoreString("starlight_serial", state.starlightSerial, overwrite: overwritePrefs)
        restoreString("lab_hex", state.labHex, overwrite: overwritePrefs)
        restoreString("lab_label", state.labLabel, overwrite: overwritePrefs)
        if let settings = state.settings {
            restorePrefs(settings, overwrite: overwritePrefs)
        }
        if let uiSettings = state.uiSettings {
            restorePrefs(uiSettings, overwrite: overwritePrefs)
        }
    }

    private func highestPacketId() -> Int64 {
        var highest: Int64 = 0
        let lists: [[MagicPacket]] = [presets, learnedColors, learnedLibrary, learnedRaw]
        for list in lists {
            for packet in list where packet.id > highest {
                highest = packet.id
            }
        }
        return highest
    }

    // Recordings are not written to the library file: the CSV session log is their record.
    private func buildState() -> StorePersistedState {
        let prefs = snapshotPrefs()
        return StorePersistedState(
            presets: presets,
            learnedColors: learnedColors,
            learnedLibrary: learnedLibrary,
            learnedRaw: learnedRaw,
            recordings: [],
            autoRules: autoRules,
            nextPacketId: nextPacketId,
            nextRecordingId: nextRecordingId,
            nextRuleId: nextRuleId,
            starlightSerial: getStarlightSerial(),
            labHex: getLabHex(),
            labLabel: getLabLabel(),
            settings: prefs.main,
            uiSettings: prefs.ui
        )
    }

    /// Every preference this app has set, type-tagged, split the way Android splits its two
    /// preference files.
    private func snapshotPrefs() -> (main: [String: PrefEntry], ui: [String: PrefEntry]) {
        var main: [String: PrefEntry] = [:]
        var ui: [String: PrefEntry] = [:]
        let domainName: String = Bundle.main.bundleIdentifier ?? ""
        if domainName.isEmpty { return (main, ui) }
        let domain: [String: Any] = defaults.persistentDomain(forName: domainName) ?? [:]
        for (key, value) in domain {
            if !Self.isAppPrefKey(key) { continue }
            guard let entry = Self.prefEntry(key: key, value: value) else { continue }
            if Self.uiPrefKeys.contains(key) {
                ui[key] = entry
            } else {
                main[key] = entry
            }
        }
        return (main, ui)
    }

    /// The app's own keys are lower snake case. Keys the system keeps in the same domain
    /// (`AppleLanguages`, `NS…`, `com.apple.…`) are neither exported nor restored.
    private static func isAppPrefKey(_ key: String) -> Bool {
        guard let first = key.utf8.first else { return false }
        if first < 0x61 || first > 0x7A { return false }
        for byte in key.utf8 where byte == 0x2E {
            return false
        }
        return true
    }

    private static func prefEntry(key: String, value: Any) -> PrefEntry? {
        if let text = value as? String {
            return PrefEntry(type: "s", value: text)
        }
        if let list = value as? [String] {
            return PrefEntry(type: "ss", strings: list)
        }
        if let number = value as? NSNumber {
            let code = String(cString: number.objCType)
            if code == "c" || code == "B" {
                return PrefEntry(type: "b", value: number.boolValue ? "true" : "false")
            }
            if code == "f" || code == "d" {
                return PrefEntry(type: "f", value: "\(number.floatValue)")
            }
            let whole: Int64 = number.int64Value
            let fitsInt = whole >= Int64(Int32.min) && whole <= Int64(Int32.max)
            if longPrefKeys.contains(key) || !fitsInt {
                return PrefEntry(type: "l", value: "\(whole)")
            }
            return PrefEntry(type: "i", value: "\(whole)")
        }
        // Data, dates and dictionaries have no counterpart in the file.
        return nil
    }

    private func restoreString(_ key: String, _ value: String, overwrite: Bool) {
        if !overwrite && defaults.object(forKey: key) != nil { return }
        defaults.set(value, forKey: key)
    }

    private func restorePrefs(_ entries: [String: PrefEntry], overwrite: Bool) {
        for (key, entry) in entries {
            if !Self.isAppPrefKey(key) { continue }
            if !overwrite && defaults.object(forKey: key) != nil { continue }
            switch entry.type {
            case "b":
                let flag = (entry.value ?? "").lowercased() == "true"
                defaults.set(flag, forKey: key)
            case "i":
                if let text = entry.value, let parsed = Int32(text) {
                    defaults.set(Int(parsed), forKey: key)
                }
            case "l":
                if let text = entry.value, let parsed = Int64(text) {
                    defaults.set(Int(parsed), forKey: key)
                }
            case "f":
                if let text = entry.value, let parsed = Float(text) {
                    defaults.set(parsed, forKey: key)
                }
            case "s":
                if let text = entry.value {
                    defaults.set(text, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            case "ss":
                let members: [String] = entry.strings ?? []
                defaults.set(members, forKey: key)
            default:
                break
            }
        }
    }

    /// Marks the library changed. Writing the whole store is expensive, so a burst of calls
    /// becomes one write, encoded and written off the main thread from a value snapshot.
    func save() {
        if saveScheduled { return }
        saveScheduled = true
        let wait = Self.saveDebounceNs
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            self?.flushSave()
        }
    }

    /// Starts the pending write now instead of waiting out the coalescing delay.
    func flushSave() {
        if !saveScheduled { return }
        saveScheduled = false
        startWrite()
    }

    private func startWrite() {
        if storeWriteBlocked || !hasLoaded { return }
        // One write at a time. A change made while one is under way is written right after
        // it, from a fresh snapshot.
        if writeInFlight {
            changedWhileWriting = true
            return
        }
        writeInFlight = true
        let state = buildState()
        let url = storeURL
        Self.saveQueue.async { [weak self] in
            writeStoreSnapshot(state, to: url)
            Task { @MainActor [weak self] in
                self?.writeFinished()
            }
        }
    }

    private func writeFinished() {
        writeInFlight = false
        if changedWhileWriting {
            changedWhileWriting = false
            startWrite()
        }
        endSaveBackgroundTaskIfIdle()
    }

    /// Coalesces the high-volume raw-learn saves so a packet flood cannot cause an IO storm:
    /// at most one save per interval, and the last packet of a burst is still saved.
    private func coalesceRawSave() {
        let now = Self.nowMs()
        let elapsed = now - lastRawSaveMs
        if elapsed >= Self.rawSaveIntervalMs || elapsed < 0 {
            lastRawSaveMs = now
            save()
            return
        }
        if rawSavePending { return }
        rawSavePending = true
        let waitMs: Int64 = max(Self.rawSaveIntervalMs - elapsed, 1)
        let waitNs = UInt64(waitMs) * 1_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: waitNs)
            guard let self else { return }
            self.rawSavePending = false
            self.lastRawSaveMs = MagicStore.nowMs()
            self.save()
        }
    }

    // MARK: - Revision

    /// Tells the views that something they show has changed.
    func bumpRevision() {
        lastRevisionMs = Self.nowMs()
        revision += 1
    }

    /// For packets learned while scanning: at most one bump per interval, and the last
    /// change of a burst is still announced.
    private func bumpRevisionThrottled() {
        let now = Self.nowMs()
        let elapsed = now - lastRevisionMs
        if elapsed >= Self.revisionIntervalMs || elapsed < 0 {
            bumpRevision()
            return
        }
        if revisionPending { return }
        revisionPending = true
        let waitMs: Int64 = max(Self.revisionIntervalMs - elapsed, 1)
        let waitNs = UInt64(waitMs) * 1_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: waitNs)
            guard let self else { return }
            self.revisionPending = false
            self.bumpRevision()
        }
    }

    // MARK: - Lookups

    private func rebuildRawIndex() {
        var index = Set<String>()
        var noise = 0
        for packet in learnedRaw {
            let key = Self.canonical(packet.hex)
            index.insert(key)
            if MagicClassifier.isLibraryNoise(key) { noise += 1 }
        }
        rawHexIndex = index
        rawNoiseCount = noise
    }

    private func ensureColorIndex() {
        if colorIndexValid { return }
        var byHex: [String: Int] = [:]
        var starlight = Set<String>()
        var bySimKey: [String: Int] = [:]
        for (index, packet) in learnedColors.enumerated() {
            let key = Self.canonical(packet.hex)
            if byHex[key] == nil {
                byHex[key] = index
            }
            if packet.typeInfo == "starlight" {
                starlight.insert(key)
                if bySimKey[packet.simKey] == nil {
                    bySimKey[packet.simKey] = index
                }
            }
        }
        colorIndexByHex = byHex
        starlightHexes = starlight
        starlightIndexBySimKey = bySimKey
        colorIndexValid = true
    }

    private func ensureLibraryIndex() {
        if libraryIndexValid { return }
        var byHex: [String: Int] = [:]
        for (index, packet) in learnedLibrary.enumerated() {
            let key = Self.canonical(packet.hex)
            if byHex[key] == nil {
                byHex[key] = index
            }
        }
        libraryIndexByHex = byHex
        libraryIndexValid = true
    }

    /// The library is kept ordered by label, ignoring case.
    private func resortLibrary() {
        if deferLibrarySort {
            librarySortPending = true
            return
        }
        learnedLibrary = Self.sortedByLabel(learnedLibrary, ignoringCase: true)
    }

    /// Stable sort by label in UTF-16 code unit order, the order Android's `sortedBy` gives.
    private static func sortedByLabel(_ packets: [MagicPacket], ignoringCase: Bool) -> [MagicPacket] {
        struct Keyed {
            let key: [UInt16]
            let offset: Int
            let packet: MagicPacket
        }
        var keyed: [Keyed] = []
        keyed.reserveCapacity(packets.count)
        for (offset, packet) in packets.enumerated() {
            let text: String = ignoringCase ? packet.label.lowercased() : packet.label
            keyed.append(Keyed(key: Array(text.utf16), offset: offset, packet: packet))
        }
        keyed.sort { (a: Keyed, b: Keyed) -> Bool in
            if a.key == b.key { return a.offset < b.offset }
            return a.key.lexicographicallyPrecedes(b.key)
        }
        return keyed.map { $0.packet }
    }

    /// `HexUtils.canonicalHex`, with a shortcut for text that is already canonical — which
    /// every stored row is, and these lists are walked whole.
    private static func canonical(_ hex: String) -> String {
        var length = 0
        for byte in hex.utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isUpperHex = byte >= 0x41 && byte <= 0x46
            if !isDigit && !isUpperHex {
                return HexUtils.canonicalHex(hex)
            }
            length += 1
        }
        if length >= 4 && hex.hasPrefix("8301") {
            return hex
        }
        return HexUtils.canonicalHex(hex)
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
