import Foundation

struct AndroidRemotePreset: Identifiable, Equatable {
    let id: Int64
    let hex: String
    let label: String
    let category: String
    let typeInfo: String
    let colors: String
    let userRecorded: Bool
    let wandVerified: Bool

    static func parse(_ json: [String: Any]) -> AndroidRemotePreset? {
        guard let hex = json["hex"] as? String else { return nil }
        let id: Int64
        if let v = json["id"] as? Int64 {
            id = v
        } else if let v = json["id"] as? Int {
            id = Int64(v)
        } else if let v = json["id"] as? Double {
            id = Int64(v)
        } else if let v = json["id"] as? NSNumber {
            id = v.int64Value
        } else {
            id = 0
        }
        return AndroidRemotePreset(
            id: id,
            hex: hex,
            label: json["label"] as? String ?? "?",
            category: json["category"] as? String ?? "UNKNOWN",
            typeInfo: json["typeInfo"] as? String ?? "raw",
            colors: json["colors"] as? String ?? "",
            userRecorded: json["userRecorded"] as? Bool ?? false,
            wandVerified: json["wandVerified"] as? Bool ?? false
        )
    }
}

struct AndroidRemoteAutoRule: Identifiable, Equatable {
    let id: Int64
    let name: String
    let triggerPatternId: String
    let responsePatternId: String
    let enabled: Bool
    let responseHexes: [String]

    static func parse(_ json: [String: Any]) -> AndroidRemoteAutoRule? {
        let id: Int64
        if let v = json["id"] as? Int64 { id = v }
        else if let v = json["id"] as? Int { id = Int64(v) }
        else if let v = json["id"] as? Double { id = Int64(v) }
        else if let v = json["id"] as? NSNumber { id = v.int64Value }
        else { id = 0 }
        let hexes = AndroidRemoteCatalog.parseStringArray(json["responseHexes"])
        return AndroidRemoteAutoRule(
            id: id,
            name: json["name"] as? String ?? "Rule",
            triggerPatternId: json["triggerPatternId"] as? String ?? "?",
            responsePatternId: json["responsePatternId"] as? String ?? "?",
            enabled: json["enabled"] as? Bool ?? true,
            responseHexes: hexes
        )
    }
}

struct AndroidRemoteCatalog: Equatable {
    var wakeupPreambleMs = 520
    var commandBurstMs = 2000
    var starlightBurstMs = 500
    var transmitPresets: [AndroidRemotePreset] = []
    var wandColors: [AndroidRemotePreset] = []
    var autoRules: [AndroidRemoteAutoRule] = []

    static func parse(_ json: [String: Any]) -> AndroidRemoteCatalog? {
        guard json["ok"] as? Bool != false else { return nil }
        // Reject status snapshots mistaken for catalog (GATT read bug / stale buffer).
        guard json["transmitPresets"] != nil else { return nil }
        var catalog = AndroidRemoteCatalog()
        catalog.wakeupPreambleMs = json["wakeupPreambleMs"] as? Int ?? 520
        catalog.commandBurstMs = json["commandBurstMs"] as? Int ?? 2000
        catalog.starlightBurstMs = json["starlightBurstMs"] as? Int ?? 500
        if let presets = json["transmitPresets"] as? [[String: Any]] {
            catalog.transmitPresets = presets.compactMap(AndroidRemotePreset.parse)
        }
        if let wand = json["wandColors"] as? [[String: Any]] {
            catalog.wandColors = wand.compactMap(AndroidRemotePreset.parse)
        }
        if let rules = json["autoRules"] as? [[String: Any]] {
            catalog.autoRules = rules.compactMap(AndroidRemoteAutoRule.parse)
        }
        return catalog
    }

    static func parseStringArray(_ value: Any?) -> [String] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            if let s = item as? String { return s }
            if let n = item as? NSNumber { return n.stringValue }
            return nil
        }
    }
}
