import Foundation

enum RelayBackend: String, CaseIterable, Identifiable {
    case androidBle
    case esp32
    case androidWifi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .androidBle: return "Android BLE"
        case .esp32: return "ESP32"
        case .androidWifi: return "WiFi Hotspot"
        }
    }

    // Both BLE backends link over the same relay GATT service; the ESP32 firmware
    // implements the same contract, so the transmit path is identical.
    var usesBleRelayLink: Bool { self == .androidBle || self == .esp32 }
    var usesWifiRelay: Bool { self == .androidWifi }

    static func load() -> RelayBackend {
        let raw = UserDefaults.standard.string(forKey: "relay_backend") ?? RelayBackend.androidBle.rawValue
        if raw == "androidLocal" { return .androidBle }
        return RelayBackend(rawValue: raw) ?? .androidBle
    }

    static func save(_ backend: RelayBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: "relay_backend")
    }
}

enum RelaySettings {
    private static let ipKey = "android_relay_ip"
    private static let portKey = "android_relay_port"

    static var androidRelayIP: String {
        get { UserDefaults.standard.string(forKey: ipKey) ?? "192.168.43.1" }
        set { UserDefaults.standard.set(newValue, forKey: ipKey) }
    }

    static var androidRelayPort: Int {
        get {
            let p = UserDefaults.standard.integer(forKey: portKey)
            return p == 0 ? 8765 : p
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    static var androidBaseURL: URL {
        URL(string: "http://\(androidRelayIP):\(androidRelayPort)")!
    }
}

struct AndroidPairingInfo: Equatable {
    var ssid = ""
    var password = ""
    var ip = ""
    var port = 8765

    static func parse(_ json: [String: Any]) -> AndroidPairingInfo? {
        guard json["magicmaker"] as? Bool == true || json["ssid"] != nil else { return nil }
        var info = AndroidPairingInfo()
        info.ssid = json["ssid"] as? String ?? ""
        info.password = json["password"] as? String ?? ""
        info.ip = json["ip"] as? String ?? ""
        info.port = json["port"] as? Int ?? 8765
        return info.ssid.isEmpty ? nil : info
    }

    static func parseWiFiQR(_ string: String) -> AndroidPairingInfo? {
        guard string.hasPrefix("WIFI:") else { return nil }
        var ssid = ""
        var password = ""
        let parts = string.dropFirst(5).split(separator: ";", omittingEmptySubsequences: false)
        for part in parts {
            let p = String(part)
            if p.hasPrefix("S:") { ssid = String(p.dropFirst(2)).replacingOccurrences(of: "\\;", with: ";") }
            if p.hasPrefix("P:") { password = String(p.dropFirst(2)).replacingOccurrences(of: "\\;", with: ";") }
        }
        guard !ssid.isEmpty else { return nil }
        var info = AndroidPairingInfo()
        info.ssid = ssid
        info.password = password
        info.ip = "192.168.43.1"
        info.port = 8765
        return info
    }
}
