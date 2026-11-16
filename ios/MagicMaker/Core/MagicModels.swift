import Foundation

enum MagicCategory: String, Codable, CaseIterable {
    case show = "SHOW"
    case animation = "ANIMATION"
    case color = "COLOR"
    case unknown = "UNKNOWN"

    /// An unrecognised category name reads as `.unknown` instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let raw: String? = try? decoder.singleValueContainer().decode(String.self)
        self = MagicCategory(rawValue: (raw ?? "").uppercased()) ?? .unknown
    }
}

/// Lenient keyed reads for the persisted models: a missing key, a null or a value of the wrong
/// type all fall back to a default, so an older store file or one written by Android still loads.
private extension KeyedDecodingContainer {
    func lenientString(_ key: Key, default fallback: String = "") -> String {
        let value: String? = try? decodeIfPresent(String.self, forKey: key)
        return value ?? fallback
    }

    func lenientBool(_ key: Key, default fallback: Bool = false) -> Bool {
        let value: Bool? = try? decodeIfPresent(Bool.self, forKey: key)
        return value ?? fallback
    }

    func lenientInt(_ key: Key) -> Int? {
        let value: Int? = try? decodeIfPresent(Int.self, forKey: key)
        return value
    }

    func lenientInt64(_ key: Key, default fallback: Int64 = 0) -> Int64 {
        let value: Int64? = try? decodeIfPresent(Int64.self, forKey: key)
        return value ?? fallback
    }

    func lenientCategory(_ key: Key) -> MagicCategory {
        let value: MagicCategory? = try? decodeIfPresent(MagicCategory.self, forKey: key)
        return value ?? .unknown
    }

    func lenientFiniteDouble(_ key: Key) -> Double? {
        let value: Double? = try? decodeIfPresent(Double.self, forKey: key)
        return finiteOrNil(value)
    }
}

/// JSONEncoder refuses NaN and infinity, so "no value" is always nil.
private func finiteOrNil(_ value: Double?) -> Double? {
    guard let v = value, v.isFinite else { return nil }
    return v
}

struct MagicPacket: Identifiable, Codable, Equatable {
    var id: Int64
    var hex: String
    var label: String
    var category: MagicCategory
    var typeInfo: String
    var colors: String
    var simKey: String
    var userRecorded: Bool
    var rssi: Int?
    var wandVerified: Bool

    init(
        id: Int64 = 0,
        hex: String,
        label: String,
        category: MagicCategory,
        typeInfo: String,
        colors: String = "",
        simKey: String,
        userRecorded: Bool = false,
        rssi: Int? = nil,
        wandVerified: Bool = false
    ) {
        self.id = id
        self.hex = hex
        self.label = label
        self.category = category
        self.typeInfo = typeInfo
        self.colors = colors
        self.simKey = simKey
        self.userRecorded = userRecorded
        self.rssi = rssi
        self.wandVerified = wandVerified
    }

    enum CodingKeys: String, CodingKey {
        case id, hex, label, category, typeInfo, colors, simKey, userRecorded, rssi, wandVerified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt64(.id)
        hex = try c.decode(String.self, forKey: .hex)
        label = c.lenientString(.label)
        category = c.lenientCategory(.category)
        typeInfo = c.lenientString(.typeInfo)
        colors = c.lenientString(.colors)
        simKey = c.lenientString(.simKey)
        userRecorded = c.lenientBool(.userRecorded)
        rssi = c.lenientInt(.rssi)
        wandVerified = c.lenientBool(.wandVerified)
    }
}

struct ClassifiedPacket: Equatable {
    let hex: String
    let label: String
    let category: MagicCategory
    let typeInfo: String
    let colors: String
    let simKey: String
}

struct IScanLivePacket: Identifiable, Equatable {
    let timestampMs: Int64
    let hex: String
    let label: String
    let rssi: Int
    let note: String
    let category: MagicCategory
    let typeInfo: String
    let dedupeKey: String
    var sourceAddress: String
    var isBand: Bool

    init(
        timestampMs: Int64,
        hex: String,
        label: String,
        rssi: Int,
        note: String,
        category: MagicCategory,
        typeInfo: String,
        dedupeKey: String,
        sourceAddress: String = "",
        isBand: Bool = false
    ) {
        self.timestampMs = timestampMs
        self.hex = hex
        self.label = label
        self.rssi = rssi
        self.note = note
        self.category = category
        self.typeInfo = typeInfo
        self.dedupeKey = dedupeKey
        self.sourceAddress = sourceAddress
        self.isBand = isBand
    }

    var id: String { "\(timestampMs)-\(hex.prefix(16))" }
}

/// One advertisement in the scan engine's live feed. Port of Android `ServiceState.LivePacket`.
struct LivePacket: Identifiable, Equatable {
    let hex: String
    let label: String
    let rssi: Int
    let note: String
    let category: MagicCategory
    let typeInfo: String
    let dedupeKey: String
    let timestampMs: Int64
    /// The advertiser's source id; empty when unknown.
    let address: String
    /// The source is one the user tagged as their own MagicBand.
    let isBand: Bool

    var id: String { "\(timestampMs)-\(dedupeKey)" }
}

/// A source heard while scanning; feeds the "pick my band" list.
struct SeenAddress: Identifiable, Equatable {
    let address: String
    let rssi: Int
    let lastSeenMs: Int64
    let count: Int

    var id: String { address }
}

/// Per-broadcaster diagnostics: one entry per source.
struct SourceStat: Identifiable, Equatable {
    let address: String
    let count: Int
    let bestRssi: Int
    let lastRssi: Int
    let lastSeenMs: Int64
    /// The source sent at least one show, animation or colour packet.
    let priority: Bool
    /// The category names heard from this source, in alphabetical order.
    let categories: [String]

    var id: String { address }
}

struct Recording: Identifiable, Codable, Equatable {
    var id: Int64
    var timestampMs: Int64
    var hex: String
    var rssi: Int
    var label: String
    var category: MagicCategory
    var typeInfo: String
    var colors: String
    var libraryNote: String
    var sourceAddress: String
    var isBand: Bool
    /// Where the packet was heard. Nil when there was no location fix (Android stores NaN / -1).
    var lat: Double?
    var lng: Double?
    var accuracy: Double?

    init(
        id: Int64,
        timestampMs: Int64,
        hex: String,
        rssi: Int,
        label: String,
        category: MagicCategory,
        typeInfo: String,
        colors: String,
        libraryNote: String,
        sourceAddress: String = "",
        isBand: Bool = false,
        lat: Double? = nil,
        lng: Double? = nil,
        accuracy: Double? = nil
    ) {
        self.id = id
        self.timestampMs = timestampMs
        self.hex = hex
        self.rssi = rssi
        self.label = label
        self.category = category
        self.typeInfo = typeInfo
        self.colors = colors
        self.libraryNote = libraryNote
        self.sourceAddress = sourceAddress
        self.isBand = isBand
        self.lat = finiteOrNil(lat)
        self.lng = finiteOrNil(lng)
        if let acc = finiteOrNil(accuracy), acc >= 0 {
            self.accuracy = acc
        } else {
            self.accuracy = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, timestampMs, hex, rssi, label, category, typeInfo, colors, libraryNote
        case sourceAddress, isBand, lat, lng, accuracy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt64(.id)
        timestampMs = c.lenientInt64(.timestampMs)
        hex = try c.decode(String.self, forKey: .hex)
        rssi = c.lenientInt(.rssi) ?? 0
        label = c.lenientString(.label)
        category = c.lenientCategory(.category)
        typeInfo = c.lenientString(.typeInfo)
        colors = c.lenientString(.colors)
        libraryNote = c.lenientString(.libraryNote)
        sourceAddress = c.lenientString(.sourceAddress)
        isBand = c.lenientBool(.isBand)
        lat = c.lenientFiniteDouble(.lat)
        lng = c.lenientFiniteDouble(.lng)
        // Android writes a negative accuracy for "unknown".
        if let acc = c.lenientFiniteDouble(.accuracy), acc >= 0 {
            accuracy = acc
        } else {
            accuracy = nil
        }
    }
}

struct AutoResponseRule: Identifiable, Codable, Equatable {
    var id: Int64
    var name: String
    var triggerPatternId: String
    var responsePatternId: String
    var responseHex: String
    /// The response stack, sent in order. Empty on rules made before stacking existed; those
    /// resolve through `responsePatternId` / `responseHex` instead.
    var responseHexes: [String]
    var enabled: Bool

    init(
        id: Int64,
        name: String,
        triggerPatternId: String,
        responsePatternId: String,
        responseHex: String,
        responseHexes: [String] = [],
        enabled: Bool
    ) {
        self.id = id
        self.name = name
        self.triggerPatternId = triggerPatternId
        self.responsePatternId = responsePatternId
        self.responseHex = responseHex
        self.responseHexes = responseHexes
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, triggerPatternId, responsePatternId, responseHex, responseHexes, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt64(.id)
        name = c.lenientString(.name)
        triggerPatternId = c.lenientString(.triggerPatternId)
        responsePatternId = c.lenientString(.responsePatternId)
        responseHex = c.lenientString(.responseHex)
        let stack: [String]? = try? c.decodeIfPresent([String].self, forKey: .responseHexes)
        responseHexes = stack ?? []
        enabled = c.lenientBool(.enabled, default: true)
    }
}

struct RecordEvent {
    let packet: MagicPacket
    let added: Bool
    let reason: String
}

struct ScanSessionFile: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

extension MagicPacket {
    func toClassified() -> ClassifiedPacket {
        ClassifiedPacket(hex: hex, label: label, category: category, typeInfo: typeInfo, colors: colors, simKey: simKey)
    }
}

extension ClassifiedPacket {
    func toPacket(userRecorded: Bool = false) -> MagicPacket {
        MagicPacket(
            id: 0,
            hex: hex,
            label: label,
            category: category,
            typeInfo: typeInfo,
            colors: colors,
            simKey: simKey,
            userRecorded: userRecorded
        )
    }
}
