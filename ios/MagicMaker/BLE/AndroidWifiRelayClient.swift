import Foundation

/// HTTP relay to Android foreground service (WiFi hotspot mode).
final class AndroidWifiRelayClient {
    static let shared = AndroidWifiRelayClient()

    var onStatus: ((String) -> Void)?

    private var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    private(set) var lastStatus = "WiFi relay idle"

    func transmit(hex: String, durationMs: Double, onComplete: @escaping (Bool) -> Void) {
        let canonical = HexUtils.canonicalHex(hex)
        let url = RelaySettings.androidBaseURL.appendingPathComponent("transmit")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["hex": canonical, "durationMs": Int(durationMs)]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        onStatus?("Android WiFi → broadcasting…")
        lastStatus = "Transmitting via WiFi…"

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastStatus = "WiFi relay error: \(error.localizedDescription)"
                    self.onStatus?(self.lastStatus)
                    onComplete(false)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    self.lastStatus = "Connected — Android broadcasting"
                    self.onStatus?("Android broadcasting — hold phone near MagicBand")
                    onComplete(true)
                } else {
                    self.lastStatus = "WiFi relay HTTP \(code)"
                    self.onStatus?(self.lastStatus)
                    onComplete(false)
                }
            }
        }.resume()
    }

    func refreshStatus(onComplete: ((String) -> Void)? = nil) {
        fetchRemoteStatus { status in
            if let status {
                self.lastStatus = status.running ? "Connected — \(status.status)" : "Android idle"
            } else {
                self.lastStatus = "Not connected — check hotspot + IP"
            }
            onComplete?(self.lastStatus)
        }
    }

    func fetchRemoteStatus(onComplete: @escaping (AndroidRemoteStatus?) -> Void) {
        let url = RelaySettings.androidBaseURL.appendingPathComponent("status")
        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    onComplete(nil)
                    return
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    onComplete(nil)
                    return
                }
                onComplete(AndroidRemoteStatus.parse(json))
            }
        }.resume()
    }

    func sendControl(_ body: [String: Any], onComplete: @escaping (Bool) -> Void) {
        let url = RelaySettings.androidBaseURL.appendingPathComponent("control")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    self.onStatus?("WiFi control error")
                    onComplete(false)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                onComplete(code == 200)
            }
        }.resume()
    }
}
