import Foundation

enum StarlightSerial {
    static let serialHexLen = 22
    static let defaultSerial = "C42922EFD819F22A62"

    static func normalizeSerial(_ raw: String) -> String? {
        let s = raw.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard s.count >= serialHexLen else { return nil }
        return String(s.prefix(serialHexLen))
    }

    static func extractSerial(_ hex: String) -> String? {
        let h = hex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        let markerPos = h.range(of: "CF9B")?.lowerBound ?? h.range(of: "CF0B")?.lowerBound
        guard let markerPos else { return nil }
        var pos = h.distance(from: h.startIndex, to: markerPos) + 4
        let chars = Array(h)
        if pos + 2 <= chars.count, String(chars[pos..<(pos + 2)]) == "00" { pos += 2 }
        guard pos + serialHexLen + 2 <= chars.count else { return nil }
        return String(chars[pos..<(pos + serialHexLen)])
    }

    static func marker(from hex: String) -> String {
        let h = hex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        let cf9b = h.range(of: "CF9B")?.lowerBound
        let cf0b = h.range(of: "CF0B")?.lowerBound
        switch (cf9b, cf0b) {
        case (.some(let a), .some(let b)): return a <= b ? "CF9B" : "CF0B"
        case (.some, .none): return "CF9B"
        case (.none, .some): return "CF0B"
        default: return "CF9B"
        }
    }

    static func buildHex(serial: String, colorIndex: Int, marker: String = "CF9B") -> String {
        let ser = normalizeSerial(serial) ?? defaultSerial
        let color = String(format: "%02X", colorIndex & 0x1F)
        let tag = marker == "CF0B" ? "CF0B" : "CF9B"
        return "8301\(tag)00\(ser)\(color)"
    }

    static func validatedSerial(_ raw: String?) -> String {
        normalizeSerial(raw ?? "") ?? defaultSerial
    }

    static func isStoredFormat(_ hex: String) -> Bool {
        let h = hex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        return h.range(of: "^8301(CF9B|CF0B)00[0-9A-F]{22}[0-9A-F]{2}$", options: .regularExpression) != nil
    }
}
