import Foundation

// Text normalisation for local edits (docs/SYNC_PROTOCOL.md §5.3). Works on Unicode scalars
// (never graphemes or UTF-16 units) and trims exactly the Unicode White_Space set, not the
// platform's idea of whitespace. Receivers never re-normalise. Vectors: textNormalize.

enum SyncText {
    /// The Unicode White_Space property: U+0009-000D, U+0020, U+0085, U+00A0, U+1680,
    /// U+2000-200A, U+2028, U+2029, U+202F, U+205F, U+3000. (U+200B is not in it.)
    static func isWhiteSpace(_ v: UInt32) -> Bool {
        switch v {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    static func utf8Length(_ u: Unicode.Scalar) -> Int {
        let v: UInt32 = u.value
        if v < 0x80 {
            return 1
        }
        if v < 0x800 {
            return 2
        }
        if v < 0x1_0000 {
            return 3
        }
        return 4
    }

    private static func trim(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var a: Int = 0
        var b: Int = s.count
        while a < b && isWhiteSpace(s[a].value) {
            a += 1
        }
        while b > a && isWhiteSpace(s[b - 1].value) {
            b -= 1
        }
        return Array(s[a..<b])
    }

    static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view: String.UnicodeScalarView = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// trim -> keep the longest prefix of whole scalars whose UTF-8 length is <= maxBytes -> trim.
    /// nil when the result is empty (the field is then absent).
    static func normalize(_ s: String, maxBytes: Int) -> String? {
        let trimmed: [Unicode.Scalar] = trim(Array(s.unicodeScalars))
        var kept: [Unicode.Scalar] = []
        var used: Int = 0
        for u in trimmed {
            let w: Int = utf8Length(u)
            if used + w > maxBytes {
                break
            }
            kept.append(u)
            used += w
        }
        let out: [Unicode.Scalar] = trim(kept)
        if out.isEmpty {
            return nil
        }
        return string(out)
    }

    /// A row's typeInfo -> record kind: scalars outside 0x20..0x7E become "?", then normalize(16).
    static func normalizeKind(_ s: String) -> String? {
        let question: Unicode.Scalar = "?"
        var mapped: [Unicode.Scalar] = []
        for u in s.unicodeScalars {
            if u.value >= 0x20 && u.value <= 0x7E {
                mapped.append(u)
            } else {
                mapped.append(question)
            }
        }
        return normalize(string(mapped), maxBytes: SyncConst.kindMax)
    }

    static func normalizeLabel(_ s: String) -> String? {
        return normalize(s, maxBytes: SyncConst.labelMax)
    }

    static func normalizeNote(_ s: String) -> String? {
        return normalize(s, maxBytes: SyncConst.noteMax)
    }
}
