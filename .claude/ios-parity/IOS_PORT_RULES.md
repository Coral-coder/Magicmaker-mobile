# iOS parity port — rules every agent follows

Repo: `/home/user/Magicmaker-mobile` (branch `main`). The iOS app (`ios/MagicMaker/`) is being brought to
feature parity with the Android app (`android/app/src/main/java/com/magicmaker/android/`). An iPhone cannot
broadcast these BLE packets, so sending goes through a "relay" (an Android phone or an ESP32); everything
else must work on the iPhone by itself.

The Android Kotlin code is the specification. When in doubt, do what the Kotlin does, byte for byte and
string for string (labels, notes, captions, sort orders, defaults). Do not "improve" behaviour.

The gap analysis for every area is in
`/tmp/claude-0/-home-user-Magicmaker-mobile/8956e220-2c18-5594-88a6-966886e08e67/scratchpad/parity_map.json`
(a JSON array; each element has `area`, `summary`, `gaps[]`, `logicDrift[]`, `notes`). Read the entries for
your area. Treat it as a guide; the Kotlin source is the authority.

## There is NO Swift compiler on this machine

Your Swift is first compiled in CI, minutes later, by someone else. So:

- Write plain, conservative Swift 5.9 for iOS 17 (Xcode 26 toolchain). No macros, no experimental features.
- Give explicit types wherever inference is not trivial: empty literals (`let xs: [String] = []`), numeric
  mixes (`Int` vs `Int64` vs `Double` vs `UInt8` never mix implicitly — convert explicitly), closures that
  return different types on different branches, dictionary literals with mixed values.
- Keep expressions short. Long chains of `+`, `??`, ternaries or `.map{}.filter{}` in ONE statement cause
  "the compiler is unable to type-check this expression in reasonable time". Split into `let` steps. In
  SwiftUI, keep each `var body`/`@ViewBuilder` small: move sections into separate computed properties or
  small `private struct` views. No more than ~10 direct children in one container.
- No Java-style escapes. `"·"` does NOT compile in Swift. Use the literal character (`·`, `—`, `→`,
  `×`, `≈`) or `"\u{00B7}"`.
- `String(format:)` arguments must be CVarArg of the matching kind: `%d` with `Int`, `%02X` with `Int`
  (convert `UInt8` with `Int(x)`), `%@` with `String as NSString`/`String` (works on Apple platforms, but in
  `Core/` prefer string interpolation — `Core/` is also compiled on Linux).
- `switch` must be exhaustive. Any `switch` over an enum you add a case to must be updated everywhere
  (grep the whole `ios/MagicMaker` tree).
- Never crash on data: no `precondition`, `fatalError`, `try!`, force unwrap `!`, or unchecked array
  index on anything derived from a packet, a file, user input or the network. Bounds-check first.
- Kotlin `Long` → Swift `Int64`, `Int` → `Int`, `Float` → `Float` only where rounding parity matters,
  otherwise `Double`. Kotlin `Byte` is signed: `b.toInt() and 0xFF` → `Int(byte)` on a `UInt8`.
- Kotlin `String.format("%.1f")` rounds HALF-UP on the shortest decimal form; C's `%.1f` rounds half-even
  on the binary value. Where a caption prints a rounded float, mirror `DisneyTlv.roundHalfUp` style.
- Kotlin string functions have different edge behaviour: `substring(a, b)` throws when out of range (guard
  the same way the Kotlin does), `take(n)` clamps, `chunked(2)` keeps a short last chunk, `indexOf` returns
  -1. Swift `String` has no integer subscripts — convert to `Array(string)` (of `Character`) or use
  `prefix`/`suffix`/`dropFirst`. Be careful and explicit.
- Struct memberwise initialisers: if you add a stored property to a type that is constructed elsewhere, add
  an explicit `init` with default values so EVERY existing call site keeps compiling, and grep
  `ios/MagicMaker` for call sites to be sure.
- `Codable` types that are persisted must decode tolerantly: `init(from:)` using `decodeIfPresent` with
  defaults for every non-essential key, so an older file or an Android-written file still loads.
- A file in `ios/MagicMaker/Core/` must import only `Foundation` (it is also compiled with `swiftc` on a
  Linux CI runner for the parity check). No SwiftUI, UIKit, Combine, CoreBluetooth, CoreLocation,
  `@MainActor`, `ObservableObject`, `DispatchQueue.main` there. Guard anything Apple-only with
  `#if canImport(...)`.
- Match the surrounding code's style and comment density. Comments explain why, briefly. Do not write
  comments that refer to "the port", "parity", agents, or this document, beyond a one-line
  "Port of Android `core/X.kt`" header where useful.

## Working rules

- Edit ONLY the files assigned to you. If you must touch another file to keep it compiling (a call site of
  an API you changed), make the smallest possible edit and list it in your report.
- Keep every existing public Swift name and signature unless your task says to change it; add new API next
  to it. Other screens call these.
- New API mirrors the Kotlin name in lowerCamelCase, with the first argument unlabelled where the existing
  Swift file does that (e.g. `MagicClassifier.classify(_ hexRaw: String)`), so other agents can predict it.
- Do NOT run `git commit`, `git push`, `git checkout`, `git stash` or anything that changes git state. Do
  NOT edit `ios/MagicMaker.xcodeproj/project.pbxproj` (new files are registered by the lead afterwards) —
  just report every file you created.
- Do not create documentation files. Do not touch Android code unless your task says so.
- When you finish, re-read every file you changed top to bottom as if you were the Swift compiler: check
  every brace, every label, every optional, every type. Count braces with a script if the file is long:
  `python3 -c "s=open(P).read();print(s.count('{')-s.count('}'),s.count('(')-s.count(')'),s.count('[')-s.count(']'))"`.
- Report back: files created, files changed, every public API you added or changed (exact Swift
  signatures), anything you deliberately left out and why, and anything you are unsure will compile.

## Already in place (written by the lead — read them, do not rewrite them)

- `ios/MagicMaker/Core/DisneyTlv.swift` — port of `core/DisneyTlv.kt`: `DisneyTlv.parse(_:) -> Parsed?`,
  `Record` (`type`, `value: [UInt8]`, `declaredLength`, `legacyStarlight`, `length`, `truncated`,
  `typeHex()`, `lengthHex()`, `valueHex()`, `headHex()`, `isChannelMarker()`, `byte(_:) -> Int?`),
  `Parsed` (`hex`, `records`, `malformed`, `exact`, `first(_:)`, `has(_:)`, `effect`, `channel`),
  `anatomy(_:) -> [Segment]`, `SegmentKind`, `timingCaption(_:)`, `pingName(_:)`, `effectName(_:)`,
  `colorSlotCount(_:)`, `hex2(_:)`, `roundHalfUp(_:)`, type constants `typePing`, `typeWand`,
  `typeEffect`, `typeChannel1...3`, `typeBandTelemetry`, `typeBandId`, `legacyStarlightLength`.
- `ios/MagicMaker/Core/StarlightColors.swift` — `StarlightColors.palette`, `nameFor(_:)`,
  `broadcastHex(_:serial:)`, `entries(serial:)`.
- `HexUtils.hexToBytes` already tolerates an odd trailing nibble (drops it) like Kotlin.

## Status (updated by the lead)

- Phase A is done and verified in CI: the whole app target compiles with the ported Core, and
  `ios/ParityCheck` (run on Linux by `.github/workflows/ios-core-parity.yml`) confirms the Swift Core returns
  what the Android core returns for 868 packets. Do not change Core behaviour unless your task says so; if
  you add a file to `Core/`, tell the lead (it must be added to that workflow's `swiftc` file list).
- Do NOT download, install or run compilers or toolchains (a Linux Swift toolchain left under the
  scratchpad by an earlier step must not be used — running it is not permitted here). Check by reading.
- Facts about the ported Core that differ from what you might guess from the Kotlin:
  `PacketBuilder.rainbowFinale` is a `static let`, not a function; `LabPacketBuilder.buildRandomShow()`
  returns only the hex and `LabPacketBuilder.buildRandomShowStep()` returns `(label:hex:)`;
  `LabPacketBuilder.vib(enabled:pattern:)` keeps its labels; `PresetCatalog.vibratePacket` is Android's
  "Vibrate band" (white + burst). Always open the Swift file and read the real signature.
- The views RecordTab, FilesTab, AutoTab, PresetsTab and LabTab no longer exist.
