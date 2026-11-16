import Foundation

/// Low-level helpers for the Lab packet inspector — byte-level editing plus the well-defined
/// fields (vibration tail nibble) that every esp32_magicband command shares. Kept deliberately
/// structural so it works on any captured packet, not just the ones the builder can synthesize.
///
/// Port of Android `core/LabPacketTools.kt`.
enum LabPacketTools {
    /// Split a hex string into 2-char byte tokens (drops a trailing odd nibble).
    static func toBytes(_ hex: String) -> [String] {
        let clean: [Character] = Array(hex.uppercased().filter { "0123456789ABCDEF".contains($0) })
        let byteCount = clean.count / 2
        var out: [String] = []
        out.reserveCapacity(byteCount)
        for i in 0..<byteCount {
            out.append(String(clean[(i * 2)..<(i * 2 + 2)]))
        }
        return out
    }

    static func fromBytes(_ bytes: [String]) -> String {
        bytes.joined().uppercased()
    }

    /// Vibration value (0–15) encoded in the tail byte `0xB0 | vib`, or nil if no tail.
    static func tailVibration(_ hex: String) -> Int? {
        guard let token = toBytes(hex).last, let last = Int(token, radix: 16) else { return nil }
        if (last & 0xF0) != 0xB0 { return nil }
        return last & 0x0F
    }

    /// Rewrite the tail byte to `0xB0 | vib`. No-op if the packet has no B0–BF tail.
    static func withVibration(_ hex: String, _ vib: Int) -> String {
        var bytes = toBytes(hex)
        guard let token = bytes.last, let last = Int(token, radix: 16) else { return hex }
        if (last & 0xF0) != 0xB0 { return hex }
        bytes[bytes.count - 1] = DisneyTlv.hex2(0xB0 | (vib & 0x0F))
        return fromBytes(bytes)
    }
}
