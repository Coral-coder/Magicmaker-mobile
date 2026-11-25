import Foundation

// The iPhone <-> Apple Watch contract over WatchConnectivity (docs/WATCH_APP.md section 3).
// Compiled into BOTH targets, MagicMaker (iOS) and MagicMakerWatch (watchOS): Foundation only.
// Every payload is a property-list dictionary; the structured parts travel as JSON Data.

enum WatchProtocol {
    /// Bumped only for a change an older peer would misread. New fields are optional and keep 1.
    static let version: Int = 1
    /// Most favourites the iPhone keeps (and so the watch shows).
    static let maxFavorites: Int = 24

    static let keyVersion: String = "v"
    static let keyAt: String = "at"
    static let keyFavorites: String = "favorites"
    static let keyStatus: String = "status"
    static let keyTheme: String = "theme"
    static let keyLastSend: String = "lastSend"
    static let keyOp: String = "op"
    static let keyId: String = "id"
    static let keyOk: String = "ok"
    static let keyState: String = "state"
    static let keyVia: String = "via"
    static let keyError: String = "error"
    static let keyLabel: String = "label"
    /// watch -> iPhone, optional: when the watch sent the request (its clock, Unix seconds).
    static let keySentAt: String = "sentAt"

    /// A favourite that reaches the iPhone this long after the tap is not sent: the watch gives
    /// up on a reply after 30 s, so a band lighting up later would be a surprise. A paired
    /// watch's clock follows the iPhone's, far closer than this.
    static let lateSendSeconds: Double = 20

    static let opSend: String = "send"
    static let opStopPrograms: String = "stop_programs"
    static let opRefresh: String = "refresh"

    static let stateSent: String = "sent"
    static let stateOnAir: String = "on_air"
    static let stateQueued: String = "queued"
    static let stateLoop: String = "loop"
    static let stateStopped: String = "stopped"
    static let stateRefreshed: String = "refreshed"
    static let stateFailed: String = "failed"

    static let viaEsp32: String = "ESP32"
    static let viaAndroidBle: String = "ANDROID BLE"
    static let viaAndroidWifi: String = "ANDROID WIFI"
    static let viaIphone: String = "IPHONE"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The version a dictionary carries; 0 when it has none.
    static func versionOf(_ dictionary: [String: Any]) -> Int {
        return dictionary[keyVersion] as? Int ?? 0
    }
}

/// One starred packet (docs/WATCH_APP.md 2.1). kind / source / burst are strings so that a value
/// added later never makes an older peer drop the whole list.
struct WatchFavorite: Codable, Equatable, Identifiable {
    enum Kind {
        static let band: String = "band"
        static let wand: String = "wand"
        static let other: String = "other"
    }
    enum Source {
        static let library: String = "library"
        static let labPreset: String = "labPreset"
        static let wandColor: String = "wandColor"
        static let newWand: String = "newWand"
        static let wandQuick: String = "wandQuick"
    }
    enum Burst {
        static let command: String = "command"
        static let starlight: String = "starlight"
        static let ping: String = "ping"
    }

    var id: String
    var label: String
    var hex: String
    var kind: String
    var source: String
    var burst: String
    var wake: Bool
    var swatch: String?
    var onAirMs: Int?
    var addedAt: Double
}

/// The ESP32 transmitter as the iPhone knows it.
struct WatchEsp32Status: Codable, Equatable {
    /// "LINKED", "LINKING", "NOT LINKED" or "NOT SELECTED".
    var state: String
    var batteryPct: Int?
    var batteryMv: Int?
    var runtimeMin: Int?
    var charging: Bool
    /// "KEEP AWAKE", "TX LOOP · 3S", "WAND LOOP · 2.5S" or "IDLE"; nil without a status.
    var program: String?
    var firmware: String?
    var board: String?
    var uptimeS: Int?
    var outdated: Bool
}

/// The Android phone as the iPhone knows it (relay backend and scanner).
struct WatchAndroidStatus: Codable, Equatable {
    /// "LINKED", "LINKING", "NOT LINKED" or "NOT SELECTED".
    var state: String
    /// "BLE", "WIFI", or "" when not selected.
    var transport: String
    var scanning: Bool?
    var autoArmed: Bool?
    var keepAwake: Bool?
    var program: String?
    var lastHeardLabel: String?
}

/// This iPhone.
struct WatchPhoneStatus: Codable, Equatable {
    var batteryPct: Int?
    var charging: Bool
    /// ScanEngine.bluetoothStatus, uppercased ("BLUETOOTH READY", "TURN ON BLUETOOTH", ...).
    var bluetooth: String
    var scanning: Bool
    /// The app is frontmost (iOS passes band packets to it only then).
    var foreground: Bool
    var autoArmed: Bool
    var lastHeardLabel: String
    /// Unix seconds of the newest heard packet; nil when none this run.
    var lastHeardAt: Double?
    var txStatus: String
    var transmitting: Bool
    /// Programs this iPhone times itself: "TX LOOP · 3S", "WAND LOOP · 3S", "RANDOM SHOW", "REPLAY 3/40".
    var programs: [String]
}

struct WatchStatus: Codable, Equatable {
    /// The selected backend's via name ("ESP32", "ANDROID BLE", "ANDROID WIFI").
    var selected: String
    var linked: Bool
    /// AppViewModel.remoteLinkHint, uppercased; "" when linked.
    var hint: String
    var esp32: WatchEsp32Status
    var android: WatchAndroidStatus
    var phone: WatchPhoneStatus
}

/// The five VFD inks of the iPhone's base colour ("#RRGGBB").
struct WatchThemeColors: Codable, Equatable {
    var highlight: String
    var text: String
    var dim: String
    var alarm: String
    /// A red-ish base: alarms are drawn as inverted highlight blocks.
    var alarmInverted: Bool

    static let amber: WatchThemeColors = WatchThemeColors(
        highlight: "#FFB014", text: "#FFE8C4", dim: "#966428", alarm: "#FF5028", alarmInverted: false)
}

/// The final result of a watch send whose reply went out before it ended.
struct WatchSendResult: Codable, Equatable {
    var id: String
    var ok: Bool
    var state: String
    var via: String
    var error: String
    var label: String
    var at: Double
}

/// The application context and the snapshot part of a reply. A part that is absent stays nil;
/// the watch applies only the parts that are present.
struct WatchContext: Equatable {
    var at: Double
    var favorites: [WatchFavorite]?
    var status: WatchStatus?
    var theme: WatchThemeColors?
    var lastSend: WatchSendResult?

    init(at: Double, favorites: [WatchFavorite]? = nil, status: WatchStatus? = nil,
         theme: WatchThemeColors? = nil, lastSend: WatchSendResult? = nil) {
        self.at = at
        self.favorites = favorites
        self.status = status
        self.theme = theme
        self.lastSend = lastSend
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [WatchProtocol.keyVersion: WatchProtocol.version, WatchProtocol.keyAt: at]
        if let favorites, let data = WatchProtocol.encode(favorites) { d[WatchProtocol.keyFavorites] = data }
        if let status, let data = WatchProtocol.encode(status) { d[WatchProtocol.keyStatus] = data }
        if let theme, let data = WatchProtocol.encode(theme) { d[WatchProtocol.keyTheme] = data }
        if let lastSend, let data = WatchProtocol.encode(lastSend) { d[WatchProtocol.keyLastSend] = data }
        return d
    }

    /// nil for another protocol version or a dictionary with no `at`.
    init?(dictionary d: [String: Any]) {
        guard WatchProtocol.versionOf(d) == WatchProtocol.version,
              let at = d[WatchProtocol.keyAt] as? Double else { return nil }
        self.at = at
        self.favorites = WatchProtocol.decode([WatchFavorite].self, d[WatchProtocol.keyFavorites])
        self.status = WatchProtocol.decode(WatchStatus.self, d[WatchProtocol.keyStatus])
        self.theme = WatchProtocol.decode(WatchThemeColors.self, d[WatchProtocol.keyTheme])
        self.lastSend = WatchProtocol.decode(WatchSendResult.self, d[WatchProtocol.keyLastSend])
    }
}

/// watch -> iPhone.
struct WatchRequest {
    var version: Int
    var op: String
    var id: String?
    /// When the watch sent it (watch clock, Unix seconds); nil from a peer that does not send it.
    var sentAt: Double?

    init(op: String, id: String? = nil) {
        self.version = WatchProtocol.version
        self.op = op
        self.id = id
        self.sentAt = Date().timeIntervalSince1970
    }

    init?(dictionary d: [String: Any]) {
        guard let op = d[WatchProtocol.keyOp] as? String else { return nil }
        self.version = WatchProtocol.versionOf(d)
        self.op = op
        self.id = d[WatchProtocol.keyId] as? String
        self.sentAt = d[WatchProtocol.keySentAt] as? Double
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [WatchProtocol.keyVersion: version, WatchProtocol.keyOp: op]
        if let id { d[WatchProtocol.keyId] = id }
        if let sentAt { d[WatchProtocol.keySentAt] = sentAt }
        return d
    }

    /// Seconds from the watch's send to `now` on this device's clock; nil without `sentAt`.
    func age(now: Date = Date()) -> Double? {
        guard let sentAt else { return nil }
        return now.timeIntervalSince1970 - sentAt
    }
}

/// iPhone -> watch, the reply to one request.
struct WatchReply {
    var ok: Bool
    var state: String
    var via: String
    var error: String
    var label: String
    var id: String?
    var context: WatchContext?

    init(ok: Bool, state: String, via: String, error: String = "", label: String = "",
         id: String? = nil, context: WatchContext? = nil) {
        self.ok = ok
        self.state = state
        self.via = via
        self.error = error
        self.label = label
        self.id = id
        self.context = context
    }

    init?(dictionary d: [String: Any]) {
        guard let ok = d[WatchProtocol.keyOk] as? Bool,
              let state = d[WatchProtocol.keyState] as? String else { return nil }
        self.ok = ok
        self.state = state
        self.via = d[WatchProtocol.keyVia] as? String ?? ""
        self.error = d[WatchProtocol.keyError] as? String ?? ""
        self.label = d[WatchProtocol.keyLabel] as? String ?? ""
        self.id = d[WatchProtocol.keyId] as? String
        self.context = WatchContext(dictionary: d)
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = context?.dictionary() ?? [WatchProtocol.keyVersion: WatchProtocol.version]
        d[WatchProtocol.keyOk] = ok
        d[WatchProtocol.keyState] = state
        d[WatchProtocol.keyVia] = via
        d[WatchProtocol.keyError] = error
        d[WatchProtocol.keyLabel] = label
        if let id { d[WatchProtocol.keyId] = id }
        return d
    }
}
