import Foundation

// Byte helpers for the SYNC codec: uppercase hex, little-endian integers, TLV parsing and strict
// UTF-8 validation (docs/SYNC_PROTOCOL.md §1, §4.1, §10). Bytes are [UInt8] throughout, so every
// index is zero-based (no Data / ArraySlice index surprises).

enum SyncHex {
    private static let digits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Uppercase hex, most significant nibble first.
    static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Hex (either case) -> bytes; nil on an odd length or a non-hex character.
    static func decode(_ text: String) -> [UInt8]? {
        let chars: [UInt8] = Array(text.utf8)
        if chars.count % 2 != 0 {
            return nil
        }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i: Int = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else {
                return nil
            }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39:
            return c - 0x30
        case 0x41...0x46:
            return c - 0x41 + 10
        case 0x61...0x66:
            return c - 0x61 + 10
        default:
            return nil
        }
    }
}

/// Little-endian fixed-width integers (§1).
enum SyncLE {
    /// Reads up to 8 bytes; `signed` sign-extends from the top bit of the last byte.
    static func read(_ v: [UInt8], signed: Bool) -> Int64 {
        let width: Int = min(v.count, 8)
        var u: UInt64 = 0
        var i: Int = 0
        while i < width {
            u |= UInt64(v[i]) << UInt64(8 * i)
            i += 1
        }
        if signed && width > 0 && width < 8 && (v[width - 1] & 0x80) != 0 {
            u |= ~UInt64(0) << UInt64(8 * width)
        }
        return Int64(bitPattern: u)
    }

    /// The low `width` bytes of `x` (two's complement), least significant first.
    static func write(_ x: Int64, width: Int) -> [UInt8] {
        let u: UInt64 = UInt64(bitPattern: x)
        var out: [UInt8] = []
        var i: Int = 0
        while i < width {
            out.append(UInt8(truncatingIfNeeded: u >> UInt64(8 * i)))
            i += 1
        }
        return out
    }

    /// Whether `x` is representable in `width` bytes (signed or unsigned).
    static func fits(_ x: Int64, width: Int, signed: Bool) -> Bool {
        if width >= 8 {
            return signed || x >= 0
        }
        let bits: Int64 = Int64(8 * width)
        if signed {
            let hi: Int64 = (Int64(1) << (bits - 1)) - 1
            let lo: Int64 = -hi - 1
            return x >= lo && x <= hi
        }
        return x >= 0 && x <= (Int64(1) << bits) - 1
    }
}

/// One TLV: `tag len value`. `start` is the index of the tag byte, `end` is one past the value, so
/// `data[start..<end]` is the raw TLV.
struct SyncTlv {
    let tag: UInt8
    let value: [UInt8]
    let start: Int
    let end: Int
}

enum SyncTlvCodec {
    /// Parses `data[from...]` as TLVs; BAD_MSG(truncated) unless they end exactly at the end.
    static func parse(_ data: [UInt8], from start: Int = 0) throws -> [SyncTlv] {
        var out: [SyncTlv] = []
        var i: Int = start
        while i < data.count {
            if i + 2 > data.count {
                throw SyncError.badMsg("truncated")
            }
            let tag: UInt8 = data[i]
            let len: Int = Int(data[i + 1])
            let end: Int = i + 2 + len
            if end > data.count {
                throw SyncError.badMsg("truncated")
            }
            out.append(SyncTlv(tag: tag, value: Array(data[(i + 2)..<end]), start: i, end: end))
            i = end
        }
        return out
    }

    /// Appends `tag len value`; BAD_MSG(length) for a value over 255 bytes.
    static func append(_ out: inout [UInt8], tag: UInt8, value: [UInt8]) throws {
        if value.count > 255 {
            throw SyncError.badMsg("length")
        }
        out.append(tag)
        out.append(UInt8(value.count))
        out.append(contentsOf: value)
    }
}

enum SyncUtf8 {
    /// RFC 3629 well-formed UTF-8 (Unicode Table 3-7): no overlong forms, no surrogates, nothing
    /// above U+10FFFF, no truncated sequences. NUL is allowed.
    static func isValid(_ b: [UInt8]) -> Bool {
        let n: Int = b.count
        var i: Int = 0
        while i < n {
            let c: UInt8 = b[i]
            if c < 0x80 {
                i += 1
                continue
            }
            var need: Int = 0
            var lo: UInt8 = 0x80
            var hi: UInt8 = 0xBF
            if c >= 0xC2 && c <= 0xDF {
                need = 1
            } else if c == 0xE0 {
                need = 2
                lo = 0xA0
            } else if (c >= 0xE1 && c <= 0xEC) || c == 0xEE || c == 0xEF {
                need = 2
            } else if c == 0xED {
                need = 2
                hi = 0x9F
            } else if c == 0xF0 {
                need = 3
                lo = 0x90
            } else if c >= 0xF1 && c <= 0xF3 {
                need = 3
            } else if c == 0xF4 {
                need = 3
                hi = 0x8F
            } else {
                return false
            }
            if i + need >= n {
                return false
            }
            let c1: UInt8 = b[i + 1]
            if c1 < lo || c1 > hi {
                return false
            }
            var k: Int = 2
            while k <= need {
                let ck: UInt8 = b[i + k]
                if ck < 0x80 || ck > 0xBF {
                    return false
                }
                k += 1
            }
            i += need + 1
        }
        return true
    }

    /// Every byte in 0x20..0x7E.
    static func isPrintableAscii(_ b: [UInt8]) -> Bool {
        for c in b where c < 0x20 || c > 0x7E {
            return false
        }
        return true
    }

    /// The bytes as a String (call only after `isValid`; the UTF-8 view returns exactly these bytes).
    static func string(_ b: [UInt8]) -> String {
        return String(decoding: b, as: UTF8.self)
    }
}

/// Lexicographic byte order (shorter prefix first), as Python compares bytes.
func syncBytesLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    return a.lexicographicallyPrecedes(b)
}
