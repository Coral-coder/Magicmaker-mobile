import Foundation

// Live record push, event relay / Android route, heartbeat forwarding and replacement, the HELLO
// subs table (docs/SYNC_PROTOCOL.md §16). Pure functions over the node's session list. Vectors:
// routing.{localRec, liveRec, evtRelay, androidRoute, hbForward, hbReplace, subs, caps}.

/// One session as routing sees it. `subscribed`: the peer subscribed to what is being routed
/// (records, events or heartbeats); `up`: the session is AUTHED+ (member).
struct SyncRouteSession {
    let peer: [UInt8]
    let subscribed: Bool
    let up: Bool

    init(peer: [UInt8], subscribed: Bool, up: Bool) {
        self.peer = peer
        self.subscribed = subscribed
        self.up = up
    }
}

/// Targets in session order and the seenBy list to send.
struct SyncRoute: Equatable {
    let targets: [[UInt8]]
    let seenBy: [[UInt8]]
}

/// Android's route for one event (§16.3): 1 direct to the iPhone, 2 via the hub, 3 ring only.
struct SyncAndroidRoute: Equatable {
    let route: Int
    let target: [UInt8]?
    let seenBy: [[UInt8]]
}

/// The kept HB identity of a device: `{bootId, hbSeq}`.
struct SyncHbStamp: Equatable {
    let bootId: Int64
    let hbSeq: Int64

    init(bootId: Int64, hbSeq: Int64) {
        self.bootId = bootId
        self.hbSeq = hbSeq
    }
}

enum SyncRouting {
    /// The existing list in order, then new ids not yet present, truncated to the first 4.
    static func mergeSeen(_ base: [[UInt8]], _ extra: [[UInt8]]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for x in base + extra where !out.contains(x) {
            out.append(x)
        }
        if out.count > SyncConst.seenByMax {
            out = Array(out[0..<SyncConst.seenByMax])
        }
        return out
    }

    /// Local change: every AUTHED+, records-subscribed session; seenBy = [self] + targets.
    static func localRec(selfId: [UInt8], sessions: [SyncRouteSession]) -> SyncRoute {
        var targets: [[UInt8]] = []
        for s in sessions where s.up && s.subscribed {
            targets.append(s.peer)
        }
        return SyncRoute(targets: targets, seenBy: mergeSeen([], [selfId] + targets))
    }

    /// First accept of a live REC from `sender`. `origin` nil (or zero) = PRESENCE.
    static func liveRec(selfId: [UInt8], sender: [UInt8], origin: [UInt8]?, seenBy: [[UInt8]],
                        sessions: [SyncRouteSession]) -> SyncRoute {
        var excluded: [[UInt8]] = seenBy
        excluded.append(sender)
        if let o = origin, o != SyncConst.zero8 {
            excluded.append(o)
        }
        var targets: [[UInt8]] = []
        for s in sessions where s.up && s.subscribed && !excluded.contains(s.peer) && s.peer != selfId {
            targets.append(s.peer)
        }
        if targets.isEmpty {
            return SyncRoute(targets: [], seenBy: seenBy)
        }
        return SyncRoute(targets: targets, seenBy: mergeSeen(seenBy, [selfId] + targets))
    }

    /// Hub relay of an EVT from `sender` (sessions: events-subscribed, member).
    static func evtRelay(selfId: [UInt8], sender: [UInt8], origin: [UInt8], seenBy: [[UInt8]],
                         sessions: [SyncRouteSession]) -> SyncRoute {
        var excluded: [[UInt8]] = seenBy
        excluded.append(sender)
        excluded.append(origin)
        var targets: [[UInt8]] = []
        for s in sessions where s.up && s.subscribed && !excluded.contains(s.peer) && s.peer != selfId {
            targets.append(s.peer)
        }
        if targets.isEmpty {
            return SyncRoute(targets: [], seenBy: seenBy)
        }
        return SyncRoute(targets: targets, seenBy: mergeSeen(seenBy, [selfId] + targets))
    }

    /// Android's event route. `ios`: the A–I session (`up` = AUTHED+, `subscribed` = the iPhone
    /// subscribed to events); `hub`: the A–H session (`subscribed` unused); `hubHbAgeMs` /
    /// `hubHbLinks`: the hub's latest DIRECT HB (nil age = none).
    static func androidRoute(selfId: [UInt8], ios: SyncRouteSession?, hub: SyncRouteSession?,
                             hubHbAgeMs: Int64?, hubHbLinks: [SyncHbLink]) -> SyncAndroidRoute {
        if let i = ios, i.up, i.subscribed {
            return SyncAndroidRoute(route: 1, target: i.peer, seenBy: [selfId, i.peer])
        }
        if let h = hub, h.up, let age = hubHbAgeMs, age <= SyncConst.pathFreshMs {
            for l in hubHbLinks where l.peerKind == SyncKind.ios && (l.flags & SyncMsgFlag.linkSynced) != 0 {
                return SyncAndroidRoute(route: 2, target: h.peer, seenBy: [selfId, h.peer])
            }
        }
        return SyncAndroidRoute(route: 3, target: nil, seenBy: [])
    }

    /// HB forwarding: a direct (hops 0) HB goes once to every other heartbeat-subscribed member
    /// whose peer is neither the sender nor the described device. hops 1 is never forwarded.
    static func hbForward(selfId: [UInt8], sender: [UInt8], deviceId: [UInt8], hops: Int64,
                          sessions: [SyncRouteSession]) -> [[UInt8]] {
        if hops != 0 {
            return []
        }
        var targets: [[UInt8]] = []
        for s in sessions where s.up && s.subscribed && s.peer != sender && s.peer != deviceId && s.peer != selfId {
            targets.append(s.peer)
        }
        return targets
    }

    /// Keep-latest rule: a new HB replaces the stored one iff bootId differs or hbSeq is greater.
    static func hbReplaces(stored: SyncHbStamp?, incoming: SyncHbStamp) -> Bool {
        guard let s = stored else {
            return true
        }
        if incoming.bootId != s.bootId {
            return true
        }
        return incoming.hbSeq > s.hbSeq
    }

    /// The subs a node of `selfKind` sends in HELLO (§16.1): hub and iPhone 0x07, Android 0x05.
    static func subsFor(selfKind: UInt8, peerKind: UInt8) -> Int64 {
        switch selfKind {
        case SyncKind.hub, SyncKind.ios:
            return SyncSubs.records | SyncSubs.events | SyncSubs.heartbeats
        case SyncKind.android:
            return SyncSubs.records | SyncSubs.heartbeats
        default:
            return 0
        }
    }
}
