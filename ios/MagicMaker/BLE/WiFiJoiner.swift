import Foundation
import NetworkExtension

enum WiFiJoiner {
    static func join(ssid: String, password: String, onComplete: @escaping (String) -> Void) {
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        config.joinOnce = false
        NEHotspotConfigurationManager.shared.apply(config) { error in
            DispatchQueue.main.async {
                if let error {
                    onComplete("WiFi join failed: \(error.localizedDescription)")
                } else {
                    onComplete("Joined \(ssid)")
                }
            }
        }
    }
}
