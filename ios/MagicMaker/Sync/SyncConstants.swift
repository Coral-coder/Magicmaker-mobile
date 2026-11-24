import Foundation

// SYNC protocol v1: constants, codes and flag bits (docs/SYNC_PROTOCOL.md §11, §12, §18).
//
// Every file in ios/MagicMaker/Sync is Foundation-only and uses no app type, so the codec also
// compiles on Linux with ios/SyncCheck/main.swift, which checks it against tools/sync/vectors.json
// and the golden transcripts (CI job "sync" in .github/workflows/ios-core-parity.yml). The
// executable reference is tools/sync/sync_ref.py; this code follows it function for function.

enum SyncConst {
    static let proto: UInt8 = 1
    static let frameVersion: UInt8 = 1
    static let frameHeaderLen: Int = 2
    static let attOverhead: Int = 3
    static let mtuMin: Int = 23
    static let mtuMax: Int = 517
    /// MTU below this -> the small pull profile (limit 8, maxBytes 512).
    static let smallMtuBelow: Int = 64
    static let maxMsgMin: Int = 512
    static let hubMaxMsg: Int = 512
    static let phoneMaxMsg: Int = 1024

    static let packetMin: Int = 3
    static let packetMax: Int = 29
    static let labelMax: Int = 64
    static let noteMax: Int = 160
    static let kindMax: Int = 16
    static let bodyMax: Int = 360
    static let seenByMax: Int = 4
    static let hbLinksMax: Int = 4
    static let hbEvtWmMax: Int = 4

    static let uPresence: Int64 = 1
    static let uLegacyAndroid: Int64 = 2
    static let uLegacyIos: Int64 = 3
    static let uMinMs: Int64 = 1_500_000_000_000
    static let futureBoundMs: Int64 = 86_400_000

    static let pullLimitDefault: Int64 = 24
    static let pullMaxBytesDefault: Int64 = 1536
    static let pullLimitSmall: Int64 = 8
    static let pullMaxBytesSmall: Int64 = 512
    static let pullMaxBytesMin: Int64 = 256
    static let pullLimitMax: Int64 = 32
    static let pullMaxBytesMax: Int64 = 1536

    static let helloTimeoutMs: Int64 = 5000
    static let helloTries: Int = 3
    static let incompatibleRetryMs: Int64 = 60000
    static let authTimeoutMs: Int64 = 5000
    static let memberDeadlineMs: Int64 = 10000
    static let pageTimeoutMs: Int64 = 10000
    static let pageTries: Int = 3
    static let pageFailRetryMs: Int64 = 30000
    static let livePullMs: Int64 = 2000
    static let hbIntervalMs: Int64 = 60000
    static let hbSpacingMs: Int64 = 5000
    static let pathFreshMs: Int64 = 90000
    static let notReadyRetryMs: Int64 = 500
    static let busyRetryMs: Int64 = 1000
    static let defaultRetryMs: Int64 = 1000

    static let evtWindowBits: Int64 = 64
    static let evtEpochsKept: Int = 2
    static let evtReplayDedupeMs: Int64 = 5000
    static let androidRingCap: Int = 2000
    static let tombstoneCapPhone: Int = 5000

    static let fnv64Offset: UInt64 = 0xCBF2_9CE4_8422_2325
    static let fnv64Prime: UInt64 = 0x0000_0100_0000_01B3

    /// Eight zero bytes: "absent" origin, ungrouped groupId.
    static let zero8: [UInt8] = [UInt8](repeating: 0, count: 8)
}

/// Record key namespaces (§3).
enum SyncNs {
    static let lib: UInt8 = 0
    static let newWand: UInt8 = 1
}

/// Record body flag bits (§4.1).
enum SyncFlag {
    static let deleted: UInt8 = 0x01
    static let userEdited: UInt8 = 0x02
    static let preset: UInt8 = 0x04
    static let mask: UInt8 = 0x07
}

/// Record body category values (§4.1).
enum SyncCategory {
    static let unknown: UInt8 = 0
    static let show: UInt8 = 1
    static let animation: UInt8 = 2
    static let color: UInt8 = 3
}

/// Record body place values (§4.1).
enum SyncPlace {
    static let presets: UInt8 = 1
    static let colors: UInt8 = 2
    static let library: UInt8 = 3
    static let raw: UInt8 = 4
}

/// Node kinds (HELLO 0x03, HB 0x02).
enum SyncKind {
    static let hub: UInt8 = 1
    static let android: UInt8 = 2
    static let ios: UInt8 = 3
}

/// HELLO / SUB subscription bits (§16.1).
enum SyncSubs {
    static let records: Int64 = 0x01
    static let events: Int64 = 0x02
    static let heartbeats: Int64 = 0x04
}

/// HELLO caps bits (§11.1).
enum SyncCaps {
    static let feed: Int64 = 0x0001
    static let events: Int64 = 0x0002
    static let transmitter: Int64 = 0x0008
    static let programs: Int64 = 0x0010
    static let loopsByHex: Int64 = 0x0020

    static let hub: Int64 = 0x0039
    static let android: Int64 = 0x003B
    static let ios: Int64 = 0x0001

    static func forKind(_ kind: UInt8) -> Int64 {
        switch kind {
        case SyncKind.hub: return hub
        case SyncKind.android: return android
        case SyncKind.ios: return ios
        default: return 0
        }
    }
}

/// Other flag bits carried in messages.
enum SyncMsgFlag {
    /// JOIN 0x03 bit0.
    static let joinRekey: Int64 = 0x01
    /// EVT 0x0C bit0: tagged own-band address.
    static let evtTagged: Int64 = 0x01
    /// EVT 0x0C bit1: replayed from Android's ring.
    static let evtReplay: Int64 = 0x02
    /// HB link flags.
    static let linkSynced: UInt8 = 0x01
    static let linkTxReady: UInt8 = 0x02
    static let linkWifi: UInt8 = 0x04
}

/// Message type codes (§11).
enum SyncMsgType {
    static let hello: UInt8 = 0x01
    static let pull: UInt8 = 0x02
    static let rec: UInt8 = 0x03
    static let pageEnd: UInt8 = 0x04
    static let evt: UInt8 = 0x05
    static let evtSince: UInt8 = 0x06
    static let evtGap: UInt8 = 0x07
    static let hb: UInt8 = 0x08
    static let sub: UInt8 = 0x09
    static let err: UInt8 = 0x0A
    static let auth: UInt8 = 0x0B
    static let join: UInt8 = 0x0C

    static let names: [UInt8: String] = [
        0x01: "HELLO", 0x02: "PULL", 0x03: "REC", 0x04: "PAGE_END", 0x05: "EVT", 0x06: "EVT_SINCE",
        0x07: "EVT_GAP", 0x08: "HB", 0x09: "SUB", 0x0A: "ERR", 0x0B: "AUTH", 0x0C: "JOIN",
    ]

    static func name(_ type: UInt8) -> String {
        if let n = names[type] {
            return n
        }
        return "0x" + SyncHex.encode([type])
    }

    static func code(_ name: String) -> UInt8? {
        for (k, v) in names where v == name {
            return k
        }
        return nil
    }
}

/// ERR codes (§12).
enum SyncErrorCode {
    static let badFrame: UInt8 = 1
    static let tooBig: UInt8 = 2
    static let badMsg: UInt8 = 3
    static let proto: UInt8 = 4
    static let dbChanged: UInt8 = 5
    static let full: UInt8 = 6
    static let clock: UInt8 = 7
    static let busy: UInt8 = 8
    static let collision: UInt8 = 9
    static let auth: UInt8 = 10
    static let notReady: UInt8 = 11

    static let names: [UInt8: String] = [
        1: "BAD_FRAME", 2: "TOO_BIG", 3: "BAD_MSG", 4: "PROTO", 5: "DB_CHANGED", 6: "FULL",
        7: "CLOCK", 8: "BUSY", 9: "COLLISION", 10: "AUTH", 11: "NOT_READY",
    ]

    static func name(_ code: UInt8) -> String {
        if let n = names[code] {
            return n
        }
        return "ERR_" + String(code)
    }
}

/// A decode or validation failure. `code` is an ERR code (BAD_MSG or CLOCK); `reason` is the short
/// tag the vectors carry (informative, not normative: only the code is part of the protocol).
struct SyncError: Error, Equatable, CustomStringConvertible {
    let code: UInt8
    let reason: String

    init(_ code: UInt8, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    static func badMsg(_ reason: String) -> SyncError {
        return SyncError(SyncErrorCode.badMsg, reason)
    }

    var name: String {
        return SyncErrorCode.name(code)
    }

    var description: String {
        return name + ":" + reason
    }
}
