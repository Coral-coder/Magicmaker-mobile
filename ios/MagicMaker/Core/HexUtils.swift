#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation

enum HexUtils {
    static let disneyCompanyId: UInt16 = 0x0183
    static let maxMfgPayloadBytes = 27
    static let magicMakerLocalNamePrefix = "MM:"

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")
    private static let markerCF9B: [UInt8] = Array("CF9B".utf8)
    private static let markerCF0B: [UInt8] = Array("CF0B".utf8)

    static func bytesToHex(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 0x0F)])
        }
        return out
    }

    static func hexToBytes(_ hex: String) -> [UInt8] {
        let clean = Array(hex.uppercased().filter { "0123456789ABCDEF".contains($0) })
        // Tolerate an odd trailing nibble (e.g. mid-edit in the Lab hex field) by dropping it,
        // rather than trapping — callers run on every keystroke and must not crash.
        let byteCount = clean.count / 2
        var out: [UInt8] = []
        out.reserveCapacity(byteCount)
        for i in 0..<byteCount {
            out.append(UInt8(String(clean[(i * 2)..<(i * 2 + 2)]), radix: 16) ?? 0)
        }
        return out
    }

    static func canonicalHex(_ hex: String) -> String {
        let clean = hex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        if clean.hasPrefix("8301") { return clean }
        if clean.hasPrefix("CF9B") || clean.hasPrefix("CF0B") { return "8301" + clean }
        if !clean.isEmpty { return "8301" + clean }
        return clean
    }

    static func isStarlightPacket(_ hex: String) -> Bool {
        let h = canonicalHex(hex)
        return h.contains("CF9B") || h.contains("CF0B")
    }

    /// True when a starlight ADV includes the serial + color byte (not a truncated UUID slice).
    static func hasCompleteStarlightPayload(_ hex: String) -> Bool {
        let h = canonicalHex(hex)
        guard isStarlightPacket(h) else { return false }
        guard let cf9bPos = h.range(of: "CF9B")?.lowerBound ?? h.range(of: "CF0B")?.lowerBound else { return false }
        var pos = h.distance(from: h.startIndex, to: cf9bPos) + 4
        let chars = Array(h)
        if pos + 2 <= chars.count, String(chars[pos..<(pos + 2)]) == "00" { pos += 2 }
        return pos + StarlightSerial.serialHexLen + 2 <= chars.count
    }

    static func isDisneyBlePacket(_ hex: String) -> Bool {
        let clean = canonicalHex(hex)
        return clean.count >= 4 && clean.count % 2 == 0
    }

    static func isDisneyManufacturerData(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let bytes = [UInt8](data)
        let companyId = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        return companyId == disneyCompanyId
    }

    /// Payload after the 8301 prefix (what follows company ID 0x0183 on-air).
    static func iosMfgPayload(_ hex: String) -> Data {
        let bytes = hexToBytes(canonicalHex(hex))
        if bytes.count >= 2, bytes[0] == 0x83, bytes[1] == 0x01 {
            return Data(bytes.dropFirst(2))
        }
        return Data(bytes)
    }

    static func canonicalFromMfgData(_ data: Data) -> String {
        canonicalFromMfgBytes([UInt8](data))
    }

    static func canonicalFromMfgBytes(_ bytes: [UInt8]) -> String {
        if bytes.count >= 2, bytes[0] == 0x83, bytes[1] == 0x01 {
            return bytesToHex(bytes)
        }
        return "8301" + bytesToHex(bytes)
    }

    /// Manufacturer payload as an advertiser takes it: without the company ID bytes.
    static func disneyAdvertisePayload(_ hex: String) -> Data {
        iosMfgPayload(hex)
    }

    /// Manufacturer block for CoreBluetooth relay: company ID + payload.
    static func disneyManufacturerBlock(_ hex: String) -> Data {
        var mfg = Data([0x83, 0x01])
        mfg.append(iosMfgPayload(hex))
        return mfg
    }

    /// Full AD structure for raw HCI LE Set Advertising Data.
    static func disneyLeAdvertisingBytes(_ hex: String) -> Data {
        let mfg = disneyManufacturerBlock(hex)
        let adLen = UInt8(clamping: 1 + mfg.count)
        var ad = Data([adLen, 0xFF])
        ad.append(mfg)
        return ad
    }

    static func legacyAdvertiseRejectReason(_ hex: String) -> String? {
        let payload = iosMfgPayload(hex)
        if payload.isEmpty { return "Empty packet" }
        if payload.count > maxMfgPayloadBytes {
            return "Packet too long for BLE ADV (\(payload.count) bytes, max \(maxMfgPayloadBytes))"
        }
        // AD structure: type byte + company ID + payload, and its own length byte on top.
        let adLen = 1 + 2 + payload.count
        if adLen + 1 > 31 { return "Packet too long for BLE ADV" }
        return nil
    }

    static func hexFromMagicMakerLocalName(_ name: String) -> String? {
        guard name.hasPrefix(magicMakerLocalNamePrefix) else { return nil }
        let hex = String(name.dropFirst(magicMakerLocalNamePrefix.count))
        guard isDisneyBlePacket(hex) else { return nil }
        return canonicalHex(hex)
    }

    #if canImport(CoreBluetooth)
    static func hexFromAdvertisementUUID(_ uuid: CBUUID) -> String? {
        hexFromAdvertisementUUIDBytes([UInt8](uuid.data))
    }
    #endif

    /// A 16- or 32-bit service UUID in its full 128-bit form (Bluetooth base UUID), which is the
    /// form Android searches. Anything else is returned unchanged.
    private static func fullUUIDBytes(_ bytes: [UInt8]) -> [UInt8] {
        let baseTail: [UInt8] = [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB]
        var out: [UInt8] = []
        if bytes.count == 2 {
            out.append(0x00)
            out.append(0x00)
        } else if bytes.count != 4 {
            return bytes
        }
        out.append(contentsOf: bytes)
        out.append(contentsOf: baseTail)
        return out
    }

    /// Starlight / Disney packets embedded in a BLE service UUID (iOS path).
    static func hexFromAdvertisementUUIDBytes(_ uuidBytes: [UInt8]) -> String? {
        let bytes = fullUUIDBytes(uuidBytes)
        if bytes.count >= 3, bytes[0] == 0x83, bytes[1] == 0x01 {
            let length = Int(bytes[2])
            if length > 0, length <= maxMfgPayloadBytes + 2, 3 + length <= bytes.count {
                return bytesToHex(Array(bytes[0..<(3 + length)]))
            }
        }
        return scanForDisneyMarker(bytes)
    }

    static func hexFromServiceData(_ bytes: [UInt8]) -> String? {
        if bytes.count >= 2, bytes[0] == 0x83, bytes[1] == 0x01 {
            return bytesToHex(bytes)
        }
        return scanForDisneyMarker(bytes)
    }

    /// A blob with a wand marker (CF9B / CF0B) somewhere inside it: everything from the earliest
    /// marker on, as canonical hex. The search runs over the hex text, so a marker that straddles
    /// a byte boundary is found too and yields an odd-length result; `pickBestDisneyHex` drops those.
    static func scanForDisneyMarker(_ bytes: [UInt8]) -> String? {
        if bytes.count < 4 { return nil }
        let hex = bytesToHex(bytes)
        let text = Array(hex.utf8)
        let cf9b = indexOf(markerCF9B, in: text)
        let cf0b = indexOf(markerCF0B, in: text)
        let idx: Int
        if cf9b >= 0 && cf0b >= 0 {
            idx = min(cf9b, cf0b)
        } else if cf9b >= 0 {
            idx = cf9b
        } else if cf0b >= 0 {
            idx = cf0b
        } else {
            return nil
        }
        return canonicalHex(String(hex.dropFirst(idx)))
    }

    /// Offset of the first `needle` in `haystack`, or -1.
    private static func indexOf(_ needle: [UInt8], in haystack: [UInt8]) -> Int {
        if needle.isEmpty { return 0 }
        if haystack.count < needle.count { return -1 }
        let last = haystack.count - needle.count
        var start = 0
        while start <= last {
            var j = 0
            while j < needle.count && haystack[start + j] == needle[j] { j += 1 }
            if j == needle.count { return start }
            start += 1
        }
        return -1
    }

    /// Ranks payload candidates: longer is better, a wand packet beats anything else, and a wand
    /// packet that still has its serial and colour byte beats a truncated one.
    static func disneyHexScore(_ hex: String) -> Int {
        let h = canonicalHex(hex)
        var score = h.count
        if isStarlightPacket(h) { score += 200 }
        if hasCompleteStarlightPayload(h) { score += 150 }
        if StarlightSerial.extractSerial(h) != nil { score += 50 }
        return score
    }

    /// The highest-scoring valid candidate; the earliest one wins a tie.
    static func pickBestDisneyHex(_ candidates: [String]) -> String? {
        var seen = Set<String>()
        var best: String? = nil
        var bestScore = 0
        for raw in candidates {
            let hex = canonicalHex(raw)
            if !isDisneyBlePacket(hex) { continue }
            if !seen.insert(hex).inserted { continue }
            let score = disneyHexScore(hex)
            if best == nil || score > bestScore {
                best = hex
                bestScore = score
            }
        }
        return best
    }

    static func bestDisneyHex(candidates: [String]) -> String? {
        pickBestDisneyHex(candidates)
    }

    /// Every Disney payload one advertisement carries, for `bestDisneyHex(candidates:)`.
    ///
    /// `manufacturerData` is the blob as CoreBluetooth delivers it, company ID bytes first. Only
    /// what CoreBluetooth exposes can be searched: one manufacturer entry, the service UUIDs, the
    /// service data and the local name. The raw advertisement bytes are not available here.
    static func extractDisneyCandidates(
        manufacturerData: [UInt8]?,
        serviceData: [[UInt8]],
        serviceUUIDBytes: [[UInt8]],
        localName: String?
    ) -> [String] {
        var out: [String] = []

        if let mfg = manufacturerData, mfg.count > 2 {
            let payload = Array(mfg[2...])
            if mfg[0] == 0x83, mfg[1] == 0x01 {
                let hex = canonicalFromMfgBytes(payload)
                if isDisneyBlePacket(hex) { out.append(hex) }
            }
            // Any company's data can still wrap a Disney payload or a wand marker.
            if let hex = hexFromServiceData(payload) { out.append(hex) }
        }

        if let name = localName, let hex = hexFromMagicMakerLocalName(name) {
            out.append(hex)
        }

        for bytes in serviceUUIDBytes {
            if let hex = hexFromAdvertisementUUIDBytes(bytes) { out.append(hex) }
        }
        for bytes in serviceData {
            if let hex = hexFromServiceData(bytes) { out.append(hex) }
        }

        // Android also reads the manufacturer structure straight from the raw advertisement,
        // company ID bytes included.
        if let mfg = manufacturerData, let hex = hexFromManufacturerStructure(mfg) {
            out.append(hex)
        }
        return out
    }

    /// What `extractDisneyPayload(ad:)` returns for one manufacturer structure, company ID first.
    private static func hexFromManufacturerStructure(_ data: [UInt8]) -> String? {
        if data.count < 2 { return nil }
        if data[0] == 0x83, data[1] == 0x01 { return bytesToHex(data) }
        return scanForDisneyMarker(data)
    }

    static func extractDisneyPayload(ad: [UInt8]) -> String? {
        var i = 0
        while i < ad.count {
            let len = Int(ad[i])
            if len == 0 { break }
            let typeIndex = i + 1
            if typeIndex >= ad.count { break }
            let type = ad[typeIndex]
            let dataStart = typeIndex + 1
            let dataEnd = i + 1 + len
            if dataEnd > ad.count { break }
            if type == 0xFF, dataEnd - dataStart >= 2 {
                let data = Array(ad[dataStart..<dataEnd])
                if data[0] == 0x83, data[1] == 0x01 {
                    return bytesToHex(data)
                }
                if let hex = scanForDisneyMarker(data) { return hex }
            }
            i += len + 1
        }
        return nil
    }
}
