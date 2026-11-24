#!/usr/bin/env python3
"""Model harness: checks tools/sync/vectors.json and transcripts/*.json using only the JSON.

    python3 tools/sync/check_vectors.py

It treats sync_ref.py as "the implementation under test", exactly as the C++, Kotlin and Swift
harnesses treat their own codecs, so it doubles as an executable description of how to consume each
vector group (see README.md). Exit status 1 on the first mismatch.
"""

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import sync_ref as R  # noqa: E402
from sync_ref import hexu, unhex  # noqa: E402

checked = {}


def ok(group):
    checked[group] = checked.get(group, 0) + 1


def eq(got, want, what):
    if got != want:
        raise AssertionError("%s\n  got:  %r\n  want: %r" % (what, got, want))


def err_name(fn, *a):
    try:
        fn(*a)
    except R.SyncError as e:
        return R.ERR_NAMES[e.code]
    return None


def check_primitives(v):
    for c in v["crc32"]:
        eq(R.crc32(unhex(c["hex"])), c["crc"], "crc32 " + c["name"]); ok("crc32")
    for c in v["fnv1a64"]:
        eq("%016X" % R.fnv1a64(unhex(c["hex"])), c["hash"], "fnv " + c["name"]); ok("fnv1a64")
    for c in v["sha256"]:
        eq(hexu(R.sha256(unhex(c["hex"]))), c["digest"], "sha " + c["name"]); ok("sha256")
    for c in v["hmacSha256"]:
        mac = R.hmac_sha256(unhex(c["keyHex"]), unhex(c["dataHex"]))
        eq(hexu(mac), c["macHex"], c["name"])
        if "trunc16Hex" in c:
            eq(hexu(mac[:16]), c["trunc16Hex"], c["name"])
        ok("hmacSha256")
    for c in v["groupIds"]:
        g = R.group_id(unhex(c["keyHex"]))
        eq(hexu(g), c["groupId"], c["name"]); eq(hexu(g[:2]), c["advertTag"], c["name"]); ok("groupIds")
    for c in v["proofs"]:
        k, a = unhex(c["keyHex"]), [unhex(c[x]) for x in ("nonceC", "nonceP", "idC", "idP")]
        eq(hexu(R.auth_transcript(*a)), c["transcriptHex"], c["name"])
        eq(hexu(R.proof_p(k, *a)), c["proofP"], c["name"]); eq(hexu(R.proof_c(k, *a)), c["proofC"], c["name"])
        ok("proofs")
    for c in v["textNormalize"]:
        s = unhex(c["inputHex"]).decode("utf-8")
        eq(s, c["input"], c["name"])
        out = R.normalize_text(s, c["maxBytes"]) if c["fn"] == "text" else R.normalize_kind(s)
        eq(out, c["output"], c["name"]); ok("textNormalize")
    for c in v["keys"]:
        k = R.encode_key(c["ns"], unhex(c["packet"]))
        eq(hexu(k), c["keyHex"], "key"); eq(R.key_string(c["ns"], unhex(c["packet"])), c["keyString"], "keyString")
        eq("%016X" % R.fnv1a64(k), c["fnv1a64"], "key fnv"); ok("keys")


def check_bodies(v):
    for c in v["bodies"]:
        f = R.body_from_json(c["body"])
        b = R.encode_body(f)
        eq(hexu(b), c["hex"], "encode " + c["name"])
        back = R.decode_body(unhex(c["hex"]))
        eq(R.body_to_json(back), c["body"], "decode " + c["name"])
        eq(R.crc32(b), c["crc"], "crc " + c["name"]); eq(R.body_class(back), c["class"], "class " + c["name"])
        ok("bodies")
    for c in v["bodyRejects"]:
        eq(err_name(R.decode_body, unhex(c["hex"])), c["error"], "reject " + c["name"]); ok("bodyRejects")
    for c in v["clock"]:
        if "bodyHex" in c:
            st, _, _ = R.Ledger().apply_remote(unhex(c["bodyHex"]), R.ZERO8, c["now"])
            eq(st, c["result"], c["name"])
        else:
            eq(err_name(R.check_future, c["updatedAt"], c["now"]) or "OK", c["result"], c["name"])
        ok("clock")
    for c in v["comparator"]:
        va = (c["a"]["updatedAt"], int(c["a"]["origin"], 16), c["a"]["crc"])
        vb = (c["b"]["updatedAt"], int(c["b"]["origin"], 16), c["b"]["crc"])
        eq(R.compare_versions(va, vb), c["expect"], c["name"]); eq(R.compare_versions(vb, va), -c["expect"], c["name"])
        ok("comparator")
    for c in v["localStamp"]:
        eq(R.local_stamp(c["now"], c["ledgerUpdatedAt"], c["lastLocalStamp"]), c["expect"], c["name"])
        ok("localStamp")


def check_apply(v):
    for sc in v["apply"]:
        led = R.Ledger(tombstone_cap=sc["tombstoneCap"], next_sync_seq=sc["nextSyncSeq"])
        for i, st in enumerate(sc["steps"]):
            what = "%s step %d" % (sc["name"], i)
            if st["op"] == "remote":
                s, e, ev = led.apply_remote(unhex(st["bodyHex"]), unhex(st["from"]), st["now"])
                eq(s, st["expect"]["status"], what); eq(ev, st["expect"]["evicted"], what)
                eq(e.to_json() if (e is not None and s == "ACCEPT") else None, st["expect"]["entry"], what)
            elif st["op"] == "edit":
                kw = {k: st[k] for k in ("label", "category", "kind", "place", "note") if k in st}
                if st["class"] == R.CLASS_USER:
                    kw["preset"], kw["user_edited"] = st["preset"], st["userEdited"]
                e, ev = led.local_edit(st["class"], st["key"]["ns"], unhex(st["key"]["packet"]), st["now"],
                                       unhex(st["self"]), **kw)
                eq(hexu(e.body), st["expect"]["bodyHex"], what); eq(e.version[0], st["expect"]["updatedAt"], what)
                eq(ev, st["expect"]["evicted"], what)
            else:
                e = led.local_learn(unhex(st["packet"]))
                eq(e is not None, st["expect"]["created"], what)
        fin = sc["final"]
        eq(led.next_sync_seq, fin["nextSyncSeq"], sc["name"]); eq(led.last_local_stamp, fin["lastLocalStamp"], sc["name"])
        eq(led.tombstone_count(), fin["tombstones"], sc["name"]); eq(led.to_json(), fin["entries"], sc["name"])
        ok("apply")


def check_messages(v):
    for c in v["messages"]:
        mt = R.MSG_TYPES[c["type"]]
        eq(mt, c["typeCode"], c["name"])
        eq(hexu(R.encode_msg(mt, R.msg_fields_from_json(mt, c["fields"]))), c["hex"], "encode " + c["name"])
        t2, f = R.decode_msg(unhex(c["hex"]))
        eq(t2, mt, c["name"]); eq(R.msg_fields_to_json(mt, f), c["fields"], "decode " + c["name"])
        ok("messages")
    for c in v["messageNonCanonical"]:
        mt, f = R.decode_msg(unhex(c["hex"]))
        eq(R.msg_fields_to_json(mt, f), c["fields"], c["name"]); eq(hexu(R.encode_msg(mt, f)), c["canonicalHex"], c["name"])
        ok("messageNonCanonical")
    for c in v["messageRejects"]:
        eq(err_name(R.decode_msg, unhex(c["hex"])), "BAD_MSG", c["name"]); ok("messageRejects")
    for c in v["messageBadBody"]:
        mt, f = R.decode_msg(unhex(c["hex"]))
        eq(R.ERR_NAMES[f["bodyError"].code], c["bodyError"], c["name"]); eq(R.msg_fields_to_json(mt, f), c["fields"], c["name"])
        ok("messageBadBody")
    for c in v["messageIgnored"]:
        mt, f = R.decode_msg(unhex(c["hex"]))
        eq(f, None, c["name"]); ok("messageIgnored")
    for c in v["hbHops"]:
        eq(hexu(R.hb_set_hops(unhex(c["inHex"]), 1)), c["outHex"], c["name"]); ok("hbHops")


def check_frames(v):
    for c in v["frames"]:
        fr = R.Fragmenter(c["startCounter"], c["startSeq"])
        frames = []
        for m in c["messages"]:
            frames += [hexu(x) for x in fr.fragment(unhex(m), c["mtu"])]
        eq(frames, c["frames"], c["name"]); eq(R.chunk_size(c["mtu"]), c["chunk"], c["name"]); ok("frames")
    for c in v["reassembly"]:
        ra = R.Reassembler(c["maxMsg"])
        ra.expected = c.get("startExpectedSeq", 0)
        got = []
        for f in c["frames"]:
            for a in ra.feed(unhex(f)):
                key = {"deliver": "deliver", "bad_frame": "badFrame", "err_too_big": "errTooBig",
                       "err_proto": "errProto"}[a[0]]
                got.append({key: hexu(a[1]) if a[0] == "deliver" else a[1]})
        eq(got, c["expect"], c["name"]); ok("reassembly")


class E(object):
    def __init__(self, j):
        self.s, self.body, self.f = j["seq"], unhex(j["bodyHex"]), unhex(j["syncFrom"])
        self.origin = R.decode_body(self.body).get("origin")


def check_pages(v):
    for c in v["pages"]:
        pull = R.msg_fields_from_json(R.PULL, c["pull"])
        eq(hexu(R.encode_msg(R.PULL, pull)), c["pullHex"], c["name"])
        excl = pull.get("exclude", 0) == 1 and c["excludeOk"]
        recs, pe = R.serve_page([E(x) for x in c["entries"]], c["durableHigh"], pull["since"],
                                pull.get("limit", 24), pull.get("maxBytes", 1536), excl, unhex(c["puller"]),
                                pull["reqId"])
        eq([hexu(r) for r in recs], c["expect"]["recs"], c["name"]); eq(pe, c["expect"]["pageEnd"], c["name"])
        eq(hexu(R.encode_msg(R.PAGE_END, pe)), c["expect"]["pageEndHex"], c["name"]); ok("pages")


def check_routing(v):
    r = v["routing"]
    H = lambda xs: [unhex(x) for x in xs]
    X = lambda xs: [hexu(x) for x in xs]
    for c in r["localRec"]:
        t, s = R.route_local_rec(unhex(c["self"]), [(unhex(x["peer"]), x["subRecords"], x["authed"]) for x in c["sessions"]])
        eq({"targets": X(t), "seenBy": X(s)}, c["expect"], c["name"]); ok("routing.localRec")
    for c in r["liveRec"]:
        t, s = R.route_live_rec(unhex(c["self"]), unhex(c["sender"]), unhex(c["origin"]), H(c["seenBy"]),
                                [(unhex(x["peer"]), x["subRecords"], x["authed"]) for x in c["sessions"]])
        eq({"targets": X(t), "seenBy": X(s)}, c["expect"], c["name"]); ok("routing.liveRec")
    for c in r["evtRelay"]:
        t, s = R.route_evt_relay(unhex(c["self"]), unhex(c["sender"]), unhex(c["origin"]), H(c["seenBy"]),
                                 [(unhex(x["peer"]), x["subEvents"], x["member"]) for x in c["sessions"]])
        eq({"targets": X(t), "seenBy": X(s)}, c["expect"], c["name"]); ok("routing.evtRelay")
    for c in r["androidRoute"]:
        ios = None if c["ios"] is None else (unhex(c["ios"]["peer"]), c["ios"]["up"], c["ios"]["subEvents"])
        hub = None if c["hub"] is None else (unhex(c["hub"]["peer"]), c["hub"]["up"])
        links = [{"peerId": unhex(l["peerId"]), "peerKind": l["peerKind"], "flags": l["flags"]} for l in c["hubHbLinks"]]
        rt, tg, s = R.android_event_route(unhex(c["self"]), ios, hub, c["hubHbAgeMs"], links)
        eq({"route": rt, "target": hexu(tg), "seenBy": X(s)}, c["expect"], c["name"]); ok("routing.androidRoute")
    for c in r["hbForward"]:
        t = R.route_hb(unhex(c["self"]), unhex(c["sender"]), unhex(c["deviceId"]), c["hops"],
                       [(unhex(x["peer"]), x["subHeartbeats"], x["member"]) for x in c["sessions"]])
        eq({"targets": X(t)}, c["expect"], c["name"]); ok("routing.hbForward")
    for c in r["hbReplace"]:
        eq(R.hb_replaces(c["stored"], c["incoming"]), c["expect"], c["name"]); ok("routing.hbReplace")
    for c in r["subs"]:
        eq(R.subs_for(c["selfKind"], c["peerKind"]), c["subs"], "subs"); ok("routing.subs")
    for c in r["caps"]:
        eq(R.CAPS_BY_KIND[c["kind"]], c["caps"], "caps"); ok("routing.caps")


def check_events(v):
    for sc in v["eventDedupe"]:
        d = R.EvtDedupe()
        for i, st in enumerate(sc["steps"]):
            o = unhex(st["origin"])
            if st["op"] == "evt":
                res, lost = d.receive(o, st["epoch"], st["seq"])
                got = {"result": res, "lost": lost, "holes": d.has_holes(o, st["epoch"]),
                       "windows": [w.to_json() for w in d.windows(o)]}
            else:
                lost, reqs = d.on_gap(o, st["epoch"], st["firstAvail"], st["lastAvail"], st["curEpoch"])
                got = {"lost": lost, "requests": [{"epoch": a, "afterSeq": b} for a, b in reqs],
                       "windows": [w.to_json() for w in d.windows(o)]}
            eq(got, st["expect"], "%s step %d" % (sc["name"], i))
        ok("eventDedupe")
    for c in v["replayPlan"]:
        plan = R.replay_plan([tuple(x) for x in c["ring"]], c["curEpoch"], c["curSeq"], c["epoch"], c["afterSeq"])
        got = [{"replay": {"epoch": p[1], "seq": p[2]}} if p[0] == "replay" else
               {"gap": {"epoch": p[1], "firstAvail": p[2], "lastAvail": p[3], "curEpoch": p[4]}} for p in plan]
        eq(got, c["expect"], c["name"]); ok("replayPlan")


def core_from_json(cfg, ctx):
    c = R.SessionConfig(cfg["role"], unhex(cfg["deviceId"]), cfg["kind"], cfg["bootId"], cfg["maxMsg"],
                        caps=cfg["caps"], version=cfg["version"], name=cfg["name"], peer_kind=cfg["peerKind"],
                        tracks_events=cfg["tracksEvents"], is_hub=cfg["isHub"])
    base = ctx["clockBaseMs"]
    x = R.SessionCtx(group=(unhex(ctx["groupId"]), unhex(ctx["groupKey"])) if ctx["groupId"] else None,
                     db_id=unhex(ctx["dbId"]), feed_high=ctx["feedHigh"],
                     clock=(lambda t: base + t) if base is not None else (lambda t: 0),
                     nonces=[unhex(n) for n in ctx["nonces"]], ready=ctx["ready"],
                     peers={k: R.PeerState.from_json(p) for k, p in ctx["peers"].items()})
    return R.SessionCore(c, x)


def check_sessions(v):
    for sc in v["sessions"]:
        core = core_from_json(sc["config"], sc["ctx"])
        for i, st in enumerate(sc["steps"]):
            if "ctx" in st:
                c = st["ctx"]
                core.ctx.group = (unhex(c["groupId"]), unhex(c["groupKey"])) if c["groupId"] else None
                core.ctx.db_id, core.ctx.feed_high, core.ctx.ready = unhex(c["dbId"]), c["feedHigh"], c["ready"]
            acts = R.public_actions(core.handle(st["t"], st["in"]))
            what = "%s step %d (%s)" % (sc["name"], i, st["in"]["in"])
            eq(acts, st["out"], what)
            eq(core.snapshot(), st["after"], what + " snapshot")
        ok("sessions")


def check_transcript(path):
    with open(path, encoding="utf-8") as fh:
        j = json.load(fh)
    keys = {}
    for n in j["nodes"].values():
        if n.get("groupKey"):
            keys[n["groupId"]] = unhex(n["groupKey"])
    frag, reasm, hello_c = {}, {}, {}
    maxmsg = {name: n.get("maxMsg", R.PHONE_MAXMSG) for name, n in j["nodes"].items()}
    links = {}
    for st in j["steps"]:
        if st["ev"] == "link_up":
            links[st["link"]] = (st["central"], st["peripheral"], st["mtu"])
            for who in (st["central"], st["peripheral"]):
                frag[(st["link"], who)] = R.Fragmenter()
                reasm[(st["link"], who)] = R.Reassembler(maxmsg[who])
            continue
        if st["ev"] != "msg":
            continue
        data = unhex(st["hex"])
        what = "%s step %d %s" % (os.path.basename(path), st["i"], st["type"])
        if st["fields"] is None:
            assert "decodeError" in st, what
            eq(err_name(R.decode_msg, data), "BAD_MSG", what)
        else:
            mt, f = R.decode_msg(data)
            eq(R.msg_fields_to_json(mt, f), st["fields"], what)
            eq(hexu(R.encode_msg(mt, f)), st["hex"], what + " re-encode")
            if mt == R.JOIN:
                keys[hexu(f["groupId"])] = f["groupKey"]
                eq(R.group_id(f["groupKey"]), f["groupId"], what)
            central, periph, mtu = links[st["link"]]
            if mt == R.HELLO and st["from"] == central:
                hello_c[st["link"]] = f
            elif mt == R.HELLO and "proof" in f:
                hc = hello_c[st["link"]]
                key = keys[hexu(f["groupId"])]
                eq(f["proof"], R.proof_p(key, hc["nonce"], f["nonce"], hc["deviceId"], f["deviceId"]), what + " proofP")
                hello_c[st["link"] + "/p"] = f
            elif mt == R.AUTH and (st["link"] + "/p") in hello_c and st["by"] == "session":
                hc, hp = hello_c[st["link"]], hello_c[st["link"] + "/p"]
                key = keys[hexu(hp["groupId"])]
                eq(f["proof"], R.proof_c(key, hc["nonce"], hp["nonce"], hc["deviceId"], hp["deviceId"]), what + " proofC")
        frames = [hexu(x) for x in frag[(st["link"], st["from"])].fragment(data, links[st["link"]][2])]
        eq(frames, st["frames"], what + " frames")
        got = []
        for fr in frames:
            got += reasm[(st["link"], st["to"])].feed(unhex(fr))
        eq(got, [("deliver", data)], what + " reassembly")
        ok("transcript messages")
    for name, n in j["final"]["nodes"].items():
        for e in n["ledger"]:
            b = unhex(e["b"])
            f = R.decode_body(b)
            eq(R.key_string(f["ns"], f["packet"]), e["key"], path)
            eq(R.crc32(b), e["c"], path)
    ok("transcripts")


def main():
    with open(os.path.join(HERE, "vectors.json"), encoding="utf-8") as fh:
        v = json.load(fh)
    assert v["schema"] == 1 and v["proto"] == R.PROTO
    check_primitives(v)
    check_bodies(v)
    check_apply(v)
    check_messages(v)
    check_frames(v)
    check_pages(v)
    check_routing(v)
    check_events(v)
    check_sessions(v)
    for p in sorted(glob.glob(os.path.join(HERE, "transcripts", "*.json"))):
        check_transcript(p)
    print("all vectors pass: " + ", ".join("%s %d" % kv for kv in checked.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
