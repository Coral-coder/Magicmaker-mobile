import Foundation

struct AndroidRemoteStatus: Equatable {
    var running = false
    var status = ""
    var scanActive = false
    var autoEnabled = false
    var recordSessionActive = false
    var activeSessionName = ""
    var packetsHeard = 0
    var autoResponsesSent = 0
    var lastHeardHex = ""
    var lastHeardLabel = ""
    var relayLinked = false
    var starlightLoopEnabled = false
    var starlightLoopLabel = ""
    var starlightLoopPacketId: Int64 = -1
    var starlightIntervalMs: Int64 = 3000
    var txLoopEnabled = false
    var txLoopLabel = ""
    var txLoopPacketId: Int64 = -1
    var txLoopIntervalMs: Int64 = 3000
    var wandDisplayColorIndex = 0x1B
    var wakeupPreambleMs = 520
    var commandBurstMs = 2000
    var starlightBurstMs = 500
    var storeRevision = 0

    static func parse(_ json: [String: Any]) -> AndroidRemoteStatus {
        var s = AndroidRemoteStatus()
        s.running = json["running"] as? Bool ?? false
        s.status = json["status"] as? String ?? ""
        s.scanActive = json["scanActive"] as? Bool ?? false
        s.autoEnabled = json["autoEnabled"] as? Bool ?? false
        s.recordSessionActive = json["recordSessionActive"] as? Bool ?? false
        s.activeSessionName = json["activeSessionName"] as? String ?? ""
        s.packetsHeard = json["packetsHeard"] as? Int ?? 0
        s.autoResponsesSent = json["autoResponsesSent"] as? Int ?? 0
        s.lastHeardHex = json["lastHeardHex"] as? String ?? ""
        s.lastHeardLabel = json["lastHeardLabel"] as? String ?? ""
        s.relayLinked = json["relayLinked"] as? Bool ?? false
        s.starlightLoopEnabled = json["starlightLoopEnabled"] as? Bool ?? false
        s.starlightLoopLabel = json["starlightLoopLabel"] as? String ?? ""
        s.starlightLoopPacketId = (json["starlightLoopPacketId"] as? Int64) ?? Int64(json["starlightLoopPacketId"] as? Int ?? -1)
        s.starlightIntervalMs = (json["starlightIntervalMs"] as? Int64) ?? Int64(json["starlightIntervalMs"] as? Int ?? 3000)
        s.txLoopEnabled = json["txLoopEnabled"] as? Bool ?? false
        s.txLoopLabel = json["txLoopLabel"] as? String ?? ""
        s.txLoopPacketId = (json["txLoopPacketId"] as? Int64) ?? Int64(json["txLoopPacketId"] as? Int ?? -1)
        s.txLoopIntervalMs = (json["txLoopIntervalMs"] as? Int64) ?? Int64(json["txLoopIntervalMs"] as? Int ?? 3000)
        s.wandDisplayColorIndex = json["wandDisplayColorIndex"] as? Int ?? 0x1B
        s.wakeupPreambleMs = json["wakeupPreambleMs"] as? Int ?? 520
        s.commandBurstMs = json["commandBurstMs"] as? Int ?? 2000
        s.starlightBurstMs = json["starlightBurstMs"] as? Int ?? 500
        s.storeRevision = json["storeRevision"] as? Int ?? 0
        return s
    }
}

struct AndroidRemotePacket: Identifiable, Equatable {
    let id: String
    let hex: String
    let label: String
    let rssi: Int
    let note: String
    let category: String
    let typeInfo: String
    let dedupeKey: String
    let timestampMs: Int64
}

/// iPhone remote control of Android MagicMaker (WiFi HTTP + BLE GATT command char).
@MainActor
final class AndroidRemoteClient {
    static let shared = AndroidRemoteClient()

    var onStatus: ((String) -> Void)?

    private let wifi = AndroidWifiRelayClient.shared
    private var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    func refreshStatus(central: BleCentral?, onComplete: @escaping (AndroidRemoteStatus?) -> Void) {
        let backend = RelayBackend.load()
        switch backend {
        case .androidWifi:
            wifi.fetchRemoteStatus { status in
                onComplete(status)
            }
        case .androidBle:
            guard let central else {
                onComplete(nil)
                return
            }
            central.relayGatt.readRemoteStatus { status in
                onComplete(status)
            }
        }
    }

    func fetchPairing(central: BleCentral?, onComplete: @escaping (AndroidPairingInfo?) -> Void) {
        let backend = RelayBackend.load()
        switch backend {
        case .androidWifi:
            let url = RelaySettings.androidBaseURL.appendingPathComponent("status")
            session.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    guard error == nil,
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        onComplete(nil)
                        return
                    }
                    onComplete(Self.pairingFromStatus(json))
                }
            }.resume()
        case .androidBle:
            guard let central else {
                onComplete(nil)
                return
            }
            central.relayGatt.sendRemoteCommandJson(["action": "pairing"]) { json in
                onComplete(Self.pairingFromCommand(json))
            }
        }
    }

    private static func pairingFromCommand(_ json: [String: Any]?) -> AndroidPairingInfo? {
        guard let json else { return nil }
        if let info = AndroidPairingInfo.parse(json) { return info }
        if let ssid = json["ssid"] as? String, !ssid.isEmpty {
            var info = AndroidPairingInfo()
            info.ssid = ssid
            info.password = json["password"] as? String ?? ""
            info.ip = json["ip"] as? String ?? "192.168.43.1"
            info.port = json["port"] as? Int ?? 8765
            return info
        }
        return nil
    }

    private static func pairingFromStatus(_ json: [String: Any]?) -> AndroidPairingInfo? {
        guard let json else { return nil }
        if let info = AndroidPairingInfo.parse(json) { return info }
        guard let ssid = json["hotspotSsid"] as? String ?? json["ssid"] as? String, !ssid.isEmpty else {
            return nil
        }
        var info = AndroidPairingInfo()
        info.ssid = ssid
        info.password = json["hotspotPassword"] as? String ?? json["password"] as? String ?? ""
        info.ip = json["relayIp"] as? String ?? json["ip"] as? String ?? "192.168.43.1"
        info.port = json["httpPort"] as? Int ?? json["port"] as? Int ?? 8765
        return info
    }

    func sendCommand(_ action: String, params: [String: Any] = [:], central: BleCentral?, onComplete: @escaping (Bool) -> Void) {
        var body = params
        body["action"] = action
        let backend = RelayBackend.load()
        switch backend {
        case .androidWifi:
            wifi.sendControl(body) { ok in
                onComplete(ok)
            }
        case .androidBle:
            guard let central else {
                onComplete(false)
                return
            }
            central.relayGatt.sendRemoteCommand(body) { ok in
                onComplete(ok)
            }
        }
    }

    func fetchLivePackets(central: BleCentral?, onComplete: @escaping ([AndroidRemotePacket]) -> Void) {
        let backend = RelayBackend.load()
        switch backend {
        case .androidWifi:
            guard backend.usesWifiRelay else {
                onComplete([])
                return
            }
            let url = RelaySettings.androidBaseURL.appendingPathComponent("live")
            session.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    onComplete(Self.parseLivePackets(data: data, response: response, error: error))
                }
            }.resume()
        case .androidBle:
            guard let central else {
                onComplete([])
                return
            }
            central.relayGatt.sendRemoteCommandJson(["action": "live"]) { json in
                onComplete(Self.parseLivePackets(json: json))
            }
        }
    }

    func fetchCatalog(
        central: BleCentral?,
        previousCatalog: AndroidRemoteCatalog? = nil,
        onDiagnostic: ((String) -> Void)? = nil,
        onComplete: @escaping (AndroidRemoteCatalog?) -> Void
    ) {
        fetchCatalog(central: central, previousCatalog: previousCatalog, attempt: 0, onDiagnostic: onDiagnostic, onComplete: onComplete)
    }

    private func fetchCatalog(
        central: BleCentral?,
        previousCatalog: AndroidRemoteCatalog?,
        attempt: Int,
        onDiagnostic: ((String) -> Void)?,
        onComplete: @escaping (AndroidRemoteCatalog?) -> Void
    ) {
        let backend = RelayBackend.load()
        switch backend {
        case .androidWifi:
            onDiagnostic?("wifi /catalog")
            fetchCatalogViaHttp(onDiagnostic: onDiagnostic, onComplete: onComplete)
        case .androidBle:
            guard let central else {
                onDiagnostic?("BLE not linked")
                onComplete(nil)
                return
            }
            guard central.relayGatt.isCommandReady else {
                onDiagnostic?("BLE command channel not ready")
                fetchCatalogLegacyBle(
                    central: central,
                    attempt: attempt,
                    onDiagnostic: onDiagnostic,
                    onComplete: onComplete
                )
                return
            }
            fetchCatalogChunkedWithRetry(
                central: central,
                previousCatalog: previousCatalog,
                syncAttempt: 0,
                onDiagnostic: onDiagnostic,
                onComplete: { catalog in
                    if let catalog, !catalog.transmitPresets.isEmpty {
                        onComplete(catalog)
                        return
                    }
                    onDiagnostic?("chunks failed — BLE fallback…")
                    self.fetchCatalogLegacyBle(
                        central: central,
                        attempt: attempt,
                        onDiagnostic: onDiagnostic,
                        onComplete: onComplete
                    )
                }
            )
        }
    }

    private func fetchCatalogChunkedWithRetry(
        central: BleCentral,
        previousCatalog: AndroidRemoteCatalog?,
        syncAttempt: Int,
        onDiagnostic: ((String) -> Void)?,
        onComplete: @escaping (AndroidRemoteCatalog?) -> Void
    ) {
        let label = syncAttempt == 0 ? "chunked sync…" : "chunk retry \(syncAttempt + 1)…"
        onDiagnostic?(label)
        fetchCatalogChunked(central: central, previousCatalog: previousCatalog, onDiagnostic: onDiagnostic) { catalog in
            if let catalog, !catalog.transmitPresets.isEmpty {
                onComplete(catalog)
                return
            }
            if syncAttempt < 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.fetchCatalogChunkedWithRetry(
                        central: central,
                        previousCatalog: previousCatalog,
                        syncAttempt: syncAttempt + 1,
                        onDiagnostic: onDiagnostic,
                        onComplete: onComplete
                    )
                }
                return
            }
            onComplete(nil)
        }
    }

    private func fetchCatalogLegacyBle(
        central: BleCentral,
        attempt: Int,
        onDiagnostic: ((String) -> Void)?,
        onComplete: @escaping (AndroidRemoteCatalog?) -> Void
    ) {
        if central.relayGatt.isCatalogReady {
            central.relayGatt.readHandshakeCatalog { json in
                if let json, let catalog = AndroidRemoteCatalog.parse(json), !catalog.transmitPresets.isEmpty {
                    onComplete(catalog)
                    return
                }
                self.continueBleCatalogFetch(
                    central: central,
                    attempt: attempt,
                    onDiagnostic: onDiagnostic,
                    onComplete: onComplete
                )
            }
        } else {
            continueBleCatalogFetch(
                central: central,
                attempt: attempt,
                onDiagnostic: onDiagnostic,
                onComplete: onComplete
            )
        }
    }

    private func continueBleCatalogFetch(
        central: BleCentral,
        attempt: Int,
        onDiagnostic: ((String) -> Void)?,
        onComplete: @escaping (AndroidRemoteCatalog?) -> Void
    ) {
        guard central.relayGatt.isCommandReady else {
            onDiagnostic?("BLE not ready")
            onComplete(nil)
            return
        }
        central.relayGatt.refreshCatalogFromAndroid { refreshJson in
            if let refreshJson,
               let catalog = AndroidRemoteCatalog.parse(refreshJson),
               !catalog.transmitPresets.isEmpty {
                onComplete(catalog)
                return
            }
            if attempt < 3 {
                onDiagnostic?("retry \(attempt + 1)/3…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.fetchCatalog(
                        central: central,
                        previousCatalog: nil,
                        attempt: attempt + 1,
                        onDiagnostic: onDiagnostic,
                        onComplete: onComplete
                    )
                }
                return
            }
            onDiagnostic?("BLE sync failed")
            onComplete(nil)
        }
    }

    private func fetchCatalogViaHttp(
        onDiagnostic: ((String) -> Void)? = nil,
        onComplete: @escaping (AndroidRemoteCatalog?) -> Void
    ) {
        let url = RelaySettings.androidBaseURL.appendingPathComponent("catalog")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let catalog = AndroidRemoteCatalog.parse(json),
                      !catalog.transmitPresets.isEmpty else {
                    onComplete(nil)
                    return
                }
                onComplete(catalog)
            }
        }.resume()
    }

    private static func parseLivePackets(data: Data?, response: URLResponse?, error: Error?) -> [AndroidRemotePacket] {
        guard error == nil,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parseLivePackets(json: json)
    }

    private static func parseLivePackets(json: [String: Any]?) -> [AndroidRemotePacket] {
        guard let json,
              let packets = json["packets"] as? [[String: Any]] else {
            return []
        }
        return packets.compactMap { p -> AndroidRemotePacket? in
            guard let hex = p["hex"] as? String else { return nil }
            let label = p["label"] as? String ?? "?"
            let rssi = p["rssi"] as? Int ?? 0
            let note = p["note"] as? String ?? ""
            let category = p["category"] as? String ?? "UNKNOWN"
            let typeInfo = p["typeInfo"] as? String ?? "raw"
            let ts = (p["timestampMs"] as? Int64) ?? Int64(p["timestampMs"] as? Int ?? 0)
            let classified = MagicClassifier.classify(hex)
            let dedupeKey = (p["dedupeKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? LivePacketSort.liveDedupeKey(hex: hex, classified: classified)
            return AndroidRemotePacket(
                id: "\(hex)-\(ts)",
                hex: hex,
                label: label,
                rssi: rssi,
                note: note,
                category: category,
                typeInfo: typeInfo,
                dedupeKey: dedupeKey,
                timestampMs: ts
            )
        }
    }

    private func fetchCatalogChunked(
        central: BleCentral,
        previousCatalog: AndroidRemoteCatalog?,
        onDiagnostic: ((String) -> Void)?,
        onComplete: @escaping (AndroidRemoteCatalog?) -> Void
    ) {
        CatalogChunkSync.fetch(
            central: central,
            previousCatalog: previousCatalog,
            onDiagnostic: onDiagnostic,
            onComplete: onComplete
        )
    }
}

// MARK: - Chunked BLE catalog sync (fits within GATT STATUS 512-byte limit)

private enum CatalogChunkSync {
    private static let maxChunkAttempts = 5
    private static let interChunkDelay: TimeInterval = 0.1

    static func fetch(
        central: BleCentral,
        previousCatalog: AndroidRemoteCatalog? = nil,
        onDiagnostic: ((String) -> Void)?,
        onComplete: @escaping (AndroidRemoteCatalog?) -> Void
    ) {
        guard central.relayGatt.isCommandReady else {
            onDiagnostic?("begin: command channel not ready")
            onComplete(nil)
            return
        }
        central.relayGatt.sendRemoteCommandJson(["action": "catalog_sync_begin"]) { meta in
            guard let meta, meta["ok"] as? Bool == true, jsonInt(meta["protocol"]) == 1 else {
                let err = (meta?["error"] as? String) ?? "bad begin response"
                onDiagnostic?("begin failed: \(err)")
                onComplete(nil)
                return
            }
            let txChunks = jsonInt(meta["txChunks"]) ?? 0
            let txCount = jsonInt(meta["txCount"]) ?? 0
            onDiagnostic?("begin ok · tx \(txCount) · \(txChunks) chunks")
            var catalog = AndroidRemoteCatalog()
            catalog.wakeupPreambleMs = jsonInt(meta["wakeupPreambleMs"]) ?? 520
            catalog.commandBurstMs = jsonInt(meta["commandBurstMs"]) ?? 2000
            catalog.starlightBurstMs = jsonInt(meta["starlightBurstMs"]) ?? 500

            fetchPresetChunks(
                central: central,
                section: "tx",
                total: jsonInt(meta["txChunks"]) ?? 0,
                index: 0,
                accumulated: [],
                chunkAttempt: 0,
                onDiagnostic: onDiagnostic
            ) { tx in
                guard let tx else {
                    onDiagnostic?("tx chunks failed")
                    onComplete(nil)
                    return
                }
                catalog.transmitPresets = tx
                onDiagnostic?("tx \(tx.count) presets")
                fetchPresetChunks(
                    central: central,
                    section: "wand",
                    total: jsonInt(meta["wandChunks"]) ?? 0,
                    index: 0,
                    accumulated: [],
                    chunkAttempt: 0,
                    onDiagnostic: onDiagnostic
                ) { wand in
                    guard let wand else {
                        onDiagnostic?("wand chunks failed")
                        onComplete(nil)
                        return
                    }
                    catalog.wandColors = wand
                    fetchRuleChunks(
                        central: central,
                        total: jsonInt(meta["ruleChunks"]) ?? 0,
                        index: 0,
                        accumulated: [],
                        chunkAttempt: 0,
                        onDiagnostic: onDiagnostic
                    ) { rules in
                        if let rules {
                            catalog.autoRules = rules
                        } else if let previous = previousCatalog, !previous.autoRules.isEmpty {
                            onDiagnostic?("rules skipped — keeping \(previous.autoRules.count) cached")
                            catalog.autoRules = previous.autoRules
                        } else {
                            onDiagnostic?("rules skipped (TX/wand ok)")
                            catalog.autoRules = []
                        }
                        if catalog.transmitPresets.isEmpty {
                            onDiagnostic?("done but 0 TX presets")
                            onComplete(nil)
                        } else {
                            onComplete(catalog)
                        }
                    }
                }
            }
        }
    }

    private static func fetchPresetChunks(
        central: BleCentral,
        section: String,
        total: Int,
        index: Int,
        accumulated: [AndroidRemotePreset],
        chunkAttempt: Int,
        onDiagnostic: ((String) -> Void)?,
        onComplete: @escaping ([AndroidRemotePreset]?) -> Void
    ) {
        if total == 0 || index >= total {
            onComplete(accumulated)
            return
        }
        central.relayGatt.sendRemoteCommandJson([
            "action": "catalog_sync_chunk",
            "section": section,
            "index": index,
        ]) { json in
            guard let json, isValidChunkResponse(json) else {
                let err: String
                if let json {
                    if json["running"] != nil { err = "got status instead of chunk" }
                    else if let e = json["error"] as? String { err = e }
                    else { err = "bad chunk json" }
                } else {
                    err = "no response"
                }
                if chunkAttempt + 1 < maxChunkAttempts {
                    onDiagnostic?("\(section)[\(index)] retry \(chunkAttempt + 2)…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        fetchPresetChunks(
                            central: central,
                            section: section,
                            total: total,
                            index: index,
                            accumulated: accumulated,
                            chunkAttempt: chunkAttempt + 1,
                            onDiagnostic: onDiagnostic,
                            onComplete: onComplete
                        )
                    }
                    return
                }
                onDiagnostic?("\(section)[\(index)] failed: \(err)")
                onComplete(nil)
                return
            }
            let parsed = parsePresetItems(json["items"])
            var next = accumulated
            next.append(contentsOf: parsed)
            let scheduleNext = {
                fetchPresetChunks(
                    central: central,
                    section: section,
                    total: total,
                    index: index + 1,
                    accumulated: next,
                    chunkAttempt: 0,
                    onDiagnostic: onDiagnostic,
                    onComplete: onComplete
                )
            }
            if index + 1 < total {
                DispatchQueue.main.asyncAfter(deadline: .now() + interChunkDelay, execute: scheduleNext)
            } else {
                scheduleNext()
            }
        }
    }

    private static func fetchRuleChunks(
        central: BleCentral,
        total: Int,
        index: Int,
        accumulated: [AndroidRemoteAutoRule],
        chunkAttempt: Int,
        onDiagnostic: ((String) -> Void)?,
        onComplete: @escaping ([AndroidRemoteAutoRule]?) -> Void
    ) {
        if total == 0 || index >= total {
            onComplete(accumulated)
            return
        }
        central.relayGatt.sendRemoteCommandJson([
            "action": "catalog_sync_chunk",
            "section": "rules",
            "index": index,
        ]) { json in
            guard let json, isValidChunkResponse(json) else {
                let err: String
                if let json {
                    if json["running"] != nil { err = "got status instead of chunk" }
                    else if let e = json["error"] as? String { err = e }
                    else { err = "bad chunk json" }
                } else {
                    err = "no response"
                }
                if chunkAttempt + 1 < maxChunkAttempts {
                    onDiagnostic?("rules[\(index)] retry \(chunkAttempt + 2)…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        fetchRuleChunks(
                            central: central,
                            total: total,
                            index: index,
                            accumulated: accumulated,
                            chunkAttempt: chunkAttempt + 1,
                            onDiagnostic: onDiagnostic,
                            onComplete: onComplete
                        )
                    }
                    return
                }
                onDiagnostic?("rules[\(index)] failed: \(err)")
                onComplete(nil)
                return
            }
            let parsed = parseRuleItems(json["items"])
            var next = accumulated
            next.append(contentsOf: parsed)
            let scheduleNext = {
                fetchRuleChunks(
                    central: central,
                    total: total,
                    index: index + 1,
                    accumulated: next,
                    chunkAttempt: 0,
                    onDiagnostic: onDiagnostic,
                    onComplete: onComplete
                )
            }
            if index + 1 < total {
                DispatchQueue.main.asyncAfter(deadline: .now() + interChunkDelay, execute: scheduleNext)
            } else {
                scheduleNext()
            }
        }
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Int64 { return Int(v) }
        if let v = value as? Double { return Int(v) }
        if let v = value as? NSNumber { return v.intValue }
        return nil
    }

    private static func isValidChunkResponse(_ json: [String: Any]?) -> Bool {
        guard let json, json["ok"] as? Bool == true, json["items"] != nil else { return false }
        if json["running"] != nil { return false }
        return true
    }

    private static func parsePresetItems(_ value: Any?) -> [AndroidRemotePreset] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return AndroidRemotePreset.parse(dict)
        }
    }

    private static func parseRuleItems(_ value: Any?) -> [AndroidRemoteAutoRule] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return AndroidRemoteAutoRule.parse(dict)
        }
    }
}
