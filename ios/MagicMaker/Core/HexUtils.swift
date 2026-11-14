#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation

enum HexUtils {
    static let disneyCompanyId: UInt16 = 0x0183
    static let maxMfgPayloadBytes = 27
    static let magicMakerLocalNamePrefix = "MM:"

    static func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
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
        let bytes = [UInt8](data)
        if bytes.count >= 2, bytes[0] == 0x83, bytes[1] == 0x01 {
            return bytesToHex(bytes)
        }
        return "8301" + bytesToHex(bytes)
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
        let adLen = UInt8(1 + mfg.count)
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
        let ad = disneyLeAdvertisingBytes(hex)
        if ad.count > 31 {
            return "Packet too long for BLE ADV (\(ad.count) bytes, max 31)"
        }
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

    static func hexFromAdvertisementUUIDBytes(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 3, bytes[0] == 0x83, bytes[1] == 0x01 else { return nil }
        let length = Int(bytes[2])
        guard length > 0, length <= maxMfgPayloadBytes + 2, 3 + length <= bytes.count else { return nil }
        return bytesToHex(Array(bytes[0..<(3 + length)]))
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
                if ad[dataStart] == 0x83, ad[dataStart + 1] == 0x01 {
                    return bytesToHex(Array(ad[dataStart..<dataEnd]))
                }
            }
            i += len + 1
        }
        return nil
    }
}
