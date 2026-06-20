import Foundation

/// Parses Hawkeye `rawLightSequenceString` (base64) from MDE CMS into transmit hex.
enum MdeLightSequence {
    /// Scan decoded CMS bytes for an embedded 8301 Disney command payload.
    static func transmitHex(fromBase64 base64: String) -> String? {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              !data.isEmpty else { return nil }
        return transmitHex(from: data)
    }

    static func transmitHex(from data: Data) -> String? {
        let bytes = [UInt8](data)
        if let embedded = find8301(in: bytes) { return embedded }
        // Some sequences are raw command bytes without 8301 prefix.
        if bytes.count >= 8, bytes[0] == 0xE9 || bytes[0] == 0xE1 {
            return "8301" + bytes.map { String(format: "%02X", $0) }.joined()
        }
        return nil
    }

    private static func find8301(in bytes: [UInt8]) -> String? {
        for i in 0..<bytes.count {
            if i + 1 < bytes.count, bytes[i] == 0x83, bytes[i + 1] == 0x01 {
                return bytes[i...].map { String(format: "%02X", $0) }.joined()
            }
        }
        return nil
    }
}
