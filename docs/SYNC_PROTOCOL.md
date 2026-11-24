# MagicMaker SYNC protocol, version 1 (normative)

Status: **normative** for `proto = 1`. Phase P1 of [SYNC_HUB_SPEC.md](SYNC_HUB_SPEC.md) (§12).

This document fixes the bytes on the wire and the rules that must give identical results on the
ESP32 hub (C++, gnu++11), Android (Kotlin) and the iPhone (Swift 5.9). It is derived from
SYNC_HUB_SPEC.md §2, §3, §9.1 and its appendix, with the amendments at the top of that file (A1–A3).
Where the spec was ambiguous or self-contradictory, this document decides; every such decision is
listed in [§19](#19-decisions-made-in-p1).

The executable reference is [`tools/sync/sync_ref.py`](../tools/sync/sync_ref.py) (Python stdlib).
[`tools/sync/gen_vectors.py`](../tools/sync/gen_vectors.py) writes the shared test vectors
(`tools/sync/vectors.json`) and golden session transcripts (`tools/sync/transcripts/*.json`);
their JSON schema is in [`tools/sync/README.md`](../tools/sync/README.md). The three codecs pass when
they reproduce every vector. If this text and the reference disagree, this text wins and the
reference has a bug.

Out of scope here (P2–P4): BLE transport code, storage formats (the hub log, the phones' JSON),
projection of records onto list rows (spec §2.6, summarised in §6.5), UI, transmit routing.

---

## Contents

1. [Conventions](#1-conventions)
2. [Identifiers and primitives](#2-identifiers-and-primitives)
3. [Record key](#3-record-key)
4. [Record body](#4-record-body)
5. [Versions, comparator, local edits](#5-versions-comparator-local-edits)
6. [Ledger and apply rules](#6-ledger-and-apply-rules)
7. [Clock rules](#7-clock-rules)
8. [Heard-packet events](#8-heard-packet-events)
9. [GATT transport and framing](#9-gatt-transport-and-framing)
10. [Message encoding](#10-message-encoding)
11. [Messages](#11-messages)
12. [Errors](#12-errors)
13. [Sync group and authentication](#13-sync-group-and-authentication)
14. [Session state machine](#14-session-state-machine)
15. [Pull, paging, watermarks, exclusion](#15-pull-paging-watermarks-exclusion)
16. [Live push, forwarding, events routing, heartbeats](#16-live-push-forwarding-events-routing-heartbeats)
17. [Version negotiation](#17-version-negotiation)
18. [Constants](#18-constants)
19. [Decisions made in P1](#19-decisions-made-in-p1)
20. [Conformance](#20-conformance)

---

## 1. Conventions

- MUST, MUST NOT, SHOULD, MAY: as in RFC 2119.
- All integers on the wire are **little-endian**, fixed width: `u8 u16 u32` unsigned, `i8 i16 i32 i64`
  two's complement. The one exception is the comparator, which reads `origin` as an 8-byte
  **big-endian** unsigned number (§5.1); on the wire `origin` is just 8 opaque bytes.
- `‖` is byte concatenation. Hex is written uppercase, most significant nibble first, byte order as on
  the wire (`8301` = bytes `83 01`).
- Strings are UTF-8 with no terminator, no BOM and no Unicode normalisation: the bytes are the value.
- "Node" = the hub (H, kind 1), Android (A, kind 2) or the iPhone (I, kind 3). "Session" = the state
  machine of §14 on one BLE link. A node has one session per link.
- Times: `*Ms` fields are Unix epoch milliseconds; `epoch` (events) is Unix seconds.

## 2. Identifiers and primitives

| Name | Size | Definition |
|---|---|---|
| deviceId | 8 B | Hub: `01 00` ‖ BLE MAC (6 B, as printed). Phones: random, created once, kept outside backups (spec D15). Never all zero. |
| dbId | 8 B | Random; names one incarnation of a node's feed. Regenerated on reset, rollback or corruption. |
| groupKey | 16 B | Random. |
| groupId | 8 B | `SHA-256("MMGROUP1" ‖ groupKey)[0..7]`. All zero = ungrouped. (A generated key whose groupId is all zero MUST be discarded and regenerated.) |
| nonce | 8 B | Random, fresh per handshake (§14). |
| bootId | u16 | Random per boot (hub), service start (Android), launch (iPhone). |

Primitives (all three codecs ship their own portable implementations; vectors in `crc32`,
`fnv1a64`, `sha256`, `hmacSha256`):

- **CRC-32/ISO-HDLC** (zlib `crc32`): reflected poly `0x04C11DB7`, init `0xFFFFFFFF`, xorout
  `0xFFFFFFFF`. Check value: `"123456789"` → `0xCBF43926`.
- **FNV-1a 64**: offset basis `0xCBF29CE484222325`, prime `0x100000001B3`, `h = (h XOR byte) × prime`
  mod 2⁶⁴ per byte. `""` → `CBF29CE484222325`, `"a"` → `AF63DC4C8601EC8C`. Used for the hub's key
  hash over the encoded key bytes (§3).
- **SHA-256** (FIPS 180-4) and **HMAC-SHA256** (RFC 2104). Known answers include RFC 4231 test cases
  1–4, 6, 7 and the 128-bit truncation case 5. Test case 2: key `"Jefe"`, data
  `"what do ya want for nothing?"` →
  `5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843`.

## 3. Record key

```
key = ns (u8) ‖ packet (3..29 B)
```

| ns | Name | Meaning |
|---|---|---|
| 0 | LIB | the library row(s) with that packet hex, in any list |
| 1 | NEWWAND | the user's name for a generated New-Wand code |

- `packet` is the decoded canonical hex (`HexUtils.canonicalHex`): the full manufacturer field,
  which MUST start with `83 01` and be 3..29 bytes long. Anything else is BAD_MSG.
- Other `ns` values are BAD_MSG in v1.
- Phones' ledger map key ("key string"): `"<ns>:<HEX>"` with decimal ns and uppercase hex, e.g.
  `0:8301E100E90C00010F4D575A940705488BB0`.
- Hub index hash: FNV-1a 64 over the encoded key bytes (`ns ‖ packet`). Example: key
  `008301E100E90C00010F4D575A940705488BB0` → `669E0D770E9844DA`.

## 4. Record body

### 4.1 Layout

A record body is a sequence of TLVs `[tag u8][len u8][value len bytes]`:

| Tag | Field | Type / length | Value rules |
|---|---|---|---|
| 0x10 | key | 4..30 B | `ns ‖ packet` (§3) |
| 0x11 | updatedAt | i64, 8 B | §4.4 |
| 0x12 | origin | 8 B | a deviceId; never all zero |
| 0x13 | flags | u8, 1 B | bit0 DELETED, bit1 USER_EDITED, bit2 PRESET; bits 3–7 MUST be 0; never 0 |
| 0x14 | label | 1..64 B | valid UTF-8 |
| 0x15 | category | u8, 1 B | 0 UNKNOWN, 1 SHOW, 2 ANIMATION, 3 COLOR |
| 0x16 | note | 1..160 B | valid UTF-8 |
| 0x17 | kind | 1..16 B | printable ASCII `0x20..0x7E` (the row's `typeInfo`) |
| 0x18 | place | u8, 1 B | 1 presets, 2 colors, 3 library, 4 raw |

"Valid UTF-8" is RFC 3629: no overlong forms, no surrogates (U+D800..U+DFFF), nothing above
U+10FFFF, no truncated sequences.

### 4.2 Canonical form

A body is **canonical** iff all of the following hold. Encoders MUST produce only canonical bodies;
receivers MUST reject a non-canonical body with **BAD_MSG** (spec §2.2).

1. Total length ≤ **360** bytes (`oversize`). (The largest valid body is 307 bytes.)
2. The TLVs parse exactly to the end (`truncated`).
3. Every tag is one of 0x10..0x18 (`unknown_tag`): **no unknown tags** in a body.
4. Tags strictly ascending (`order`); each at most once (`duplicate`).
5. Each value has the width/length in §4.1 (`length`) and a value in range (`range`,
   `packet_prefix`, `utf8`, `ascii`).
6. `key` and `updatedAt` present (`missing`).
7. `origin` present ⇔ it is non-zero (`zero_origin`); `flags` present ⇔ non-zero (`zero_flags`).
8. The class rules of §4.4 hold.

Because every field has exactly one encoding and absent fields are omitted, a canonical body is
byte-identical to its re-encoding; implementations MAY therefore validate by "decode, then
re-encode and compare", or by checking rules 1–8 directly. The reason tags in parentheses appear in
the `bodyRejects` vectors (informative; only the error code is normative).

`bodyCrc` = CRC-32 over the canonical body bytes.

### 4.3 Worked examples

PRESENCE of `8301E100E90C00010F4D575A940705488BB0` (31 bytes, CRC `0xCE6592D2`):

```
10 13 00 8301E100E90C00010F4D575A940705488BB0     key: ns 0 + 18-byte packet
11 08 0100000000000000                            updatedAt = 1
```

TOMBSTONE (38 bytes, CRC `0x11642507`):

```
10 0D 00 8301E100E90600220F5C57B0
11 08 146C50C4A0010000                            updatedAt = 1790000000020
12 08 4A1D0B5E77C2903F                            origin
13 01 01                                          flags = DELETED
```

### 4.4 Record classes and validity

The class is decided by `ns`, `flags`, `origin` and content; then `updatedAt` is checked against the
class. Check order (it decides BAD_MSG vs CLOCK when several rules fail): structural rules of §4.2
(1–7) → `updatedAt ≤ 0` is BAD_MSG → field presence for the class (BAD_MSG) → time rule for the
class.

| Class | Shape (ns, flags) | origin | Required | Allowed optional | Forbidden | updatedAt |
|---|---|---|---|---|---|---|
| PRESENCE | LIB, flags absent, no origin, no content | absent | — | — | 0x12..0x18 | exactly **1** |
| USER | LIB, USER_EDITED and/or PRESET, not DELETED | required | label, category, place | kind, note | — | 2 (`LEGACY_USER_ANDROID`), 3 (`LEGACY_USER_IOS`), or ≥ 1.5e12 |
| RESET | LIB, flags absent, origin present | required | — | note | label, category, kind, place | ≥ 1.5e12 |
| TOMBSTONE | LIB, flags = DELETED exactly | required | — | — | label, category, note, kind, place | ≥ 1.5e12 |
| NEWWAND (name) | NEWWAND, flags absent | required | label | note | category, kind, place | 2, 3 or ≥ 1.5e12 |
| NEWWAND (deleted) | NEWWAND, flags = DELETED | required | — | — | label, note, category, kind, place | ≥ 1.5e12 |

Time rules (`U_MIN_MS` = 1,500,000,000,000):

- `updatedAt ≤ 0` → **BAD_MSG**.
- `updatedAt = 1` with any shape but PRESENCE → **BAD_MSG**; a PRESENCE shape with any other
  `updatedAt` → BAD_MSG (that would be a RESET without origin).
- `updatedAt ∈ {2, 3}` where the class does not allow it → **BAD_MSG**.
- `4 ≤ updatedAt < U_MIN_MS` → **CLOCK** (the record is well formed but its clock is invalid).
- NEWWAND with USER_EDITED or PRESET → BAD_MSG. Any DELETED combination other than exactly
  `DELETED` on LIB → BAD_MSG.

### 4.5 Body field semantics (informative)

USER is **full state**: label, category, kind, note, place and the PRESET bit together are the
user's current view of the row; a newer USER replaces all of them. `place` is only a hint for a
receiver that has no row with that hex. RESET means "the user cleared the name": label and category
are derived locally on each node; `note` is the only content. The NEWWAND label is the name.

## 5. Versions, comparator, local edits

### 5.1 Comparator

```
version(record) = (updatedAt as i64, origin as u64 big-endian (0 when absent), bodyCrc as u32)
```

Versions compare **lexicographically** (signed `updatedAt`, then unsigned `origin`, then unsigned
CRC). An incoming record is accepted iff `version(incoming) > version(ledger entry)`; a key with no
entry accepts any valid record. Equal versions are a **duplicate**: no change, not forwarded. (Two
different bodies with equal `(updatedAt, origin)` and colliding CRCs are treated as one version;
accepted risk, ≈ 2⁻³² per tie.)

Because ties break on origin and then on CRC, the winner never depends on arrival order (`apply`
vectors "same updatedAt…" and "reverse order…").

### 5.2 Local edit stamp

A user edit on node N writes a new version with `origin = N.deviceId` and

```
updatedAt = max(nowMs, ledger.updatedAt + 1, lastLocalStamp + 1, 1_500_000_000_000)
lastLocalStamp = updatedAt          (persisted with the ledger)
```

where `ledger.updatedAt` is 0 when the key has no entry. An edit therefore always beats the
version it edits whatever the clock skew, two edits in one millisecond stay ordered, and a phone
whose clock reads before 2017 still produces a valid record (the floor is a P1 decision).

### 5.3 Text normalisation for local edits

Before a label, note or kind is stored or sent, local edit APIs normalise it; the stored row and
the record therefore never differ. Receivers do **not** re-normalise (they validate only §4).

`normalize(s, maxBytes)`:

1. **trim**: remove leading and trailing code points in the Unicode **White_Space** set, exactly:
   U+0009–U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F,
   U+3000. (Not the platform's notion of whitespace; U+200B ZERO WIDTH SPACE is *not* trimmed.)
2. **truncate**: keep the longest prefix of whole code points whose UTF-8 length ≤ `maxBytes`.
   Work on Unicode scalars (Swift `unicodeScalars`, Kotlin code points), not graphemes or UTF-16
   units.
3. **trim** again (so `normalize` is idempotent).
4. Empty → the field is absent.

label: `maxBytes` 64. note: 160. kind: first replace every code point outside `0x20..0x7E` by `?`,
then `normalize(…, 16)`. A blank label on a rename means RESET (LIB) or a NEWWAND delete.

## 6. Ledger and apply rules

### 6.1 Ledger entry

Each node keeps, per key, the winning **verbatim** canonical body (spec D6) with:

| Field | Meaning |
|---|---|
| `u`, `o`, `c` | updatedAt, origin (or none), bodyCrc: the version |
| `b` | the body bytes (phones store base64; PRESENCE MAY be omitted and recomputed) |
| `s` | local feed seq (`syncSeq`), assigned on store: `s = nextSyncSeq++` |
| `f` | `syncFrom`: the deviceId of the peer it was accepted from; none for local edits/learns |

Pages and live pushes serve `b` verbatim; nodes never rebuild bodies from list rows.

### 6.2 Apply (remote record)

```
apply(body, sender, now):
  decode + validate (§4)               -> BAD_MSG or CLOCK on failure, ledger unchanged
  if now known and updatedAt > now + 24 h -> CLOCK (§7), ledger unchanged
  cmp = compare(version(body), version(entry))      (no entry: accept)
  cmp == 0 -> DUPLICATE        cmp < 0 -> STALE      (both: ledger unchanged)
  cmp > 0  -> ACCEPT: entry = {body, s = nextSyncSeq++, f = sender}; then tombstone cap (§6.3)
```

The result codes `ACCEPT`, `DUPLICATE`, `STALE`, `BAD_MSG`, `CLOCK` are what the `apply` vectors check.
A rejected record from a peer is answered with `ERR{code, refType=0x03, key}` (§12); the page
still advances past it (§15.3).

### 6.3 Tombstones

- A user delete of a syncable key writes a TOMBSTONE (NEWWAND: the deleted form). Bulk deletes
  tombstone only keys that have a ledger entry.
- **Learn paths check the ledger**: a local learn creates a PRESENCE entry (`updatedAt = 1`, `s` =
  next, `f` none) **only when the key has no entry at all**. A tombstoned (or any) entry blocks it.
  An explicit save-as-preset is a USER edit (§5.2) and beats the tombstone.
- **No time-based garbage collection.** Phones cap tombstones at **5,000**. "Tombstone" here means
  any entry with the DELETED flag, in either namespace. After a store that makes the count exceed
  the cap, remove the entry with the **smallest version** (ties: smallest encoded key bytes), until
  the count is at the cap. The key is left with no entry. (A just-stored tombstone may be the one
  evicted.) The hub keeps tombstones as ordinary records under its capacity policy (spec §4.8).

### 6.4 Local operations (ledger side)

| Operation | Ledger effect |
|---|---|
| user edit (rename, recategorise, note, save preset) | USER (or RESET if the label is blank), stamp §5.2, `f` none |
| user delete | TOMBSTONE, stamp §5.2 |
| New-Wand name set / cleared | NEWWAND name / deleted, stamp §5.2 |
| learn | PRESENCE iff no entry |

### 6.5 Projection (informative; P3/P4)

The ledger is the replicated state; list rows are its projection, per spec §2.6: TOMBSTONE removes
learned rows and user presets for the hex (built-in presets reset to built-in label/category); USER
sets label/category/kind/note/userEdited on every row with the hex (PRESET adds or, when newer,
removes the user preset row; no row → create in `place`); RESET derives label/category locally;
PRESENCE creates a row through the learn routine only when none exists (a declined learn still keeps
the entry); NEWWAND sets or removes `newwand_names[HEX]`. A PRESENCE learned from a heard-packet
event gets `f = event origin` (spec §6.5 step 5).

## 7. Clock rules

- Phones reject an incoming record with `updatedAt > now + 86,400,000` (24 h) with ERR CLOCK and the
  key. Exactly `now + 24 h` is accepted. PRESENCE (`updatedAt = 1`) is never in the future.
- The invalid range `4 ≤ updatedAt < 1.5e12` is CLOCK regardless of the receiver's clock (§4.4).
- The hub uses `esp_timer` + an epoch offset learned from member phones (HELLO `clockMs` and direct
  HB `ts`, median of the latest per phone). Until it knows the time it skips the future check, sends
  `clockMs = 0` in HELLO and `ts = 0` in HB.
- A node whose own clock is unknown never stamps local records (the hub has no local edits).

## 8. Heard-packet events

### 8.1 Identity

`eventId = (origin 8 B, epoch u32, seq u32)`. Only Android originates events. At each service start
Android sets `epoch = max(nowSeconds, lastEpoch + 1)` and persists it (identity file); `seq` restarts
at 1 for each epoch. `epoch ≥ 1`, `seq ≥ 1`.

### 8.2 Receiver dedupe window (iPhone)

Per origin the receiver keeps the windows of the **two newest epochs**; a window is
`{epoch, hc, bits}` where `hc` is the highest contiguous seq received and bit *i* of the 64-bit
`bits` means seq `hc + 1 + i` was received. On `receive(origin, epoch, seq)`:

1. No window for `(origin, epoch)`:
   - origin unknown (first contact): open `{epoch, hc = seq − 1, bits = 0}`. History before the first
     event seen is not requested.
   - `epoch` newer than the newest window: open `{epoch, hc = 0, bits = 0}`; keep only the two
     newest windows.
   - otherwise (older than the kept epochs): **DUPLICATE**.
2. `seq ≤ hc` → DUPLICATE.
3. `seq > hc + 64` → slide: `advanceFloor(seq − 64)` (below). The seqs passed over that were never
   received are counted as lost.
4. If bit `seq − hc − 1` is set → DUPLICATE. Else set it, then **normalise**: while bit 0 is set,
   `hc += 1; bits >>= 1`. → ACCEPT.

`advanceFloor(w, floor)`: if `floor ≤ hc` nothing; else `shift = floor − hc`,
`lost = shift − popcount(bits & (2^shift − 1))` (all bits if `shift ≥ 64`), `bits >>= shift`
(0 if `shift ≥ 64`), `hc = floor`, normalise. Holes: after an ACCEPT, `bits ≠ 0` means a seq jump.

### 8.3 Catch-up requests (iPhone)

The iPhone sends `EVT_SINCE{origin, epoch, afterSeq = hc, requester = self}` for the **newest**
window of each tracked origin:

- on AUTHED, on a session that can supply events (§14.5, AUTHED entry step 5);
- after an ACCEPT that leaves holes (`bits ≠ 0`), on the session the event arrived on;
- as told by an EVT_GAP (§8.4).

Except at AUTHED, a request equal to the last one sent for that `(origin, epoch)` is not repeated.
The iPhone's HB carries `evtWm = (origin, newest epoch, hc)` per tracked origin (≤ 4).

### 8.4 EVT_GAP handling (iPhone)

On `EVT_GAP{origin, epoch, firstAvail, lastAvail, curEpoch}`:

- `firstAvail > 0` and a window for `epoch` exists with `firstAvail > hc + 1`: `advanceFloor(window,
  firstAvail − 1)` (count the lost), then `EVT_SINCE(epoch, hc)`.
- `firstAvail = 0` and `curEpoch > epoch`: the epoch is gone. Open a window for `curEpoch`
  (`hc = 0`) unless one exists or a newer one exists, and send `EVT_SINCE(curEpoch, hc)`.
- otherwise nothing.

### 8.5 Android ring and replay plan

Android keeps the last 2,000 encoded EVTs in RAM (cleared at service restart). A catch-up request
`(epoch e, afterSeq s)` — from EVT_SINCE, or from an iPhone HB `evtWm` that is behind
(`e < curEpoch`, or `e = curEpoch` and `s < curSeq`) — is answered with this plan, sent in order
over the current route (§16.3; dropped when there is none):

```
plan(e, s):
  e > curEpoch                     -> nothing
  e == curEpoch                    -> planCur(s)
  ring has (e, s+1)                -> replay (e, q) for every ring q > s, then planCur(0)
  ring has e and s >= max seq of e -> planCur(0)                (complete for e)
  otherwise                        -> GAP{e, firstAvail = min seq of e in ring or 0,
                                          lastAvail = max or 0, curEpoch}
planCur(s):
  s >= curSeq                      -> nothing
  ring has (curEpoch, s+1)         -> replay (curEpoch, q) for ring q > s
  otherwise                        -> GAP{curEpoch, min or 0, max or 0, curEpoch}
```

Replays are the stored EVT with `flags.replay` (bit1) set and `seenBy` for the route. Android
skips a request identical in `(requester, epoch, afterSeq)` to one it served less than 5 s ago (the
AUTHED HB and EVT_SINCE ask the same thing).

## 9. GATT transport and framing

### 9.1 Characteristic

SYNC `A7830006-0000-1000-8000-00805F9B34FB` in service `A7830001-…`; WRITE | WRITE_NO_RESPONSE |
NOTIFY with CCCD 0x2902. Central → peripheral: write without response. Peripheral → central:
notification. The iPhone is always central; Android is central to the hub and peripheral to the
iPhone. A peer without SYNC is "transmit-only, no sync".

### 9.2 Frame

Each ATT value carries one frame: a 2-byte header plus a chunk of the message.

```
byte 0:  bits 7..6  frame version = 01
         bit  5     START  (first frame of a message)
         bit  4     END    (last frame of a message)
         bits 3..0  message counter
byte 1:  frame seq
bytes 2..: chunk, 1 .. MTU − 5 bytes
```

- **chunk size** = `MTU − 3 (ATT) − 2 (header)`. MTU 23 → 18, 185 → 180, 247 → 242. MTU range
  23..517. On iOS use `maximumWriteValueLength(for: .withoutResponse) − 2`.
- **message counter**: 0 for the first message a sender sends on the link after link-up, +1 per
  message (mod 16); the same value in every frame of one message.
- **frame seq**: 0 for the first frame a sender sends after link-up, +1 per frame (mod 256), per
  direction, across messages.
- A message of `L` bytes (`L ≥ 1`) is sent as `ceil(L / chunk)` frames; a one-frame message has
  START and END both set (`0x70 | counter` with version 01). Frames of different messages are never
  interleaved in one direction (one outbox per link); whole messages may interleave freely.

Example, `SUB{subs=5}` = `09 01 01 05` as the first message on a link: frame `70 00 09 01 01 05`.

### 9.3 Reassembly

Per direction the receiver keeps `expected` (0 at link-up), an optional partial buffer with its
counter, a `skip` flag and a "PROTO sent" flag. For each frame:

1. Fewer than 3 bytes → count BAD_FRAME (`short`), drop.
2. Version ≠ 01 → drop without touching any state; the first time on this link, answer
   `ERR{PROTO}`.
3. If `seq ≠ expected`: count BAD_FRAME (`gap`), drop any partial, `skip = true`. Then in all cases
   `expected = seq + 1 mod 256` and continue with this frame.
4. START: if a partial is open, count BAD_FRAME (`restart`). Begin a new partial with this chunk and
   this counter; `skip = false`.
5. Not START, no partial: if `skip` is false count BAD_FRAME (`orphan`); drop. (Frames after a gap,
   counter error or TOO_BIG are dropped silently until the next START.)
6. Not START, counter ≠ the partial's: count BAD_FRAME (`counter`), drop the partial, `skip = true`.
   Else append.
7. If the partial now exceeds the receiver's `maxMsg`: drop it, `skip = true`, answer
   `ERR{TOO_BIG, refType = first byte of the partial}`.
8. END: deliver the message.

BAD_FRAME is counted locally; a node MAY tell the peer with `ERR{BAD_FRAME}` at most once per 10 s.

### 9.4 Message sizes

`maxMsg` (HELLO) is the largest message a node accepts: hub **512**, phones **1024**; it MUST be
≥ 512. Every v1 message fits in 512 bytes by construction (largest REC 357 B, HB 247 B, EVT
138 B, HELLO 136 B), so a v1 sender never needs to split or skip anything; a node MUST NOT send a message
larger than the peer's `maxMsg`.

At MTU 23 everything works with small pages (§15.2) and STATUS/Diag show `MTU23`.

## 10. Message encoding

```
message = type (u8) ‖ TLV*          TLV = tag (u8) ‖ len (u8) ‖ value (len bytes)
```

Decoding rules (`messageRejects` vectors carry the reason tags in parentheses):

1. Empty message → BAD_MSG (`empty`). TLVs must parse exactly to the end (`truncated`).
2. **Unknown message type** (0x00, 0x0D..0xFF in v1): ignored silently (counted), no ERR.
3. **Tag order**: tags are non-decreasing (`order`). A tag may repeat (consecutively) only if it
   is repeatable for that message type, or unknown (`duplicate`).
4. **Unknown tags are skipped** (forward compatibility), but they still take part in the order rule.
5. Known tags: exact width for integers and fixed-size fields; strings 1..max bytes and valid UTF-8;
   declared ranges (`length`, `range`, `utf8`, `packet_prefix`, `count`).
6. Every mandatory tag present (`missing`), else BAD_MSG.
7. A repeatable tag over its maximum count → BAD_MSG (`count`).
8. **REC**: tags 0x10..0x1F are body tags; they are collected, in order of appearance, into the
   body bytes and validated as a body (§4), separately from the envelope (§11.4).
9. Decoders accept an optional field that is present with its default value.

Canonical encoding (what every encoder emits, and what all vectors contain): tags ascending;
repeatable tags consecutive in list order; an optional field omitted when absent **or equal to its
default**; REC body bytes verbatim after the envelope tags. A decoder followed by the canonical
encoder therefore reproduces any canonical message byte for byte (`messages` vectors) and
normalises the rest (`messageNonCanonical`: explicit defaults, unknown tags).

Any decode failure of a non-ERR message is answered with `ERR{BAD_MSG, refType = type}`. An ERR is
never answered with an ERR.

## 11. Messages

Type codes:

| Type | Name | Sent by | Purpose |
|---|---|---|---|
| 0x01 | HELLO | both | identity, group, nonce, feed position, subscriptions |
| 0x02 | PULL | both | request a feed page |
| 0x03 | REC | both | one record version (page or live) |
| 0x04 | PAGE_END | both | ends a page |
| 0x05 | EVT | A (origin), H (relay) | heard packet |
| 0x06 | EVT_SINCE | I (or H relaying) | replay request |
| 0x07 | EVT_GAP | A (or H relaying) | the ring no longer covers the request |
| 0x08 | HB | all | heartbeat |
| 0x09 | SUB | both | change subscriptions |
| 0x0A | ERR | both | error |
| 0x0B | AUTH | central | group proof |
| 0x0C | JOIN | grouped node | hand over the group key (or rekey) |

In the tables: **M** mandatory, **O** optional; "default" is the value assumed when absent (and
omitted by encoders); `8 B` etc. are fixed-size byte strings; `str ≤ n` is UTF-8, 1..n bytes.

### 11.1 HELLO 0x01

| Tag | Field | Type | M/O | Rules |
|---|---|---|---|---|
| 0x01 | proto | u8 | M | 1. A HELLO whose **first TLV is `01 01 xx` with xx ≠ 01** is answered with ERR PROTO before any other decoding (§17). |
| 0x02 | deviceId | 8 B | M | |
| 0x03 | kind | u8 | M | 1 hub, 2 android, 3 ios; else BAD_MSG |
| 0x04 | dbId | 8 B | M | |
| 0x05 | clockMs | i64 | M | ≥ 0; 0 = unknown |
| 0x06 | feedHigh | u32 | M | sender's durableHigh |
| 0x07 | subs | u8 | M | bit0 records, bit1 events, bit2 heartbeats; other bits ignored (send 0). What the sender wants to **receive** on this session (§16.1). |
| 0x08 | caps | u16 | O, default 0 | bit0 serves feed, bit1 originates events, bit3 transmitter, bit4 device-side programs, bit5 loops-by-hex; others ignored |
| 0x09 | maxMsg | u16 | M | ≥ 512 |
| 0x0A | bootId | u16 | M | |
| 0x0B | version | str ≤ 16 | O | |
| 0x0C | name | str ≤ 20 | O | |
| 0x0D | groupId | 8 B | M | all zero = ungrouped |
| 0x0E | nonce | 8 B | M | |
| 0x0F | proof | 16 B | O | only in the peripheral's reply, only when both groupIds are equal and non-zero (§13.2); ignored otherwise |

caps by kind (v1): hub `0x0039`, Android `0x003B`, iPhone `0x0001`.

### 11.2 AUTH 0x0B and JOIN 0x0C

AUTH: `0x01 proof 16 B` (M).

JOIN: `0x01 groupId 8 B` (M, non-zero), `0x02 groupKey 16 B` (M), `0x03 flags u8` (O, default 0;
bit0 rekey; other bits ignored). A receiver MUST check `groupId == SHA-256("MMGROUP1" ‖ groupKey)[0..7]`.

### 11.3 PULL 0x02

| Tag | Field | Type | M/O | Rules |
|---|---|---|---|---|
| 0x01 | reqId | u8 | M | 1..255 |
| 0x02 | since | u32 | M | serve seqs > since |
| 0x03 | limit | u8 | O, default 24 | 1..32 |
| 0x04 | maxBytes | u16 | O, default 1536 | 256..1536; budget of the page's encoded REC messages |
| 0x05 | dbId | 8 B | M | the server dbId that `since` refers to |
| 0x06 | exclude | u8 | O, default 0 | 0/1 |

Example (defaults omitted): `02 01 01 01 02 04 00000000 05 08 1269208CA2190C2D`.

### 11.4 REC 0x03

| Tag | Field | Type | M/O | Rules |
|---|---|---|---|---|
| 0x01 | seq | u32 | M | the sender's feed seq of this entry (informative; never used as a watermark) |
| 0x02 | reqId | u8 | M | 0 = live; else the PULL's reqId |
| 0x03 | seenBy | 8 B | O, repeatable ≤ 4 | live only: present with `reqId ≠ 0` is BAD_MSG |
| 0x10–0x18 | body | | M | the record body, verbatim and canonical |

- Envelope errors (missing seq, > 4 seenBy, …) make the whole message BAD_MSG.
- A **body** error does **not**: the REC still counts toward the page (§15.3); the receiver rejects
  the record with `ERR{BAD_MSG or CLOCK, refType 0x03, key}` (key when the 0x10 TLV parsed). Body
  tags 0x19..0x1F are unknown body tags (BAD_MSG for the body). Tags ≥ 0x20 are envelope tags
  (unknown ones skipped).
- Largest REC: 1 + 6 + 3 + 4 × 10 + 307 = 357 bytes.

### 11.5 PAGE_END 0x04

| Tag | Field | Type | M/O | Rules |
|---|---|---|---|---|
| 0x01 | reqId | u8 | M | 1..255 |
| 0x02 | scannedTo | u32 | M | highest seq examined, ≤ durableHigh (§15.2) |
| 0x03 | more | u8 | M | 0/1 |
| 0x04 | feedHigh | u32 | M | server's durableHigh |
| 0x05 | count | u8 | M | number of RECs in the page |

### 11.6 EVT 0x05

| Tag | Field | Type | M/O | Rules |
|---|---|---|---|---|
| 0x01 | origin | 8 B | M | |
| 0x02 | epoch | u32 | M | ≥ 1 |
| 0x03 | seq | u32 | M | ≥ 1 |
| 0x04 | ts | i64 | M | ms, ≥ 0 |
| 0x05 | packet | 3..29 B | M | starts `83 01` |
| 0x06 | rssi | i8 | O | absent = unknown |
| 0x07 | count | u16 | O, default 1 | ≥ 1 (coalesced sightings) |
| 0x08 | lat | i32 | O | 1e-7°, ±900,000,000 |
| 0x09 | lon | i32 | O | 1e-7°, ±1,800,000,000 |
| 0x0A | acc | u16 | O | metres. lat, lon, acc are all present (a fix) or all absent; else BAD_MSG |
| 0x0B | addr | 6 B | O | advertiser address |
| 0x0C | flags | u8 | O, default 0 | bit0 tagged own-band address, bit1 replay; other bits kept and ignored |
| 0x0D | seenBy | 8 B | O, repeatable ≤ 4 | |

### 11.7 EVT_SINCE 0x06 and EVT_GAP 0x07

EVT_SINCE: `0x01 origin 8 B`, `0x02 epoch u32`, `0x03 afterSeq u32`, `0x04 requester 8 B` (all M).

EVT_GAP: `0x01 origin 8 B`, `0x02 epoch u32`, `0x03 firstAvail u32` (0 = none), `0x04 lastAvail
u32`, `0x05 curEpoch u32`, `0x06 requester 8 B` (all M).

### 11.8 HB 0x08 (spec §9.1)

| Tag | Field | Type | M/O | Rules |
|---|---|---|---|---|
| 0x01 | deviceId | 8 B | M | the described device |
| 0x02 | kind | u8 | M | 1..3 |
| 0x03 | bootId | u16 | M | |
| 0x04 | hbSeq | u32 | M | +1 per HB the device builds |
| 0x05 | ts | i64 | M | ms; 0 = unknown |
| 0x06 | uptimeS | u32 | M | |
| 0x07 | battPct | i8 | O, default −1 | −1..100 |
| 0x08 | battMv | i16 | O, default −1 | ≥ −1 |
| 0x09 | charging | i8 | O, default −1 | −1, 0, 1 |
| 0x0A | runtimeMin | i16 | O, default −1 | −1..5999 |
| 0x0B | version | str ≤ 16 | O | |
| 0x0C | name | str ≤ 20 | O | |
| 0x0D | link | 10 B, repeatable ≤ 4 | O | `peerId 8 ‖ peerKind u8 (1..3) ‖ flags u8` — flags bit0 synced (session SYNCED), bit1 tx-ready (peer is a transmitter, caps bit3), bit2 wifi |
| 0x0E | state | u16 | O, default 0 | spec §9.1 state bits |
| 0x0F | hops | u8 | M | 0 originated, 1 forwarded |
| 0x10 | feedHigh | u32 | M | durable |
| 0x11 | dbId | 8 B | M | |
| 0x12 | records | u32 | M | ledger size |
| 0x13 | hubAirAgoS | u16 | O | Android only; 0xFFFF = never |
| 0x14 | evtWm | 16 B, repeatable ≤ 4 | O | `origin 8 ‖ epoch u32 ‖ seq u32` (iPhone) |

State bits (0x0E): bit0 scanning, bit1 keepAwake, bit2 txLoop, bit3 wandLoop, bit4 randomShow,
bit5 lowPower, bit6 txBusy, bit7 primary=ESP32, bit8 failoverActive, bit9 hubFull, bit10 clockSkew,
bit11 syncNotReady.

### 11.9 SUB 0x09 and ERR 0x0A

SUB: `0x01 subs u8` (M); replaces the sender's subs for the rest of the session.

ERR:

| Tag | Field | Type | M/O |
|---|---|---|---|
| 0x01 | code | u8 | M, ≥ 1 (unknown codes are logged) |
| 0x02 | refType | u8 | O: the message type the error is about |
| 0x03 | key | ns + packet | O: the record (CLOCK, FULL, COLLISION, BAD_MSG of a record) |
| 0x04 | detail | str ≤ 40 | O |
| 0x05 | dbId | 8 B | O; present with DB_CHANGED (the sender's current dbId) |
| 0x06 | retryMs | u16 | O; BUSY / NOT_READY (absent = 1000) |

## 12. Errors

| Code | Name | Sent when | Receiver behaviour (session reaction in §14.5) |
|---|---|---|---|
| 1 | BAD_FRAME | MAY, ≤ 1 per 10 s, after counting reassembly drops | count, continue |
| 2 | TOO_BIG | reassembly exceeded maxMsg (§9.3) | log; if a pull is outstanding, halve maxBytes (≥ 256) and re-PULL the same since |
| 3 | BAD_MSG | decode failure (§10), invalid record body | log (record: not stored) |
| 4 | PROTO | HELLO proto ≠ 1, or frame version ≠ 01 | INCOMPATIBLE: no sync on this link, transmit still works; UI "update app/firmware" |
| 5 | DB_CHANGED | a PULL's dbId ≠ the server's dbId | wm[peer] = 0, store the new dbId, excludeOk = false, re-PULL since 0 |
| 6 | FULL | hub library full (spec §4.8) | the record is not stored on the hub; phones keep it |
| 7 | CLOCK | record in the invalid range or > now + 24 h | rejected; the originator re-stamps once its clock is sane |
| 8 | BUSY | hub cannot take it now | refType PULL: re-PULL after retryMs; a live REC: nothing (it arrives by pull) |
| 9 | COLLISION | hub 64-bit hash collision | log; not stored on the hub |
| 10 | AUTH | group mismatch, bad proof, unacceptable JOIN | the link is FOREIGN (§14) |
| 11 | NOT_READY | hub index still building (HELLO or PULL) | retry after retryMs (HELLO: same nonce) |

An ERR is never answered with an ERR. Once a session is FOREIGN it sends nothing more (the ERR AUTH
that announces it goes out on entry).

## 13. Sync group and authentication

### 13.1 Group

`groupKey` 16 random bytes, `groupId = SHA-256("MMGROUP1" ‖ groupKey)[0..7]`. The iPhone creates the
group the first time this version runs; Android and the hub start ungrouped. Android advertises
`groupId[0..1]` in its service data (spec §3.1).

### 13.2 Proofs (the exact bytes that are MACed)

```
T      = nonceC (8) ‖ nonceP (8) ‖ idC (8) ‖ idP (8)                    32 bytes
proofP = HMAC-SHA256(groupKey, "MMSYNC1P" ‖ T)[0..15]                   peripheral → central (HELLO 0x0F)
proofC = HMAC-SHA256(groupKey, "MMSYNC1C" ‖ T)[0..15]                   central → peripheral (AUTH 0x01)
```

`"MMSYNC1P"` = `4D4D53594E433150`, `"MMSYNC1C"` = `4D4D53594E433143`, ASCII without terminator.
`nonceC`/`idC` are the central's HELLO nonce and deviceId; `nonceP`/`idP` the peripheral's. The MAC
input is therefore 40 bytes. Proofs are compared in constant time.

Example (vector "counting bytes"): key `000102…0F`, nonceC `0001020304050607`, nonceP
`08090A0B0C0D0E0F`, idC `1011121314151617`, idP `18191A1B1C1D1E1F` →
proofP `FDF69520F2244C0AFCAE60E20BDBA787`, proofC `E3318741C40D99C335282359227ED7DB`.

### 13.3 Group logic after the HELLO exchange

Let `mine` and `theirs` be the two groupIds (zero = none).

| mine / theirs | Peripheral (answering HELLO_C) | Central (receiving HELLO_P) |
|---|---|---|
| equal, non-zero | HELLO_P **with proofP** → HELLO_X, await AUTH | verify proofP (absent or wrong → FOREIGN); send AUTH{proofC} → AUTHED |
| both non-zero, different | HELLO_P, ERR AUTH → FOREIGN | ERR AUTH → FOREIGN |
| only mine (I am grouped) | HELLO_P, **JOIN{groupId, groupKey}**, back to LINKED (await a new HELLO) | **JOIN**, then a new HELLO (new nonce) |
| only theirs | HELLO_P → HELLO_X, await JOIN | → HELLO_X, await JOIN |
| both zero | HELLO_P → NOGROUP | → NOGROUP |

**Trust on first use**: an ungrouped node accepts the first JOIN it receives in HELLO_X or NOGROUP,
persists the key, and restarts the handshake (central: new HELLO with a new nonce; peripheral:
LINKED, await HELLO). Any grouped node may JOIN an ungrouped one (the hub can be grouped by the
iPhone or by an already grouped Android).

JOIN acceptance, in order: (1) `groupId` must match the key, else ERR AUTH → FOREIGN; (2) a JOIN for
the group the receiver is already in is ignored; (3) `rekey = 1` is accepted only on an AUTHED
session (else ERR AUTH → FOREIGN); (4) `rekey = 0` is accepted only by an ungrouped receiver in
HELLO_X or NOGROUP (else ERR AUTH → FOREIGN).

**Rekey** ("New sync group" on the iPhone): the node sets the new group, then on every AUTHED
session sends `JOIN{new groupId, new key, flags = 1}` and restarts it. A node that accepts a rekey
does the same on its *other* AUTHED sessions (so the rekey spreads to every linked member), and
gives non-AUTHED sessions `group_changed`. Rule (2) absorbs the copies that arrive on two paths.

**Leaving a group** (button or Diag): the node becomes ungrouped and drops all its links; the next
grouped peer that links hands its key over (TOFU).

**A grouped hub serves members only**: it disconnects a connection that is not AUTHED 10 s after
link-up (or after the hub itself became grouped during that connection). An ungrouped hub behaves as
before for any app. Payloads are authenticated at session start but not encrypted.

## 14. Session state machine

One code shape on all three nodes: a **pure** function of `(state, ctx, input) → (state',
actions)`. No I/O, no clock reads; time is the input's `t` (ms). The `sessions` vectors drive one
session end through scripted inputs and give, per input, the exact action list and the snapshot
after it.

### 14.1 States

| State | Meaning |
|---|---|
| LINKED | transport up, SYNC found, notifications on (central) / CCCD written (peripheral); handshake not done |
| HELLO_X | HELLOs exchanged; waiting for AUTH (peripheral) or JOIN |
| AUTHED | proofs verified (transient: immediately SYNCING or SYNCED) |
| SYNCING | own first pull loop not finished |
| SYNCED | own pull reached `more = 0` once; **sticky** for the session (later pulls do not leave it) |
| FOREIGN | group mismatch / bad proof; disconnect |
| NOGROUP | both ungrouped: transmit only |
| INCOMPATIBLE | PROTO, or 3 HELLO timeouts (central retries in 60 s) |
| CLOSED | link down (terminal; a new link gets a new session) |

"AUTHED+" means AUTHED, SYNCING or SYNCED.

### 14.2 Context (read from the node)

`role` (central / peripheral), own `deviceId kind bootId maxMsg caps version name`, `peerKind`
(central only: known from discovery), `tracksEvents` (iPhone), `isHub`; and the node state
`group (groupId, key | none)`, `dbId`, `feedHigh` (= durableHigh), `clockMs(t)`, `ready` (hub index
built), the next nonce, and the **peer table** `peerDeviceId → {dbId, wm, excludeOk}` (§15.1).

Pull profile at link-up: MTU < 64 → `limit 8, maxBytes 512`; else `24 / 1536`.

### 14.3 Inputs

`link_up{mtu}`, `link_down`, `rx{message bytes}`, `timer{name}` (delivered at its due time; a
timer that was re-armed or cancelled is ignored), `group_changed` (node joined/left a group on
another link or by the user), `rekey` (the node has a new key to spread), `pull_now` (node-level
pull trigger, e.g. the hub's `hubFull` clearing).

### 14.4 Actions

In emission order: `send{type, bytes}` (the session builds HELLO, AUTH, JOIN, PULL and ERR itself),
`state{to}`, `deliver{type, msg}` (hand a message to the node), `commit{wm}` (a page completed: the
node persists the page's data, then `wm`), `group{groupId, key, rekey}` (persist the key),
`node{send_hb | evt_since | foreign}` (the node builds and sends its HB / EVT_SINCEs, or marks the
peer foreign: phones do not auto-reconnect to it), `disconnect{reason, retryMs}`.

### 14.5 Transitions

Timers (one of each name per session): `HELLO` 5 s, `AUTH` 5 s, `DEADLINE` 10 s (grouped hub,
peripheral), `PAGE` 10 s, `LIVE_PULL` 2 s, `HB` 60 s, `RETRY` 60 s, `BACKOFF` retryMs.

**Link**

- `link_up` → LINKED. Central: `startHello` = new nonceC, tries = 1, send HELLO, arm HELLO.
  Peripheral: if `isHub` and grouped, arm DEADLINE.
- `link_down` → CLOSED, cancel all timers.

**Receive** (FOREIGN, CLOSED: everything dropped)

- HELLO pre-check: first TLV `01 01 xx`, xx ≠ 01 → send `ERR{PROTO, refType 1}` → INCOMPATIBLE.
- Decode failure → send `ERR{BAD_MSG, refType}` (not for ERR). Unknown type → ignore.
- PULL, REC, PAGE_END, EVT, EVT_SINCE, EVT_GAP, HB, SUB before AUTHED+ → dropped silently.

**Central receives HELLO** (only in LINKED while HELLO is armed; otherwise ignored): cancel HELLO,
BACKOFF; remember the peer's HELLO; apply §13.3. "→ AUTHED" emits `state HELLO_X`, `send AUTH`, then
the AUTHED entry below.

**Peripheral receives HELLO**:

- same nonce as the HELLO it already answered → re-send the identical reply messages (HELLO_P,
  and JOIN if it sent one) when in LINKED / HELLO_X / NOGROUP; ignore when AUTHED+.
- `ready` false (hub index building) → `ERR{NOT_READY, refType 1, retryMs 500}`, state unchanged.
- otherwise a new handshake (an AUTHED+ session is reset first): nonceP = next nonce, apply §13.3;
  the reply HELLO carries the peripheral's own fields, `subs` for the peer's kind (§16.1) and proofP
  when grouped alike.

**Peripheral receives AUTH** (HELLO_X, grouped alike): proofC correct → cancel AUTH → AUTHED entry;
wrong → FOREIGN. AUTH in any other state is dropped.

**JOIN**: §13.3 acceptance. On accept: `group` action, then **restart**: cancel AUTH, HELLO,
BACKOFF, RETRY and the sync timers; central `startHello`; peripheral → LINKED (and arm DEADLINE if
hub, now grouped, and not armed).

**FOREIGN entry**: send `ERR{AUTH, refType}` unless entered because of a received ERR AUTH; cancel
all timers; `node foreign`; `disconnect foreign`. (The hub's disconnect lands within 1 s.)

**INCOMPATIBLE entry**: cancel all timers except DEADLINE (a grouped hub still drops non-members);
central after HELLO timeouts arms RETRY 60 s → `startHello`.

**AUTHED entry**:

1. `state AUTHED`; cancel AUTH, DEADLINE, HELLO, BACKOFF, RETRY.
2. Resolve the peer (§15.1): if the stored dbId ≠ the peer's HELLO dbId → store it, `wm = 0`,
   `excludeOk = false`.
3. If the peer's caps bit0 (serves feed): send PULL (§15.3) → `state SYNCING`; else `state SYNCED`.
4. If the peer's subs bit2: `node send_hb`, arm HB.
5. iPhone only (`tracksEvents`): if own subs to this peer include events and the peer originates
   events (caps bit1) or is a hub: `node evt_since`.

**In AUTHED+**

| Input | Reaction |
|---|---|
| PULL with dbId ≠ own dbId | send `ERR{DB_CHANGED, refType 2, dbId = own}` |
| PULL | `deliver PULL` (the node serves the page, §15.2) |
| REC | `deliver REC`; reqId 0 → (re)arm LIVE_PULL; reqId = outstanding → count it, re-arm PAGE |
| PAGE_END, reqId ≠ outstanding | ignore (stale) |
| PAGE_END, count ≠ RECs counted | page failed: re-PULL the same since (counts as a try) |
| PAGE_END ok | cancel PAGE; `wm = max(since, scannedTo)`; `commit{wm}`; more = 1 → PULL since wm; more = 0 → done, `state SYNCED` if SYNCING, and if a trigger is pending with feedHigh > wm → PULL |
| HB | `deliver HB`; if **direct** (hops 0 and deviceId = peer): dbId ≠ stored → reset the peer (wm 0, excludeOk false, abandon the current pull) and trigger a pull; else feedHigh > wm → trigger a pull |
| SUB | replace the peer's subs; `deliver SUB` |
| EVT, EVT_SINCE, EVT_GAP | `deliver` |

*Trigger a pull*: if the peer serves a feed: when a pull is outstanding (or BACKOFF armed), remember
the highest triggering feedHigh (∞ for `pull_now`); otherwise send PULL.

**ERR** (any live state; always `deliver ERR` first)

| Code | Reaction |
|---|---|
| AUTH | → FOREIGN (no ERR sent back) |
| PROTO | → INCOMPATIBLE |
| NOT_READY, central in LINKED with HELLO armed | cancel HELLO; arm BACKOFF (retryMs); on fire re-send HELLO with the same nonce, tries = 1 |
| NOT_READY or BUSY with refType PULL, pull outstanding | abandon it; arm BACKOFF; on fire PULL again |
| TOO_BIG, pull outstanding | maxBytes = max(256, maxBytes / 2); PULL again |
| DB_CHANGED with dbId | store it, wm = 0, excludeOk = false, abandon any pull, PULL since 0 |
| others | nothing more |

**Timers**

| Timer | On fire |
|---|---|
| HELLO | tries < 3: tries++, re-send HELLO (same nonce), re-arm; else → INCOMPATIBLE + RETRY |
| RETRY | `startHello` (new nonce) |
| AUTH | `disconnect auth_timeout` |
| DEADLINE | `disconnect auth_deadline` |
| PAGE | tries < 3: re-PULL the same since; else `disconnect page_timeout, retryMs 30000` |
| LIVE_PULL | pull outstanding: re-arm 2 s; else PULL |
| HB | `node send_hb`, re-arm 60 s |
| BACKOFF | as armed (HELLO or PULL) |

**group_changed**: FOREIGN / INCOMPATIBLE / CLOSED: nothing. Now ungrouped → `disconnect
left_group`. NOGROUP (now grouped) → send JOIN, then restart. Otherwise restart.
**rekey**: AUTHED+ → send `JOIN{…, flags 1}`, restart; otherwise as group_changed.

### 14.6 Notes

- A PULL's `reqId` is per session: 1, 2, …, 255, 1, …
- `tries` counts PULLs sent for one page attempt (the first is try 1); a successful PAGE_END resets it.
- The central does not wait for an answer to AUTH; the ordered link guarantees the peripheral sees
  AUTH before the PULL that follows it.
- SYNCED is about the node's own pull only (spec 0.1 item 20); serving the peer does not affect it.

## 15. Pull, paging, watermarks, exclusion

### 15.1 Peer state

Per peer deviceId, persisted by the node (phones in the same atomic write as the ledger; the hub in
NVS after the data is flushed):

| Field | Role |
|---|---|
| `dbId` | the peer's dbId that `wm` refers to |
| `wm` | highest seq of the peer's feed this node has **durably** applied (puller side) |
| `excludeOk` | the peer may be served with exclusion (server side) |

Whenever a peer's dbId is seen to differ from the stored one (HELLO at AUTHED, a direct HB,
ERR DB_CHANGED): `dbId = new`, `wm = 0`, `excludeOk = false`.

**A node whose own dbId changes while sessions are up MUST close all of them** (the hub's
`sync_reset`), so every peer re-handshakes and sees the new dbId in HELLO before any PULL crosses.

### 15.2 Serving a PULL (durable-only)

The server iterates its **current** entries (one per key: on phones the ledger; on the hub, log
entries that the index still points at) with `since < seq ≤ durableHigh`, in ascending seq:

```
recs = []; used = 0; scannedTo = since
exclusion = (pull.exclude == 1) and excludeOk[puller]
if since < durableHigh:
  for e in current entries with since < e.seq <= durableHigh, ascending:
    if exclusion and (e.origin == puller or e.syncFrom == puller):
        scannedTo = e.seq; continue                          # skipped, still scanned
    msg = REC{seq = e.seq, reqId = pull.reqId, body = e.body}
    if len(recs) == limit: break
    if recs not empty and used + len(msg) > maxBytes: break   # the first REC always fits
    recs += msg; used += len(msg); scannedTo = e.seq
more = 1 if scannedTo < durableHigh else 0
send recs..., then PAGE_END{reqId, scannedTo, more, feedHigh = durableHigh, count = len(recs)}
if more == 0: excludeOk[puller] = true      # a complete pass to the puller's current dbId
```

- `durableHigh` = the highest seq already on the node's own disk. Entries above it are never served
  and never reported (spec D5).
- If `since ≥ durableHigh`: an empty page with `scannedTo = since`, `more = 0`.
- The hub may spread one page over several loop passes (scan budget); the content is the same.
- Other messages may be sent between a page's RECs; only RECs with the page's reqId count.

### 15.3 Pulling

- On AUTHED: `PULL{reqId, since = wm, limit, maxBytes, dbId = stored peer dbId, exclude = 1}`.
- For each REC of the page: apply it (§6.2). Rejected records are answered with ERR (§12) and still
  count.
- On PAGE_END with matching count: persist the applied data, **then** `wm = scannedTo` (phones in
  one atomic write; the hub writes wm to NVS only after the records are flushed). `more = 1` → next
  PULL `since = wm`. A count mismatch → re-PULL the same since (frames lost or a REC dropped).
- **Triggers** (§14.5): AUTHED; a direct HB with `feedHigh > wm` (or a new dbId); 2 s after the last
  live REC from that peer (LIVE_PULL); ERR DB_CHANGED; `pull_now`.
- Live RECs never advance `wm`.
- Hub backpressure: the hub sends its next PULL only when its dirty queue has room for maxBytes.

### 15.4 Durability rule for live pushes (exclusion safety)

Exclusion (`origin == puller` or `syncFrom == puller`) is only safe if a node never loses, without
changing its dbId, a record that peers hold *because of it*. Therefore: **a node MAY send a live REC
carrying its feed seq `s` only once `s` is durable, or once it has durably recorded that seqs up to
`s` were issued**, so that a crash which loses `s` is detected at restart as a rollback and the node
takes a new dbId:

- phones: raise `issuedSeq` in the identity file to ≥ `s + 1` before the push (spec §5.2(c) then
  detects `store.nextSyncSeq < issuedSeq`);
- hub: flush `s` first, or persist `liveHigh ≥ s` in NVS (a new dbId at boot when
  `liveHigh > maxSeqInLog`). When flash work is not allowed (a timed job is on air) the hub skips the
  live forward; the HB and pull path deliver the record.

## 16. Live push, forwarding, events routing, heartbeats

### 16.1 Subscriptions

`subs` in HELLO (and SUB) says what the sender wants to receive on that session:

| Sender → receiver | subs |
|---|---|
| iPhone → hub | `0x07` (records, events, heartbeats) |
| iPhone → Android | `0x07` |
| Android → hub | `0x05` (records, heartbeats) |
| Android → iPhone | `0x05` |
| hub → anyone | `0x07` |

The events bit gates **EVT** only; EVT_SINCE and EVT_GAP are control messages routed by `origin` /
`requester` (§16.3) regardless of subs.

### 16.2 Records

seenBy lists are merged as: the existing list in order, then new ids not yet present, truncated to
the first **4** ids.

- **Local change** (user edit, or a newly learned PRESENCE unless more than 4 changes are pending
  within 1 s): send `REC{seq, reqId 0, seenBy, body}` to every AUTHED+ session whose peer subscribes
  to records, with `seenBy = [self] + targets`.
- **First accept of a live REC from P**: `targets` = AUTHED+, records-subscribed sessions whose peer
  ∉ `seenBy ∪ {P, origin}`; send with `seenBy' = merge(seenBy, [self] + targets)` and `seq` = this
  node's new feed seq for the record. DUPLICATE / STALE / rejected: nothing is forwarded.
- Records accepted from **pages** are not forwarded live; the node's HB (feedHigh advanced, ≥ 5 s
  apart) makes peers pull.
- A live REC is never sent back to its sender or to its origin; each version crosses each directed
  link live at most once (spec §3.8, §3.13).

### 16.3 Events

- **Android route** per event (and for replays and EVT_GAP):
  1. the A–I session is AUTHED+ and the iPhone subscribed to events → direct, `seenBy [A, I]`;
  2. else the A–H session is AUTHED+ and the hub's latest **direct** HB is ≤ 90 s old and lists a
     link with `peerKind 3` and the synced flag → to the hub, `seenBy [A, H]`;
  3. else ring only.
- **Hub relay** of an EVT from P: to every AUTHED+, events-subscribed session whose peer ∉
  `seenBy ∪ {P, origin}`, with `seenBy' = merge(seenBy, [self] + targets)`; other fields unchanged.
  The hub keeps no ring and does not dedupe.
- **EVT_SINCE** at the hub → forwarded verbatim to the AUTHED+ session whose peer is `origin` (if
  any, and not the sender). **EVT_GAP** at the hub → verbatim to the session whose peer is
  `requester`. Otherwise dropped (the HB path heals later).
- The iPhone ingests per §8.2–§8.4. Remote events never trigger iPhone auto-responses.
- Pacing (P2/P3): ≤ 20 EVT/s per link; replays rank below live events.

### 16.4 Heartbeats

- Sent on AUTHED (§14.5), every 60 s per session, and on change at most once per 5 s per node
  (to all AUTHED+ heartbeat-subscribed sessions; one HB build, one hbSeq).
- **Direct** = received with `hops = 0` from the described device itself. Only direct HBs drive pull
  triggers, the hub clock and Android's route-2 check.
- **Forwarding**: a direct HB from P is forwarded once, with `hops = 1`, to every other AUTHED+,
  heartbeat-subscribed session whose peer is neither P nor the described device. HBs with
  `hops = 1` are never forwarded. A forwarder changes **only** the hops byte: it copies the received
  message and overwrites the 1-byte value of TLV 0x0F in place (unknown tags survive; `hbHops`
  vectors).
- **Replacement**: a receiver keeps the latest HB per deviceId; a new one replaces it iff `bootId`
  differs or `hbSeq` is greater.
- Path for the UI: DIRECT if a direct HB arrived within 90 s, VIA <forwarder> otherwise, both when
  both are fresh.

## 17. Version negotiation

- `proto = 1` (HELLO 0x01) and frame version `01`. New optional tags need no bump: old receivers
  skip unknown tags and keep tag order. Incompatible changes bump `proto` (and, if the framing
  changes, the frame version).
- A future HELLO MUST keep `01 01 <proto>` as its first TLV, so any version can answer ERR PROTO
  without understanding the rest.
- On ERR PROTO or a HELLO with another proto: INCOMPATIBLE (no sync on that link; transmit still
  works; the UI says "update app/firmware"). A grouped hub still drops the connection at its 10 s
  member deadline.
- v1 nodes ignore unknown message types, unknown flag/caps/subs bits and unknown ERR codes.

## 18. Constants

| Constant | Value |
|---|---|
| proto / frame version / frame header | 1 / `01` / 2 B |
| ATT overhead / chunk | 3 B / MTU − 5 |
| maxMsg: minimum / hub / phones | 512 / 512 / 1024 |
| packet length | 3..29 B, starts `83 01` |
| label / note / kind | 1..64 / 1..160 / 1..16 B |
| body max | 360 B (largest valid 307 B) |
| seenBy max / HB links max / HB evtWm max | 4 / 4 / 4 |
| updatedAt: PRESENCE / legacy Android / legacy iOS / ms floor | 1 / 2 / 3 / 1,500,000,000,000 |
| future bound | 86,400,000 ms (24 h) |
| PULL limit / maxBytes default, small (MTU < 64), minimum | 24 / 1536; 8 / 512; maxBytes ≥ 256 |
| HELLO timeout × tries / INCOMPATIBLE retry | 5 s × 3 / 60 s |
| AUTH timeout / member deadline (grouped hub) | 5 s / 10 s |
| page timeout × tries / retry after page failure | 10 s × 3 / 30 s |
| LIVE_PULL / HB interval / HB change spacing / path freshness | 2 s / 60 s / 5 s / 90 s |
| NOT_READY retry / BUSY retry / default retryMs | 500 ms / 1000 ms / 1000 ms |
| event window / epochs kept / Android ring / repeated-request window | 64 bits / 2 / 2,000 / 5 s |
| tombstone cap (phones) | 5,000 |
| caps: hub / Android / iPhone | 0x0039 / 0x003B / 0x0001 |
| FNV-1a 64 offset / prime | `CBF29CE484222325` / `00000100000001B3` |
| prefixes | `MMGROUP1`, `MMSYNC1P`, `MMSYNC1C` |

## 19. Decisions made in P1

Each item resolves an ambiguity, gap or contradiction in SYNC_HUB_SPEC.md.

1. **Message tag order is strict.** Tags in a message are non-decreasing; a repeat is allowed only
   for repeatable or unknown tags. (Spec: "unknown tags are skipped" only.) Keeps the decoders
   single-pass and the vectors unambiguous; unknown tags still skip.
2. **Canonical message encoding** omits optional fields equal to their default; decoders accept
   explicit defaults. Defaults: caps 0, limit 24, maxBytes 1536, exclude 0, EVT count 1, EVT flags 0,
   HB battPct/battMv/charging/runtimeMin −1, HB state 0, JOIN flags 0.
3. **Mandatory/optional sets** where the spec gave none: REC reqId is mandatory; HB hops, feedHigh,
   dbId, records, ts, uptimeS, hbSeq are mandatory; ERR refType, key, detail, dbId, retryMs optional.
4. **Ranges are enforced** (BAD_MSG): HELLO kind 1..3, maxMsg ≥ 512, clockMs ≥ 0; PULL reqId 1..255,
   limit 1..32, maxBytes 256..1536, exclude 0/1; PAGE_END more 0/1; EVT epoch/seq ≥ 1, count ≥ 1,
   lat/lon bounds, fix all-or-none; HB battPct −1..100, charging −1..1, runtimeMin −1..5999, hops 0/1,
   link peerKind 1..3; JOIN groupId non-zero; strings 1..max bytes and valid UTF-8. Unknown bits in
   subs/caps/flags are ignored.
5. **REC body/envelope split.** Tags 0x10..0x1F of a REC form the body (validated per §4); an
   invalid body does not invalidate the envelope, so one bad record cannot break a page's count (it
   gets ERR with the key). seenBy on a page REC is BAD_MSG.
6. **Packet prefix.** Every packet (key, EVT) must start `83 01` (the spec said "starting `83 01`"
   descriptively).
7. **Class matrix** (§4.4) made exact: origin present ⇔ not PRESENCE; USER requires label, category
   and place (kind, note optional); RESET allows only note; NEWWAND names require label and allow a
   note; deletes carry nothing; legacy stamps 2/3 only for USER and NEWWAND names; check order
   structural → `updatedAt ≤ 0` → fields → time, so a malformed record with a bad time is BAD_MSG.
8. **Local stamps are floored at 1.5e12** (§5.2) so a phone with a broken clock still emits valid
   records.
9. **Text normalisation** (§5.3) is defined on the Unicode White_Space set and code points, trims
   again after truncation, and kind maps non-printable-ASCII to `?`.
10. **Tombstone cap eviction** removes the smallest version (ties: key bytes) and counts DELETED in
    both namespaces.
11. **Subscriptions table corrected.** The spec's table gave I→H `0x05` and H→anyone `0x05` (no
    events), which contradicts route 2 (A→H→I). v1: I→H `0x07`, I→A `0x07`, A→H `0x05`, A→I `0x05`,
    H→* `0x07`; the events bit gates EVT only, never EVT_SINCE/EVT_GAP.
12. **Event routes need AUTHED+, not SYNCED.** With "SYNCED" an EVT_SINCE that arrives right after
    AUTHED (before Android's own pull finishes) had no route and was lost. Route 1 needs the A–I
    session AUTHED+; route 2 needs A–H AUTHED+ plus the hub's direct HB synced flag.
13. **No history on first contact.** An iPhone that has never seen an origin starts its window at the
    first event it receives (`hc = seq − 1`); a new epoch of a known origin starts at `hc = 0`.
14. **Catch-up details**: EVT_SINCE targets the newest window only; identical requests are not
    repeated (iPhone) and identical catch-ups within 5 s are skipped (Android); the replay plan and
    EVT_GAP handling of §8.4–§8.5 are new, exact algorithms.
15. **Frame counters**: both the 4-bit message counter and the 8-bit frame seq start at 0 at link-up
    and are per direction. A frame-seq gap is counted even between messages. Frames with another
    version never move `expected`. Only reassembly drops count BAD_FRAME; sending ERR BAD_FRAME is
    optional and rate-limited.
16. **maxMsg**: hub 512, phones 1024, minimum 512; every v1 message is ≤ 512 B, so TOO_BIG only
    signals a bug.
17. **maxBytes** is the budget of a page's encoded REC messages; the first REC always fits; the
    limit check happens before the size check; skipped (excluded) entries still advance scannedTo.
18. **SYNCED is sticky** for the session; re-pulls do not drop back to SYNCING (event routing and
    HB flags would otherwise flicker).
19. **Pull triggers coalesce**: a trigger during an outstanding pull is remembered (highest
    feedHigh) and served after `more = 0` only if still ahead of wm; LIVE_PULL during a pull is
    re-armed.
20. **A dbId change closes all sessions**, and the puller always sends `exclude = 1`. Without the
    first rule a hub `sync_reset` let phones exclude, with stale `excludeOk`, records the hub had lost.
21. **Durability rule for live pushes** (§15.4): issuedSeq (phones) / flush or `liveHigh` (hub)
    before a live REC leaves, so exclusion never hides a record its sender lost.
22. **JOIN acceptance order** (§13.3): a JOIN for the group the receiver is already in is ignored
    first, so a rekey reaching a node on two paths cannot make it FOREIGN. A JOIN whose key does not
    hash to its groupId is FOREIGN. Rekeys spread to all AUTHED members.
23. **Timeouts made exact**: AUTH timeout → disconnect (not FOREIGN); HELLO retries reuse the nonce;
    duplicate HELLOs (same nonce) get the identical reply; NOT_READY backs off without using a HELLO
    try; page failure = PAGE timeout or count mismatch, 3 tries, then disconnect with retry 30 s;
    INCOMPATIBLE keeps the hub's 10 s member DEADLINE.
24. **ERR AUTH on mismatch is sent by both sides** (each detects it); FOREIGN always disconnects
    (phones also stop auto-reconnecting to that peer).
25. **HB forwarding patches the hops byte in place**; only hops-0 HBs from the described device are
    "direct"; HB `link` flags: synced = session SYNCED, tx-ready = peer caps bit3.
26. **EVT_SINCE / EVT_GAP relay** at the hub is by `origin` / `requester`, verbatim.
27. **JSON numbers** in vectors stay within ±(2⁵³ − 1) so every platform's JSON parser reads them
    exactly; 64-bit bitmaps and hashes are hex strings.

## 20. Conformance

An implementation conforms when, for every entry of `tools/sync/vectors.json` (schema in
`tools/sync/README.md`), it produces the expected bytes, results and action lists, and it decodes and
re-encodes every message of every transcript in `tools/sync/transcripts/` byte for byte (P1). From P2
on, the C++ simulation and the Kotlin and Swift session tests replay the transcripts against fake
transports and must emit the same messages. CI runs `python3 tools/sync/gen_vectors.py --check` to
keep the committed files current.
