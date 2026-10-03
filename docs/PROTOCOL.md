# The Disney BLE Effect Protocol

What we know, how we know it, and what is still guesswork.

Everything marked **Proven** was validated against a real park capture: 45,446
advertisements recorded on a phone running this app, across two sessions. Everything
marked **Inferred** is a reasonable reading of that data that we have not confirmed.
Everything marked **Unknown** is called out so nobody mistakes a guess for a fact.

---

## 1. Transport

**Proven.**

These are *connectionless BLE advertisements*. Nothing pairs, nothing connects, nothing
acknowledges. A transmitter broadcasts a packet into the air and every receiver in range
decides for itself whether to react. That is the whole model — it is why replay works at
all, and why there is no handshake to defeat.

A BLE advertisement is a sequence of AD structures, each one:

```
[length:1][type:1][data:length-1]
```

The payload we care about rides in AD type `0xFF` — *Manufacturer Specific Data*. The
first two bytes of that data are a company ID assigned by the Bluetooth SIG, transmitted
little-endian. Disney's is **`0x0183`**, which goes out on air as the bytes `83 01`.

So every hex string in this repo that starts `8301` is already *inside* the manufacturer
data field. The `8301` is not part of Disney's own protocol — it is the envelope the
Bluetooth spec requires, and it is how a receiver knows the rest of the bytes are Disney's
to define.

### 1.1 Why the iPhone cannot transmit these

**Proven** (by API behaviour, not by capture).

Apple's `CBPeripheralManager.startAdvertising()` honours exactly two keys:

- `CBAdvertisementDataLocalNameKey`
- `CBAdvertisementDataServiceUUIDsKey`

`CBAdvertisementDataManufacturerDataKey` is **silently ignored**. Not rejected, not
an error — iOS simply builds the advertisement without it. There is no entitlement, no
private-API-free workaround, and no way to smuggle the bytes through the two keys that do
work: the service-UUID field is AD type `0x02`/`0x07` and the local-name field is `0x08`/
`0x09`. A receiver looking for AD type `0xFF` will never see them, no matter what bytes
you stuff inside.

This is an OS *policy* decision, not a Bluetooth limitation. Android's
`BluetoothLeAdvertiser` with `AdvertiseData.addManufacturerData()` is an ordinary public
API that does exactly this. Hence the architecture: **Android broadcasts natively; iOS
relays over GATT to an Android phone or an ESP32, which broadcasts on its behalf.**

Worth being precise about one thing, because it comes up: Disney *does* use iPhones in
the parks. But the iPhone there is talking to park infrastructure over a connection — the
GATT read/write channel, which iOS allows freely — and the *infrastructure* does the
broadcasting. The iPhone is a remote control, not a transmitter. That is the same split
this app uses.

---

## 2. Framing: it is TLV

**Proven. This is the central finding.**

After the `8301` company ID, the payload is a chain of **type-length-value** records:

```
8301 | <type:1><length:1><value:length> | <type:1><length:1><value:length> | ...
```

`length` counts the value bytes only — it excludes the type and length bytes themselves.
Records run back to back until the advertisement ends. A record may have **length 0**, in
which case it is a bare marker with no payload.

Two independent checks, both clean:

- **32 of 32** distinct real packets drawn from the park capture parse exactly.
- **11 of 11** packets the app itself can transmit parse exactly — every `PacketBuilder`
  output, the ping, both park-captured show blocks, and the New Wand code.

Every chain consumes its payload with no leftover bytes and no overrun. That is not
something a wrong framing hypothesis does.

The second check is reproducible right now: `tools/tlv_validate.py` parses the built-ins
and exits non-zero if any fail. Point it at a capture CSV to re-run the first:

```
tools/tlv_validate.py                  # the app's own transmit packets
tools/tlv_validate.py capture.csv      # every distinct 8301... packet in a capture
tools/tlv_validate.py --hex 8301E100E905006F0EF5B0
```

### 2.1 Worked examples

A single-colour effect:

```
8301 E1 00        -> type E1, length 0, no value
     E9 05        -> type E9, length 5
        00 6F 0E F5 B0
```
Total after `8301`: 2 + 2 + 5 = 9 bytes. The packet is 9 bytes. Exact.

The app's "vibrate" packet — three records chained:

```
8301 CC 03        -> 00 01 00
     E1 00        -> (marker)
     E9 0C        -> 00 0F 0F 5D 46 5B F0 05 32 37 48 B0   (12 bytes)
```

A New Wand broadcast:

```
8301 CF 0B        -> 00 C0 20 22 4E AC 78 07 86 6F 1D      (11 bytes)
```

A beacon with a chain of three:

```
8301 E4 09 [...] | E5 01 [04] | EF 05 [...]
```

### 2.2 What this means for our classifier

The existing code finds effects with the regex `E[0-9A-F]00E9`. Now that the framing is
known, it is clear *why* that works — and it is an accident:

```
E1    00    E9
^type ^len  ^next record's type
```

The regex is doing TLV parsing by coincidence. It matches "a channel marker with zero
length, immediately followed by an E9 record." That is correct for the common case, but
it is a substring search over the whole packet, so it will also fire on those same three
bytes appearing *inside* some other record's value. That is the root of both the false
positives and the misses (`E914` was being dropped) we have been chasing.

**A real TLV walker replaces every substring heuristic in `MagicClassifier`, and is both
faster and correct.** It is the single highest-value change still outstanding.

### 2.3 An inconsistency in our own packets

**Observed, significance unknown.**

Running the validator over the built-ins turns up a split that does not follow function:

| Built-in | Channel marker |
|---|---|
| Crossfade R/B, Lightning, Vibrate (rainbow FX) | has `E1 00` |
| all single colours, Dual, 5-LED Rainbow, Circle, Ping | none |

The split follows *origin*. The three that carry a marker are park-captured. The rest are
ported from the `esp32_magicband` project, which builds `8301 E9 05 …` directly with no
channel record.

What makes this worth noting: **every effect packet in the park capture carries a channel
marker.** Not one of the 55 omits it.

That is a plausible reason some effects do not fire, and it would apply to six presets at
once. It is *not* established — those presets may be entirely correct for addressing a
MagicBand directly, which is a different target from park show control, and we have no
evidence either way. Do not "fix" them on this basis.

It is cheap to settle in the field: send Circle, then send Circle with `E100` spliced in
after the `8301`. If the second works and the first does not, that is the answer.

---

## 3. Record type catalogue

Observed frequencies across the 45,446-packet capture. "Addresses" is the number of
distinct BLE source addresses that sent that family — a high address count means many
independent devices, i.e. guest hardware rather than fixed infrastructure.

| Head | Type | Len | Packets | Addrs | What it is |
|---|---|---|---|---|---|
| `8301C013` | `C0` | 19 | 20,173 | 941 | MagicBand telemetry — **Inferred** |
| `8301C00F` | `C0` | 15 | 17,060 | 699 | MagicBand telemetry, shorter variant — **Inferred** |
| `8301CC03` | `CC` | 3 | 3,942 | 78 | Interaction ping / wake — **Proven** (4 distinct values only) |
| `83010F11` | `0F` | 17 | 2,182 | 333 | Rolling per-device ID — **Inferred** |
| `8301E409` | `E4` | 9 | 965 | 16 | Beacon, usually chained with `E5`/`EF` — **Inferred** |
| `8301EA0C` | `EA` | 12 | 367 | 11 | Infrastructure — **Unknown** |
| `8301EF08` | `EF` | 8 | 173 | 6 | Infrastructure — **Unknown** |
| `8301EF05` | `EF` | 5 | 169 | 6 | Infrastructure — **Unknown** |
| `8301E100` | `E1` | 0 | 44 | 8 | **Effect, channel 1** — **Proven** |
| `8301E200` | `E2` | 0 | 10 | 3 | **Effect, channel 2** — **Proven** |
| `8301E300` | `E3` | 0 | 1 | 1 | **Effect, channel 3** — **Proven** |
| `8301CF0B` | `CF` | 11 | — | — | New Wand broadcast — **Proven** |

### 3.1 The headline number

**Effect packets are 55 out of 45,446 — about 0.12% of the traffic.**

Over 91% is `C0` and `0F` family telemetry from guest MagicBands, each broadcasting
continuously with a rolling payload from a rotating private address. This is the entire
explanation for the "too many unknown packets" report: the app was scanning correctly, but
the signal is genuinely four thousand times rarer than the noise.

It also explains the Starlight-list pollution. Hundreds of distinct source addresses, each
emitting a payload that differs only in a serial field, will look like hundreds of distinct
"packets" to any classifier that keys on the full hex.

**Filter aggressively on the head byte.** `C0` and `0F` are never effects.

---

## 4. The effect record (`E9`)

**Proven** framing; **Inferred** semantics.

Effects are a two-record chain: a zero-length **channel marker** (`E1`, `E2`, or `E3`),
then an `E9` record carrying the effect itself.

```
<E1|E2|E3> 00  <E9> <len> <value...>
```

The value's first byte is `00` in every sample we have. Byte 2 varies and looks like a
sub-opcode. Beyond that the structure is effect-specific and we have not decoded it.

What `E1`/`E2`/`E3` select is **Unknown**. "Channel" is our word for it. It could be a
zone, a device class, a priority, or a group address. `E1` dominates the capture; `E3` was
seen exactly once.

### 4.1 Every distinct effect packet in the capture

Nine, in full:

```
8301E100E905006F0EF5B0
8301E100E90900050FADADB1ADB1B0
8301E100E90E00B7D255000000D25800000078B0
8301E100E9110001D255640000D037F0D13D0204B27A01
8301E100E9110003240F55515BF00F10374894D13D0508
8301E100E91400030F5D5458F44882D0650AD1460228307B00B0
8301E200E909007D0FA2B1B1B1B1B0
8301E200E90E00120FBBBBBBBBBB59190248AEB0
8301E300E9110001D255640000D037F0D13D0204B27A01
```

Note the last one: byte-identical to an `E1` packet except for the channel marker. Strong
support for the channel reading.

### 4.2 Known `E9` lengths

| Len | Our name | Confidence |
|---|---|---|
| `05` | Single colour | **Inferred** — colour byte extraction works in practice |
| `06` | Dual colour | **Inferred** |
| `09` | Show control | **Unknown** semantics |
| `0C` | Animation (complex) | **Inferred** |
| `0E` | Show control | **Unknown** semantics |
| `0F` | Alternating strobe | **Inferred** |
| `11` | Palette cross-fade / Pirate Cannon | **Inferred** |
| `14` | Show control | **Unknown** — this is the `E914` the old classifier dropped |

What the code calls a "function code" (`E905`, `E90C`, `E911`…) is **not an opcode**. It is
the record type `E9` concatenated with its *length*. Different lengths mean different
payload shapes, which correlates with different effects — so treating it as an opcode
mostly works — but naming it that way has been actively misleading us.

### 4.3 The `B0` trailing-byte trap

**Proven false.** Several effect payloads end in `B0`, and the classifier uses
"ends with `B0` → the colour byte is at offset −4" to pull colours out. But two of the nine
real packets above end in `01`, not `B0`. `B0` is ordinary payload data, not a terminator.
Any logic keyed on it is guessing, and will silently produce a wrong colour on packets that
do not happen to end that way.

---

## 5. The New Wand record (`CF`)

**Proven** framing.

```
8301 CF 0B 00 C0 20 22 4E AC 78 07 86 6F 1D
           ^^                         ^^ ^^
           always 00                  the part that varies
```

The first nine value bytes are stable across every New Wand packet we have. The last two
vary, and the final byte matches the colour index space used elsewhere — `0x1D` is "Off",
which is why `…6F1D` is the default for the OFF button on both wand screens.

The bytes in between look like a per-wand serial. That is why the same logical command from
different wands produces many near-identical entries, and why the app needs to dedupe on the
tail rather than the whole hex.

### 5.1 An honest caveat about `CF9B`

The code also matches `CF9B` as a Starlight marker. Under TLV that reads as type `0xCF`,
**length 0x9B = 155 bytes** — impossible in a 31-byte legacy advertisement.

So either `CF9B` is a different framing, or it is a transcription error that has been
carried forward in the codebase. **There is not a single Starlight packet in the capture**,
so we cannot resolve it from data we have.

Running the app's own legacy Starlight template through the parser sharpened this
considerably. That template is `8301 CF9B 00 <9-byte serial> <colour>`: marker, then **exactly
11 value bytes**. Eleven is `0x0B`. In other words the only thing wrong with the template under
TLV is the single nibble that turns `0B` into `9B` — and the New Wand, which *is* known to work,
uses `CF0B` with the same 11-byte layout.

The most economical explanation is that `CF9B` is a transcription error carried forward in the
code, and the Starlight wand and the New Wand are the same record type. **Still inferred, not
proven** — transmit behaviour has deliberately not been changed on this basis.

**This is the one open question worth a field test:** capture a real Starlight wand and we
will know in one packet whether `CF9B` is real.

---

## 6. Timing

**Proven** by configuration, not by measurement against park hardware.

Replay is not fire-and-forget. The receiver has to see the advertisement, so the
transmitter repeats it for a window:

| Parameter | Value | Where |
|---|---|---|
| Wake prelude | 520 ms | ESP32 `WAKE_MS` |
| Default command duration | 4000 ms | ESP32 `DEFAULT_CMD_MS` |
| Duration clamp | 300–12000 ms | ESP32 |
| Advertising interval, active | 20–30 ms | ESP32 `BEACON_ADV` |
| Advertising interval, idle | 200–400 ms | ESP32 `IDLE_ADV` |
| Inter-packet recovery | 150 ms | Android |

Newest-wins: a new command preempts one in flight rather than queueing behind it.

---

## 6a. What other implementations say

Two independent, public re-implementations of this protocol were read in full (source, not
summaries). Both cite the same primary research — EMCOT's MagicBand+ page
(`emcot.world/Disney_MagicBand+_Bluetooth_Codes`, mirrored at `em-cot.github.io`). Where the two
agree with each other and with our capture, confidence is high. Where they disagree, that is
recorded here rather than resolved by guessing.

| Source | What it is |
|---|---|
| [Haw8411/magic-band-plus-lights](https://github.com/Haw8411/magic-band-plus-lights) | Flipper Zero app. `protocols/magicband.c` carries **36 named payloads** verbatim and builders for E905/E906/E908/E909. |
| [Shoopity/esp32_magicband_broadcaster-and-listener](https://github.com/Shoopity/esp32_magicband_broadcaster-and-listener) | ESP32 **listener** that decodes real packets onto a 5-zone LED model — the closest thing to band firmware anyone has published. |
| [xxfunprojectsxx/esp32_magicband](https://github.com/xxfunprojectsxx/esp32_magicband) | The original broadcaster this app's `PacketBuilder` was ported from. |
| [abramsimon/magicband-controller](https://github.com/abramsimon/magicband-controller) | ESP32-S3 broadcaster; same five shapes. |

**No MagicBand+ firmware dump or decompiled command handler is public.** The band uses a
Nordic BLE SoC (the original MagicBand teardown by Adafruit found an nRF24LE1; the + is a newer
part). Its FCC filing is **2AYEL-7282**, filed through a shell company, Pietersite Unakite LLC;
the internal-photo exhibit is public on fccid.io and shows the board. Everything below is
therefore *observed behaviour reproduced by others*, not Disney's code.

### The hardware

**Five LEDs: one at each corner of the square face and one in the centre.** Both
implementations model exactly this, and it is what the protocol's shapes are built around:
"dual" is centre vs corners, the 5-colour command is one colour per LED.

Zone numbering used by the listener, which this app now follows:

```
 Z2 ──────── Z4         Z1 bottom-left   Z4 top-right
 │     Z3     │          Z2 top-left      Z5 bottom-right
 Z1 ──────── Z5          Z3 centre
```

### The E9 body, decoded further

For an effect record `E9 <len> <body>`, body byte offsets (0-based):

| Byte | Meaning | Confidence |
|---|---|---|
| `[0]` | Sub-code, `00` in every effect seen | **Proven** (capture) |
| `[1]` | **Timing.** bits 0–3 duration count; bit 6 selects ×3.1 s (else ×1.5 s); bits 4–5 fade-out seconds; bit 7 always-on. Our `2E` = 14 × 1.5 = **21 s, 2 s fade**. `8F` = always on. | **Inferred** — both implementations agree; matches Flipper's named presets (`09` ≈ 20 s, `06` ≈ 10 s, `04` ≈ 5 s, `03` ≈ 3 s) |
| `[2]` | Flags, usually `0E`/`0F` | **Unknown** |
| `[3..]` | Effect-specific; colour bytes are `flag:3 \| palette:5` | **Proven** for the colour bits |
| last | Tail, `B0`-ish | **Disputed** — see below |

### Per-shape decode (what the listener does with each length)

| Len | Shape | Colour bytes | LED mapping |
|---|---|---|---|
| `05` | Single | `[3]` low 5 bits | **High 3 bits of `[3]` are a zone mask.** Both agree `0`=all, `3`=bottom-left, `4`=top-left. They *disagree* on `1`/`2` (Flipper: TR/BR; listener: centre/TR). Our `E0` = mask 7 = all. |
| `06` | Dual | `[3]`, `[4]` | `[3]` → **centre**, `[4]` → **four corners** (both agree) |
| `08` | **Custom RGB** | `[3..5]` = R, G, B as 6-bit values `<<1` | Flipper builds `E9 08 00 0E D2 55 r g b tail`. We have never used this. |
| `09` | 5-LED | `[3..7]`, one per LED | **Disputed.** Listener: Z1..Z5 = BL, TL, C, TR, BR. Flipper: C, TR, BR, BL, TL. |
| `0B` | Circle | none — both treat the body as fixed | "Green double comet" chasing round the corners. Neither decoder reads colours from it; our editable P1–P7 slots are an experiment, not a documented feature. |
| `0C` | Animations | signature at `[3..5]` | `5D 46 5B` → fade (tail `95`) or rainbow; `4F 4F 5B` → strobe; `B1 B9 B5` → stepper |
| `0E` | Twinkle / flash | `[3..7]`, one per zone | Pattern `[marker, A, B, A, B]` = two-colour alternation |
| `0F` | Candles / pulse | — | matched by signature |
| `10` | Alternating | — | matched by signature |
| `11` | Cross-fade / pulse burst | `[3]`, `[4]` | `F4 48 82` present → smooth two-colour fade (centre out of phase); else pulse burst with `[3]` centre, `[4]` corners. |
| `12` | **Rotating colours** | `[3..7]` in zone order **Z2, Z3, Z4, Z5, Z1** | `[2]` = `0F` → colour rotate; else two-colour toggle. **This is the best candidate for Figment's rotating two-colour effect** — not `0B`. |
| `13` | Zone alternate | `[3]` centre, `[4]` group B, `[5]` group A | Z1/Z4 vs Z2/Z5 alternate at 1 s |
| `14` | Repeat fade | colour at `[8]` when `[7]` is `05`/`02` | all five, 1.25 s cycle |

### The tail byte is disputed

Three readings exist for the last body byte:

- `esp32_magicband` (and this app): `B0 | vibration(0–15)` — low nibble is the pattern.
- Flipper: `vibration << 4 | 0x0B` — **high** nibble is the pattern, low nibble `B` means "enable". Its vibe table: `B` pulse 1 s, `A` short 0.5 s, `7` long 2 s, `5` fast, `6` complex, `8` rapid.
- The capture: real effects end `B0`, `B5`, `95`, `B8`, `BB`, `B3` — and also `01`, which fits neither.

Treat the buzz nibble shown in the Lab as a guess until a band confirms it.

### Pings carry a channel marker too

Every ping in the Flipper list is `E1 00 CC 03 xx xx xx` — channel marker *before* the CC
record. Our capture saw `CC 03` with and without it. The `CC 03 13 20 00` variant is named
"RRC" there; we have not seen it.

### Reconciling with the earlier sections

- The "function code is really type + length" finding stands; both implementations switch on
  the length byte as the sub-action.
- The channel marker (`E1`/`E2`) is present on every payload in both lists, including pings.
  `E2` appears on some crossfades and all the `E907` unknowns.
- `E907` exists (two variants, 7-byte body, `43 43 41` / `44 44 41`), purpose unknown.

## 7. What to do with this

In priority order:

1. **Replace the substring heuristics in `MagicClassifier` with a real TLV walker.** Done on
   Android — `core/DisneyTlv.kt`. Verified against the old classifier over a 71-packet corpus:
   every difference was one of the fixes predicted here. iOS still runs the substring version.
2. **Filter on the head record type, not on substrings.** `C0` and `0F` are 91% of traffic
   and are never effects.
3. **Dedupe `CF` packets on the tail**, not the full hex — the serial field is noise.
4. **Stop trusting the trailing `B0`** for colour extraction.
5. **Capture a Starlight wand** and settle `CF9B`.

## 8. What we still do not know

- What `E1`/`E2`/`E3` actually select.
- The internal structure of any `E9` payload beyond the leading `00`.
- Whether `CF9B` is valid framing at all.
- What `EA`, `EF`, `E4`, and `E5` do. They come from very few addresses, so they are fixed
  infrastructure rather than guest hardware, but that is as far as the data goes.
- Whether there is any authentication, sequence number, or replay protection. We have seen
  none — replay works — but absence of evidence over one capture is not proof.
