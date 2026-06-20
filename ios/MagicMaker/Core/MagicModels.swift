import Foundation

enum MagicCategory: String, Codable, CaseIterable {
    case show = "SHOW"
    case animation = "ANIMATION"
    case color = "COLOR"
    case unknown = "UNKNOWN"
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
        colors: String,
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

    var id: String { "\(timestampMs)-\(hex.prefix(16))" }
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
}

struct AutoResponseRule: Identifiable, Codable, Equatable {
    var id: Int64
    var name: String
    var triggerPatternId: String
    var responsePatternId: String
    var responseHex: String
    var enabled: Bool
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
