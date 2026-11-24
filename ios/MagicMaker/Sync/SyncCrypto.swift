import Foundation

// Portable primitives for the SYNC codec (docs/SYNC_PROTOCOL.md §2, §13): CRC-32/ISO-HDLC,
// FNV-1a 64, SHA-256, HMAC-SHA256, the group id and the HMAC challenge proofs. Pure Swift (no
// CryptoKit / CommonCrypto) so the same code runs on Linux; vectors: crc32, fnv1a64, sha256,
// hmacSha256, groupIds, proofs.

enum SyncCrc32 {
    private static let table: [UInt32] = {
        var t: [UInt32] = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c: UInt32 = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB8_8320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            t[i] = c
        }
        return t
    }()

    /// CRC-32/ISO-HDLC (zlib crc32): reflected poly 0x04C11DB7, init and xorout 0xFFFFFFFF.
    static func checksum(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            let index: Int = Int((c ^ UInt32(b)) & 0xFF)
            c = table[index] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}

enum SyncFnv1a64 {
    /// FNV-1a 64: h = (h XOR byte) * prime mod 2^64 per byte.
    static func hash(_ data: [UInt8]) -> UInt64 {
        var h: UInt64 = SyncConst.fnv64Offset
        for b in data {
            h = (h ^ UInt64(b)) &* SyncConst.fnv64Prime
        }
        return h
    }
}

enum SyncSha256 {
    private static let k: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    private static let initial: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x >> n) | (x << (32 - n))
    }

    /// SHA-256 (FIPS 180-4).
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var padded: [UInt8] = message
        let bitLength: UInt64 = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        var shift: Int = 56
        while shift >= 0 {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
            shift -= 8
        }

        var h: [UInt32] = initial
        var w: [UInt32] = [UInt32](repeating: 0, count: 64)
        var block: Int = 0
        while block < padded.count {
            for i in 0..<16 {
                let j: Int = block + i * 4
                var word: UInt32 = UInt32(padded[j]) << 24
                word |= UInt32(padded[j + 1]) << 16
                word |= UInt32(padded[j + 2]) << 8
                word |= UInt32(padded[j + 3])
                w[i] = word
            }
            for i in 16..<64 {
                let x15: UInt32 = w[i - 15]
                let x2: UInt32 = w[i - 2]
                let s0: UInt32 = rotr(x15, 7) ^ rotr(x15, 18) ^ (x15 >> 3)
                let s1: UInt32 = rotr(x2, 17) ^ rotr(x2, 19) ^ (x2 >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a: UInt32 = h[0]
            var b: UInt32 = h[1]
            var c: UInt32 = h[2]
            var d: UInt32 = h[3]
            var e: UInt32 = h[4]
            var f: UInt32 = h[5]
            var g: UInt32 = h[6]
            var hh: UInt32 = h[7]
            for i in 0..<64 {
                let bigS1: UInt32 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch: UInt32 = (e & f) ^ (~e & g)
                let t1: UInt32 = hh &+ bigS1 &+ ch &+ k[i] &+ w[i]
                let bigS0: UInt32 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj: UInt32 = (a & b) ^ (a & c) ^ (b & c)
                let t2: UInt32 = bigS0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
            block += 64
        }

        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in h {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }
}

enum SyncHmac {
    /// HMAC-SHA256 (RFC 2104, block size 64).
    static func sha256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var k: [UInt8] = key
        if k.count > 64 {
            k = SyncSha256.hash(k)
        }
        while k.count < 64 {
            k.append(0)
        }
        var inner: [UInt8] = []
        var outer: [UInt8] = []
        inner.reserveCapacity(64 + data.count)
        outer.reserveCapacity(64 + 32)
        for b in k {
            inner.append(b ^ 0x36)
            outer.append(b ^ 0x5C)
        }
        inner.append(contentsOf: data)
        outer.append(contentsOf: SyncSha256.hash(inner))
        return SyncSha256.hash(outer)
    }
}

/// A sync group: 16-byte key and its 8-byte id.
struct SyncGroup: Equatable {
    let groupId: [UInt8]
    let groupKey: [UInt8]
}

enum SyncGroupAuth {
    static let groupIdPrefix: [UInt8] = Array("MMGROUP1".utf8)
    static let proofPPrefix: [UInt8] = Array("MMSYNC1P".utf8)
    static let proofCPrefix: [UInt8] = Array("MMSYNC1C".utf8)

    /// groupId = SHA-256("MMGROUP1" ‖ groupKey)[0..7] (§13.1).
    static func groupId(key: [UInt8]) -> [UInt8] {
        var input: [UInt8] = groupIdPrefix
        input.append(contentsOf: key)
        return Array(SyncSha256.hash(input)[0..<8])
    }

    /// The advertised tag: groupId[0..1] (§13.1).
    static func advertTag(groupId: [UInt8]) -> [UInt8] {
        return Array(groupId.prefix(2))
    }

    /// A fresh random group (a key whose groupId is all zero is discarded, §2).
    static func newGroup() -> SyncGroup {
        while true {
            let key: [UInt8] = SyncRandom.bytes(16)
            let gid: [UInt8] = groupId(key: key)
            if gid != SyncConst.zero8 {
                return SyncGroup(groupId: gid, groupKey: key)
            }
        }
    }

    /// T = nonceC ‖ nonceP ‖ idC ‖ idP (32 bytes, §13.2).
    static func transcript(nonceC: [UInt8], nonceP: [UInt8], idC: [UInt8], idP: [UInt8]) -> [UInt8] {
        var t: [UInt8] = []
        t.reserveCapacity(32)
        t.append(contentsOf: nonceC)
        t.append(contentsOf: nonceP)
        t.append(contentsOf: idC)
        t.append(contentsOf: idP)
        return t
    }

    /// The 40-byte MAC input: prefix ‖ T.
    static func macInput(prefix: [UInt8], nonceC: [UInt8], nonceP: [UInt8], idC: [UInt8], idP: [UInt8]) -> [UInt8] {
        var input: [UInt8] = prefix
        input.append(contentsOf: transcript(nonceC: nonceC, nonceP: nonceP, idC: idC, idP: idP))
        return input
    }

    /// proofP = HMAC-SHA256(groupKey, "MMSYNC1P" ‖ T)[0..15]: peripheral -> central (HELLO 0x0F).
    static func proofP(key: [UInt8], nonceC: [UInt8], nonceP: [UInt8], idC: [UInt8], idP: [UInt8]) -> [UInt8] {
        let input: [UInt8] = macInput(prefix: proofPPrefix, nonceC: nonceC, nonceP: nonceP, idC: idC, idP: idP)
        return Array(SyncHmac.sha256(key: key, data: input)[0..<16])
    }

    /// proofC = HMAC-SHA256(groupKey, "MMSYNC1C" ‖ T)[0..15]: central -> peripheral (AUTH 0x01).
    static func proofC(key: [UInt8], nonceC: [UInt8], nonceP: [UInt8], idC: [UInt8], idP: [UInt8]) -> [UInt8] {
        let input: [UInt8] = macInput(prefix: proofCPrefix, nonceC: nonceC, nonceP: nonceP, idC: idC, idP: idP)
        return Array(SyncHmac.sha256(key: key, data: input)[0..<16])
    }

    /// Constant-time comparison (for equal lengths; different lengths are simply unequal).
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count {
            return false
        }
        var diff: UInt8 = 0
        var i: Int = 0
        while i < a.count {
            diff |= a[i] ^ b[i]
            i += 1
        }
        return diff == 0
    }
}

enum SyncRandom {
    /// `count` bytes from the system CSPRNG (SystemRandomNumberGenerator: arc4random on Apple,
    /// getrandom on Linux).
    static func bytes(_ count: Int) -> [UInt8] {
        var generator: SystemRandomNumberGenerator = SystemRandomNumberGenerator()
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            let x: UInt64 = generator.next()
            var i: Int = 0
            while i < 8 && out.count < count {
                out.append(UInt8(truncatingIfNeeded: x >> UInt64(8 * i)))
                i += 1
            }
        }
        return out
    }

    /// Random bytes that are not all zero (deviceId, dbId, nonce).
    static func nonZeroBytes(_ count: Int) -> [UInt8] {
        while true {
            let b: [UInt8] = bytes(count)
            for x in b where x != 0 {
                return b
            }
        }
    }
}
