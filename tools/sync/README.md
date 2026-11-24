# tools/sync — SYNC v1 vectors, transcripts and reference

Shared test data for the MagicMaker sync hub (`docs/SYNC_HUB_SPEC.md`, phase P1). The C++ (hub
firmware host tests), Kotlin (Android unit tests) and Swift (`ios/SyncCheck`) codecs must all
reproduce these files. The protocol itself is normative in [`docs/SYNC_PROTOCOL.md`](../../docs/SYNC_PROTOCOL.md);
section numbers below (§n) refer to it.

| File | What |
|---|---|
| `sync_ref.py` | Executable reference: codec, comparator, ledger/apply, CRC/FNV/SHA/HMAC, framing, events, routing, session state machine. Python 3 stdlib only, deterministic. |
| `gen_vectors.py` | Writes `vectors.json` and `transcripts/*.json` (fixed keys, nonces, ids and clocks). |
| `check_vectors.py` | Model harness: re-checks every vector and transcript **from the JSON alone**, with `sync_ref.py` as the implementation under test. Copy its structure for the other languages. |
| `vectors.json` | Unit vectors, one array per group (below). |
| `transcripts/*.json` | Golden multi-node sessions (below). |

```
python3 tools/sync/gen_vectors.py           # regenerate (run after any change to sync_ref.py)
python3 tools/sync/gen_vectors.py --check   # CI: exit 1 if the committed files are stale
python3 tools/sync/check_vectors.py         # CI: the JSON is self-consistent and passes
```

The generator builds everything twice and asserts identical output, so it is deterministic.

## Conventions used in all JSON

- Byte strings are **uppercase hex** strings (`"8301E100"`); `null` means absent.
- Every JSON integer is within ±(2⁵³ − 1), so it parses exactly everywhere (Kotlin: read as `Long`;
  Swift: `Int64`/`Int`). 64-bit bitmaps and FNV hashes are 16-digit hex strings.
- Strings (labels, names, notes) are JSON strings; the `…Hex` sibling, where given, holds their exact
  UTF-8 bytes. Compare bytes, not platform strings.
- A decoded object lists **only the fields present on the wire**: no defaults are filled in. Encoding
  that object canonically (§10) gives the vector's hex.
- Error results are names: `"BAD_MSG"`, `"CLOCK"`, … (`constants.errorCodes` maps them to codes).
  `reason` strings are informative; harnesses compare `error` and MAY compare `reason`.
- Enum-like strings: record classes `PRESENCE USER RESET TOMBSTONE NEWWAND`; apply results
  `ACCEPT DUPLICATE STALE BAD_MSG CLOCK`; message type names as in §11 (`constants.messageTypes`).

### Body object (record body, §4)

```json
{"key": {"ns": 0, "packet": "8301…"}, "updatedAt": 1790000000000,
 "origin": "4A1D0B5E77C2903F", "flags": 2, "label": "Main Street Glow",
 "category": 1, "note": "…", "kind": "show", "place": 3}
```

`origin`, `flags`, `label`, `category`, `note`, `kind`, `place` appear only when present.

### Message `fields` object (§11)

Field names are exactly the names in the §11 tables (`deviceId`, `feedHigh`, `seenBy`, …). Types:
integers → numbers; fixed byte fields and `packet` → hex; strings → strings; repeatable fields →
arrays (`seenBy: ["…", "…"]`). Structured values:

| Field | JSON |
|---|---|
| ERR `key` | `{"ns": 0, "packet": "8301…"}` |
| HB `link` | `[{"peerId": "…", "peerKind": 1, "flags": 3}]` |
| HB `evtWm` | `[{"origin": "…", "epoch": 1796000000, "seq": 41}]` |
| REC body | `"bodyHex"` (always), `"body"` (body object, when the body is valid), `"bodyError"` (`"BAD_MSG"`/`"CLOCK"`, when not) |

To encode a REC from JSON use `seq`, `reqId`, `seenBy` and the verbatim `bodyHex`.

### Ledger entry object (§6.1)

```json
{"key": "0:8301…", "u": 1796000000000, "o": "A1B2C3D4E5F60718", "c": 1920166005,
 "class": "USER", "b": "<body hex>", "s": 2, "f": "4A1D0B5E77C2903F"}
```

`o` and `f` are `null` when absent (PRESENCE has no origin; local edits/learns have no syncFrom).
Lists of entries are sorted by `key` (the key string, byte order).

## vectors.json

Top level: `schema` (1), `proto` (1), `generator`, `spec`, `constants`, then the groups.
`constants` carries every protocol constant (`proto`, `maxMsgMin`, `uMinMs`, `futureBoundMs`,
timer values, `messageTypes`, `errorCodes`, …) and `fixtures` (the fixed group keys and device ids).

Each group below is an array (`routing` is an object of arrays). "Check" says what a harness does.

### Primitives

| Group | Item | Check |
|---|---|---|
| `crc32` | `{name, hex, crc}` | CRC-32/ISO-HDLC of `hex` = `crc` |
| `fnv1a64` | `{name, hex, hash}` | FNV-1a 64 of `hex` = `hash` (hex) |
| `sha256` | `{name, hex, digest}` | SHA-256 |
| `hmacSha256` | `{name, keyHex, dataHex, macHex, trunc16Hex?}` | HMAC-SHA256; RFC 4231 TC1–4, 6, 7; TC5 compares the first 16 bytes |
| `groupIds` | `{name, keyHex, groupId, advertTag}` | `SHA-256("MMGROUP1"‖key)[0..7]`; advertTag = its first 2 bytes |
| `proofs` | `{name, keyHex, groupId, nonceC, nonceP, idC, idP, transcriptHex, macInputPHex, macInputCHex, proofP, proofC}` | `T`, the MAC inputs and both proofs (§13.2) |
| `textNormalize` | `{name, fn: "text"\|"kind", input, inputHex, maxBytes, output\|null, outputHex\|null}` | `normalize(input, maxBytes)` / `normalizeKind(input)` (§5.3) |
| `keys` | `{ns, packet, keyHex, keyString, fnv1a64}` | key encoding, key string, hub hash |

### Records

| Group | Item | Check |
|---|---|---|
| `bodies` | `{name, body, hex, len, crc, class, version}` | `encode(body) == hex`, `decode(hex) == body`, CRC, class, `version {updatedAt, origin (zero when absent), crc}` |
| `bodyRejects` | `{name, hex, error, reason}` | `decode(hex)` fails with `error` |
| `clock` | `{name, updatedAt, now\|null, result}` or `{name, bodyHex, now, result}` | future-time check (`now null` = receiver clock unknown); the second form runs `apply` |
| `comparator` | `{name, a, b, expect}` with `a`/`b` = `{updatedAt, origin, crc}` | `compare(a, b) == expect` (−1/0/1) and `compare(b, a) == −expect`; origin is big-endian unsigned |
| `localStamp` | `{name, now, ledgerUpdatedAt, lastLocalStamp, expect}` | §5.2 |

`apply` — ledger scripts. Each item `{name, tombstoneCap, nextSyncSeq, note?, steps, final}`.
Start from an **empty** ledger with that cap and `nextSyncSeq`, `lastLocalStamp = 0`, and run the
steps in order:

| `op` | Fields | Do | `expect` |
|---|---|---|---|
| `remote` | `bodyHex, from, now\|null` | apply a received record from peer `from` (§6.2) | `{status, evicted: [keyString…], entry: ledger entry\|null}` (`entry` only on ACCEPT) |
| `edit` | `class, key {ns, packet}, now, self`, optional `label category kind place note`, USER also `preset userEdited` | local edit (§5.2, §5.3 normalisation, §6.4) | `{bodyHex, updatedAt, evicted, entry\|null}` (`entry` null when the new entry was evicted at once) |
| `learn` | `packet` | local learn (§6.3) | `{created, entry\|null}` |

`final = {nextSyncSeq, lastLocalStamp, tombstones, entries: [ledger entry…]}`.

### Messages and frames

| Group | Item | Check |
|---|---|---|
| `messages` | `{name, type, typeCode, fields, hex, len}` | `encode(type, fields) == hex`; `decode(hex) == (type, fields)` |
| `messageNonCanonical` | `{name, type, hex, fields, canonicalHex}` | decodes to `fields` (unknown tags skipped, explicit defaults kept); canonical re-encode = `canonicalHex` |
| `messageRejects` | `{name, hex, error, reason}` | decode fails with BAD_MSG |
| `messageBadBody` | `{name, hex, fields, bodyError, errKey}` | the REC envelope decodes; the body fails with `bodyError`; `errKey` is the key to put in the ERR (or null) |
| `messageIgnored` | `{name, hex}` | unknown message type: ignored, no error |
| `hbHops` | `{name, inHex, outHex}` | forwarder patch: set the hops TLV value to 1 in place (§16.4) |
| `frames` | `{name, mtu, chunk, startCounter, startSeq, messages: [hex], framesPerMessage, frames: [hex]}` | a fragmenter starting at that counter/seq, fed the messages in order, emits `frames` |
| `reassembly` | `{name, maxMsg, startExpectedSeq?, frames: [hex], expect: [action]}` | a reassembler (expected seq `startExpectedSeq`, default 0) fed the frames in order emits the actions, in order, across all frames |

Reassembly actions: `{"deliver": hex}`, `{"badFrame": "short"|"gap"|"counter"|"restart"|"orphan"}`,
`{"errTooBig": refType}`, `{"errProto": frameVersion}` (§9.3).

### Pages, routing, events

`pages` — `{name, puller, excludeOk, durableHigh, entries: [{seq, bodyHex, syncFrom}], pull, pullHex,
expect: {recSeqs, recs: [hex], pageEnd, pageEndHex}}`. `entries` are the server's current entries
(one per key, superseded ones already absent; `origin` comes from the body). Serve `pull` per §15.2
with exclusion active iff `pull.exclude == 1 && excludeOk`. Absent `limit`/`maxBytes` take their
defaults.

`routing` — object of arrays:

| Key | Item | Function (§) |
|---|---|---|
| `localRec` | `{name, self, sessions: [{peer, subRecords, authed}], expect: {targets, seenBy}}` | local change push (§16.2) |
| `liveRec` | `{name, self, sender, origin\|null, seenBy, sessions, expect}` | first accept of a live REC (§16.2) |
| `evtRelay` | `{name, self, sender, origin, seenBy, sessions: [{peer, subEvents, member}], expect}` | hub EVT relay (§16.3) |
| `androidRoute` | `{name, self, ios: {peer, up, subEvents}\|null, hub: {peer, up}\|null, hubHbAgeMs\|null, hubHbLinks, expect: {route, target\|null, seenBy}}` | Android route 1/2/3 (§16.3) |
| `hbForward` | `{name, self, sender, deviceId, hops, sessions: [{peer, subHeartbeats, member}], expect: {targets}}` | HB forwarding (§16.4) |
| `hbReplace` | `{name, stored\|null, incoming, expect}` (`{bootId, hbSeq}`) | keep-latest rule (§16.4) |
| `subs` | `{selfKind, peerKind, subs}` | HELLO subs table (§16.1) |
| `caps` | `{kind, caps}` | caps by kind (§11.1) |

Targets are listed in session order; `seenBy` in merge order (§16.2).

`eventDedupe` — `{name, steps}`; start with an empty receiver. Steps:
`{"op": "evt", origin, epoch, seq, expect: {result, lost, holes, windows}}` (§8.2) and
`{"op": "gap", origin, epoch, firstAvail, lastAvail, curEpoch, expect: {lost, requests: [{epoch,
afterSeq}], windows}}` (§8.4). `windows` = that origin's windows oldest first,
`{epoch, hc, bits: "16 hex digits"}`.

`replayPlan` — `{name, ring: [[epoch, seq]…] oldest first, curEpoch, curSeq, epoch, afterSeq,
expect: [{"replay": {epoch, seq}} | {"gap": {epoch, firstAvail, lastAvail, curEpoch}}]}` (§8.5).

### Session state machine (`sessions`)

Each item drives **one session end** (§14) through scripted inputs:

```json
{"name": "…",
 "config": {"role": "central", "deviceId": "…", "kind": 3, "bootId": 4097, "maxMsg": 1024, "caps": 1,
            "version": "1.4.0", "name": "iPhone", "peerKind": 1, "tracksEvents": true, "isHub": false},
 "ctx": {"groupId": "…"|null, "groupKey": "…"|null, "dbId": "…", "feedHigh": 3,
         "clockBaseMs": 1796000000000, "ready": true, "nonces": ["…", …],
         "peers": {"<peer deviceId hex>": {"dbId": "…", "wm": 10, "excludeOk": true}}},
 "steps": [{"t": 30, "ctx"?: {…}, "in": {…}, "out": [action…], "after": snapshot}, …]}
```

- Build the session from `config` and `ctx`. `clockMs(t) = clockBaseMs + t` (0 if `clockBaseMs`
  is null). The session takes nonces from `ctx.nonces` in order, one per `startHello` (central) or
  per new handshake (peripheral). `peers` is the node's peer table, shared with the session.
- For each step: if the step has `ctx` (`{groupId, groupKey, dbId, feedHigh, ready}`), set those
  node values **first**; then feed `in` at time `t`:
  `{"in": "link_up", "mtu": n}`, `{"in": "link_down"}`, `{"in": "rx", "hex": message}`,
  `{"in": "timer", "name": n}`, `{"in": "group_changed"}`, `{"in": "rekey"}`, `{"in": "pull_now"}`.
  A timer input whose due time is not exactly `t` (already fired, re-armed or cancelled) is ignored.
- Compare the emitted actions with `out` (same order, same content):

  | Action | JSON |
  |---|---|
  | send | `{"a": "send", "type": "PULL", "hex": "…"}` |
  | state change | `{"a": "state", "to": "AUTHED"}` |
  | hand a message to the node | `{"a": "deliver", "type": "REC"}` |
  | page committed | `{"a": "commit", "wm": 14}` |
  | persist a group key | `{"a": "group", "groupId": "…", "groupKey": "…", "rekey": false}` |
  | node request | `{"a": "node", "what": "send_hb" \| "evt_since" \| "foreign"}` |
  | disconnect | `{"a": "disconnect", "reason": "foreign" \| "auth_timeout" \| "auth_deadline" \| "page_timeout" \| "left_group", "retryMs": n \| null}` |

- Compare the snapshot after the step with `after`:
  `{"state": "SYNCING", "timers": {"HB": 60030, "PAGE": 10030}, "peer"?: {"dbId", "wm", "excludeOk"}}`.
  `timers` maps each armed timer to its absolute due time (names `HELLO AUTH DEADLINE PAGE LIVE_PULL
  HB RETRY BACKOFF`); `peer` is the peer-table entry of this session's peer, once one exists.

## transcripts/*.json

Golden multi-node sessions produced by a discrete-event simulation of whole nodes (sessions +
ledger + feed + routing + events + heartbeats) over in-memory links.

| File | Scenario |
|---|---|
| `first_contact_group_handover.json` | grouped iPhone meets a fresh ungrouped hub: JOIN, restart, proofs, both pull, on-change HB, exclusion |
| `grouped_hub_two_phones.json` | grouped hub; iPhone resumes from watermarks; ungrouped Android gets the key from the hub (peripheral JOIN); live pushes I→H→A and A→H→I with seenBy; a heard packet via route 2; LIVE_PULL re-pulls |
| `reconnect_watermarks.json` | Android edits while the iPhone is away; iPhone relinks at **MTU 23** and pulls only what is new; hub `sync_reset` closes all sessions; both relink and refill the hub |
| `stranger_rejected.json` | other group (FOREIGN both sides), groupId impostor with a bad AUTH, silent old app (10 s deadline), proto-2 HELLO (ERR PROTO, INCOMPATIBLE, deadline) |
| `live_push_forwarding_seenby.json` | triangle: edits reach both peers once, nobody forwards; HBs arrive direct and forwarded; then partial topology: the iPhone forwards an Android edit to the hub |
| `event_catchup.json` | route-1 events; ring-only while unlinked (ring capacity 5); replay on relink; EVT_GAP after overflow; new epoch after a service restart |

Top level:

```json
{"schema": 1, "name": "…", "description": "…", "latencyMs": 15, "clockBaseMs": 1796000000000,
 "nodes": {"I": {…}, "H": {…}},
 "nonces": [{"link": "I-H", "gen": 1, "node": "I", "nonces": ["…", …]}],
 "steps": [ … ],
 "final": {"t": 9000, "nodes": {"I": {…}, …}}}
```

- `nodes.<name>` (initial state): `deviceId kind bootId dbId maxMsg caps version name groupId
  groupKey clockKnown durableHigh nextSyncSeq ledger peers ringCap epoch`; scripted peers (raw
  impostors) only have `deviceId kind scripted: true`. Node clocks read `clockBaseMs + t` (the hub
  reads 0 while `clockKnown` is false).
- `nonces`: the nonces each node consumed on each link incarnation (`gen` counts link-ups of that
  link id), in order. Inject them to reproduce the HELLOs.
- `final.nodes.<name>`: `dbId groupId durableHigh nextSyncSeq ledger peers`, plus `evtWindows`
  (iPhone: origin → windows) and `epoch evtSeq ring` (Android). In every transcript the ledgers of
  all non-scripted nodes are identical at the end (converged).

### Steps

Every step has `i` (index) and `t` (ms), plus `ev`:

| `ev` | Fields | Meaning |
|---|---|---|
| `link_up` | `link, gen, central, peripheral, mtu` | a new link incarnation: fresh sessions, frame counters and seqs at 0 |
| `link_down` | `link, reason` | both ends get `link_down` |
| `msg` | `link, gen, from, to, by, type, hex, fields, frames, decodeError?` | one message sent. `by`: `session` (built by the session core: HELLO AUTH JOIN PULL ERR), `node` (REC PAGE_END HB EVT EVT_SINCE EVT_GAP, node ERRs), `script` (raw impostor). `frames`: the exact frames at the link MTU. `fields` is null when the message does not decode (then `decodeError`). Delivered `latencyMs` later, in order. |
| `state` | `node, link, state` | a session state change (one per transition) |
| `timer` | `node, link, name` | a session timer fired |
| `local` | `node, op, …` | scripted user/node action: `edit` (`cls key bodyHex seq`), `learn` (`key created`), `heard` (`epoch seq packet route`), `service_restart` (`bootId epoch`), `sync_reset` (`dbId`) |
| `apply` | `node, link, key, status, live` | a received REC applied to the ledger |
| `durable` | `node, durableHigh` | a save / flush completed |
| `group` | `node, link, groupId, rekey` | a group key persisted |
| `foreign`, `disconnect` | `node, link[, reason, retryMs]` | session actions |
| `ingest` | `node, link, origin, epoch, seq, result, replay, lost` | iPhone event dedupe result |
| `gap` | `node, link, origin, epoch, lost, requests` | iPhone EVT_GAP handling |
| `note` | `text` | narration |

### How harnesses use transcripts

**P1 (codec level)**, all three languages — see `check_transcript()` in `check_vectors.py`:

1. For each `msg`: decode `hex` → must equal `fields` (or fail when `decodeError` is set); the
   canonical re-encode must equal `hex`.
2. Keep one fragmenter per `(link, from)` and one reassembler per `(link, to)`, reset at each
   `link_up`; fragmenting `hex` at the link MTU must give `frames`, and reassembling them must
   deliver exactly `hex`.
3. HELLO replies with a proof and session-built AUTHs must verify (§13.2) with the group keys of
   `nodes` and of JOIN messages seen so far (central HELLO nonce = nonceC, peripheral's = nonceP).
4. Every `final` ledger body decodes and its CRC matches `c`.

**P2–P4 (node level)**: replay one node against a fake transport. Feed it the `link_up`/`link_down`
events, the messages addressed to it (at `t`), its timers and its `local` steps, inject its nonces,
and require it to emit the same messages (`from == node`) in the same order, the same `state` steps
and the same `final` state. The simulation's non-normative timing choices, which a node-level
replay must mimic: link latency 15 ms; phones save 300 ms after a live accept or local edit and
immediately on a page commit; the hub flushes 2,000 ms after its first dirty record; an on-change HB
(5 s spacing) follows records accepted from pages once they are durable; a disconnect lands 16 ms
after it is decided; the hub learns the time from the first member HELLO with a non-zero clock.

## Regenerating

Change `sync_ref.py` (and `docs/SYNC_PROTOCOL.md`) together, run `gen_vectors.py`, then
`check_vectors.py`, and commit the regenerated JSON with the change. Fixture values are derived as
`SHA-256("mm-sync-vectors:" + label)`; simulated nonces as
`SHA-256("mm-sync-nonce:" + deviceId + u32le counter)[0..7]`.
