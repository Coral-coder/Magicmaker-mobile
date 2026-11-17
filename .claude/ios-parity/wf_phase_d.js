export const meta = {
  name: 'ios-parity-audit',
  description: 'Audit the compiled iOS app against Android by area, verify each finding adversarially, then fix the confirmed ones',
  phases: [
    { title: 'Audit', detail: 'one auditor per area: parity gaps and runtime bugs, read-only' },
    { title: 'Verify', detail: 'a skeptic tries to refute every finding' },
    { title: 'Fix', detail: 'one fixer per file group, confirmed findings only' },
    { title: 'Integrate', detail: 'whole-target compile read of every changed file' },
  ],
}

const S = '/tmp/claude-0/-home-user-Magicmaker-mobile/8956e220-2c18-5594-88a6-966886e08e67/scratchpad/'
const R = '/home/user/Magicmaker-mobile/'
const IOS = R + 'ios/MagicMaker/'
const AND = R + 'android/app/src/main/java/com/magicmaker/android/'
const UI = AND + 'ui/'

const CONTEXT = 'Repo ' + R + ' (branch main). The iOS app (' + IOS + ') was just brought to feature parity with the Android app (' + AND + '): the Android Kotlin is the specification. The whole iOS app now COMPILES in CI (Xcode 26, iOS 17, Swift 5.9 mode); there is no Swift compiler on this machine. Read ' + S + 'IOS_PORT_RULES.md first (rules for any Swift you touch), then skim ' + S + 'IOS_ARCHITECTURE.md and ' + S + 'IOS_SCREENS.md (how the iOS app is meant to work).\n\n' +
  'DELIBERATE differences — never report these:\n' +
  '- An iPhone cannot broadcast these packets: every send goes through a linked relay (Android phone or ESP32) via TxEngine; with no relay linked the control stays enabled and tx.status says why.\n' +
  '- Source ids are CoreBluetooth peripheral UUIDs (last 8 characters shown), no manual MAC entry.\n' +
  '- Left out on purpose: battery-optimisation banner, RUN IN BACKGROUND / start on boot, all-files access, APK update, relay HOST mode (hotspot, GATT server), cloud dictionary sync, permission banner, the top title bar. The tab bar is at the bottom.\n' +
  '- Scanning, loops, replay and auto-responses run while the app is in the foreground (screen kept awake); iOS cannot scan these adverts in the background.\n' +
  '- Lab: one SEND button (no builder SEND NOW); builder edits land in the hex field.\n' +
  '- Wide layouts keep one packet per List row (swipe actions are per row).\n' +
  '- Confirmation dialogs on deletes where Android deletes at once; iPhone-only extras (Hawkeye themes and MBLE in the Lab, LIGHTS/REPLAY telemetry tokens, Settings SCAN FILTER and ABOUT, Diag STATUS block, SHARE buttons, Map REFRESH).\n' +
  '- The relay-echo guard in AppViewModel (drops the packet being sent while a send is in progress) and dropping packets during a replay.\n'

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'short unique slug, e.g. scan-01' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          kind: { type: 'string', enum: ['crash', 'wrong-behaviour', 'missing-feature', 'stale-ui', 'performance', 'data-loss', 'relay-protocol'] },
          file: { type: 'string', description: 'path relative to ios/MagicMaker (or android/... if the fix belongs there)' },
          line: { type: 'integer' },
          summary: { type: 'string' },
          scenario: { type: 'string', description: 'concrete user steps / inputs and what goes wrong' },
          evidence: { type: 'string', description: 'the Swift lines and the Kotlin lines that show it, with file:line' },
          fix: { type: 'string', description: 'the smallest change that fixes it' },
        },
        required: ['id', 'severity', 'kind', 'file', 'summary', 'scenario', 'evidence', 'fix'],
      },
    },
    checkedButFine: { type: 'array', items: { type: 'string' } },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['confirmed', 'refuted', 'uncertain'] },
          reason: { type: 'string' },
          file: { type: 'string', description: 'the file the fix belongs in, relative to ios/MagicMaker (or android/...)' },
          fix: { type: 'string', description: 'the exact fix to apply (refined if the auditor got it wrong)' },
        },
        required: ['id', 'verdict', 'reason'],
      },
    },
  },
  required: ['verdicts'],
}

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    applied: { type: 'array', items: { type: 'string' } },
    skipped: { type: 'array', items: { type: 'string' } },
    filesChanged: { type: 'array', items: { type: 'string' } },
    crossFileFollowUps: { type: 'array', items: { type: 'string' } },
    unsure: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['applied', 'skipped', 'filesChanged', 'summary'],
}

const AREAS = [
  {
    key: 'scan',
    ios: ['Views/ScanScreen.swift', 'ViewModels/ScanEngine.swift', 'Views/SharedViews.swift', 'Views/BandPreviewView.swift', 'Core/LivePacketSection.swift'],
    android: [UI + 'MagicMakerScreens.kt (ScanTab, ScanPacketList, liveSubtitle, BandConfigSection, LibraryFileSection, dialogs)', UI + 'SwipePacketRow.kt', UI + 'PacketActionSheet.kt', UI + 'BandPreview.kt', AND + 'service/MagicMakerForegroundService.kt (handleHeard, auto-response)', AND + 'service/ServiceState.kt (appendLive, caps, sources)'],
    focus: 'The SCAN tab end to end: what a packet heard by the iPhone does (live feed, grouping, counters, LAST LIGHTS strip that must show only packets that light the band, library learning, session log, auto-response), every control and gesture on the screen, MY MAGICBAND tagging, library export/import.',
  },
  {
    key: 'txwand',
    ios: ['Views/TxScreen.swift', 'Views/WandScreen.swift', 'Views/StarlightWandView.swift', 'ViewModels/TxEngine.swift', 'ViewModels/AppViewModel.swift (wand quick button, New Wand names, wand display colour)'],
    android: [UI + 'MagicMakerScreens.kt (TransmitTab, TxSwipeRow, TxLoopSettingsSection, SectionFilterDropdown, WandTab, NewWandList)', UI + 'StarlightWandView.kt', AND + 'core/MagicTransmitter.kt', AND + 'service/MagicMakerForegroundService.kt (tx loop, starlight loop, random show, transmit, keep-awake)', AND + 'core/NewWandCatalog.kt'],
    focus: 'TX and WAND tabs and the send engine: tap-to-send, loops (start/stop, interval, mutual exclusion, resume at launch, what happens when the looped packet is deleted), wand colour display, New Wand list, quick button, VIBRATE / INTERROGATE, burst timing sent to the relay, status strings.',
  },
  {
    key: 'autosetdiag',
    ios: ['Views/AutoScreen.swift', 'Views/SettingsScreen.swift', 'Views/DiagScreen.swift', 'Core/PacketPatterns.swift', 'Data/CrashLog.swift', 'ViewModels/AppViewModel.swift (sendRelaySetting, setAndroid*)'],
    android: [UI + 'MagicMakerScreens.kt (AutoTab, SettingsTabScreen, TransmissionSettingsSection, DiagnosticsTab, SourceRow)', UI + 'SettingSlider.kt', AND + 'core/PacketPatterns.kt', AND + 'relay/RelayCommands.kt (set_tx_power, set_tx_interleave, set_show_control_only, timing setters)'],
    focus: 'AUTO rules (builder, trigger/response option lists, stacks, enable/disable, the auto-response firing in ScanEngine), SETTINGS (every slider/switch: range, step, default, persistence key, what is pushed to a linked Android relay and with which command and params), DIAG (sources list, crash log).',
  },
  {
    key: 'lab',
    ios: ['Views/LabScreen.swift', 'Views/LabBuilderPanel.swift', 'Views/BandPreviewView.swift', 'Core/LabPacketBuilder.swift', 'Core/LabPacketTools.swift', 'Core/DisneyTlv.swift'],
    android: [UI + 'LabPacketBuilderPanel.kt', UI + 'LabBuilderUi.kt', UI + 'BandPreview.kt', AND + 'core/LabPacketBuilder.kt', AND + 'core/LabPacketTools.kt'],
    focus: 'The LAB tab: persistence of the lab packet and label, load-in-Lab from other tabs (labLoadTick / requestedTab), decode of a loaded packet into the builder without overwriting it, SAVE / TAG / MY PRESETS, packet anatomy and inspector (byte grid edit, vibration stepper), random light show, keep-awake switch, Standard/Extended builder.',
  },
  {
    key: 'logsmap',
    ios: ['Views/LogsScreen.swift', 'Views/MapScreen.swift', 'Core/LogAnalysis.swift', 'Core/MapMath.swift', 'Core/SessionLog.swift', 'Data/MagicStore.swift (session logs, SessionLogFiles)', 'ViewModels/TxEngine.swift (startReplay/stopReplay)'],
    android: [UI + 'MagicMakerScreens.kt (LogsTab)', UI + 'MapTab.kt', AND + 'data/MagicStore.kt (session logs, readLog, analysis helpers)', AND + 'service/MagicMakerForegroundService.kt (replay)'],
    focus: 'LOGS (listing, opening, filters, ANALYZE grouping and noise rule, ADD ALL, NAME, REPLAY with progress/STOP and its filters and timing, DELETE) and MAP (point loading, bucketing, transmitter estimate maths and constants, modes, counts, marker info). Also the CSV format: a log written on the iPhone must open in the Android LOGS tab and the other way round.',
  },
  {
    key: 'linkroot',
    ios: ['Views/LinkScreen.swift', 'Views/ContentView.swift', 'Views/AppTheme.swift (TelemetryBar)', 'Views/LaunchBootstrapView.swift', 'ViewModels/AppViewModel.swift', 'BLE/AndroidRemoteClient.swift', 'BLE/AndroidRelayGattClient.swift', 'BLE/AndroidWifiRelayClient.swift', 'BLE/BleCoordinator.swift', 'BLE/BleCentral.swift', 'BLE/RelayBackend.swift'],
    android: [AND + 'relay/RelayCommands.kt', AND + 'relay/RelayGattServer.kt', AND + 'relay/RelayHttpServer.kt', AND + 'relay/RelayProtocol.kt', AND + 'service/ServiceState.kt (statusJson)', UI + 'MagicMakerScreens.kt (TelemetryLine, RelayTab)', R + 'firmware/esp32-transmitter (the ESP32 relay protocol)'],
    focus: 'The relay link and root: every command the iPhone sends (action names and params must exist in RelayCommands.kt / the ESP32 firmware with the same meaning), how a send reaches the relay and how completion/failure comes back, link state (remoteLinkReady) on each backend, the LINK screen (pairing, backend picker, the Android relay panel), the ten-tab root (tab switching to Lab on request, relay polling), the telemetry line, app launch order.',
  },
  {
    key: 'persistence',
    ios: ['Data/MagicStore.swift', 'Core/MagicModels.swift', 'Core/SessionLog.swift', 'ViewModels/AppViewModel.swift (UserDefaults keys)'],
    android: [AND + 'data/MagicStore.kt', AND + 'core/MagicModels.kt', UI + 'UiPrefs.kt'],
    focus: 'Data safety. (1) UPGRADE: the previous iOS build wrote Documents/magicmaker_store.json — read its writer with `git -C ' + R + ' show 55b4128:ios/MagicMaker/Data/MagicStore.swift` and its models with `git -C ' + R + ' show 55b4128:ios/MagicMaker/Core/MagicModels.swift`, and prove the new store loads every such file without losing a packet, rule or setting (trace decoding of every field). (2) LIBRARY FILE: a file exported by Android (MagicStore.kt export, Gson field names, PrefEntry format, settings/uiSettings) must import on iOS, and an iOS export must import on Android (field names, types, Long vs Int, NaN). (3) Saves: debounce/queue, app backgrounding and termination, no lost writes, no blocking the main thread. (4) Learning rules and caps vs MagicStore.kt.',
  },
]

function auditPrompt(a) {
  return CONTEXT + '\n\nTASK: read-only audit of one area of the iOS app. Do NOT edit any file.\n' +
    'AREA: ' + a.key + ' — ' + a.focus + '\n' +
    'iOS files (under ' + IOS + '): ' + a.ios.join(', ') + ' — and anything they call.\n' +
    'Android specification: ' + a.android.join('; ') + '.\n\n' +
    'Find REAL defects a user of this app would hit, in this order of importance: crashes and data loss; behaviour that differs from Android in a way the user notices (wrong packet sent, wrong label/count/status text, a control that does nothing or the wrong thing, a setting not saved or not applied, a list that does not refresh); missing Android controls or behaviours (not on the deliberate list); runtime problems (main-thread stalls on big libraries/logs, SwiftUI identity bugs such as duplicate ForEach ids, timers or tasks that leak or fire after stop, state that resets when switching tabs where Android keeps it).\n' +
    'Trace real code paths: for each control, follow the tap through the view, engine and store, and compare with what the Kotlin does for the same tap. Quote file:line for both sides. Do not report style, naming, comments, or anything you cannot point to in the code. Do not speculate about SwiftUI behaviour you are unsure of; say "uncertain" in the summary instead of guessing. If the area is clean, return an empty findings list — that is a good result.\n' +
    'For every finding give the smallest fix. List in checkedButFine the main paths you traced and found correct.'
}

function verifyPrompt(a, audit) {
  return CONTEXT + '\n\nTASK: adversarial verification. Another engineer audited the "' + a.key + '" area and reported the findings below. Your job is to REFUTE each one by reading the actual code (Swift under ' + IOS + ' and the Kotlin under ' + AND + '). Do not edit files.\n' +
    'For each finding: open the cited lines and everything relevant around them; check whether the scenario really happens (follow the real call path, check guards elsewhere, check whether the Kotlin really behaves as claimed, check whether the difference is on the deliberate list). Verdict: "confirmed" only if you can see the defect yourself in the code; "refuted" if the code does not do what is claimed, or the Kotlin behaves the same way, or it is a deliberate difference; "uncertain" otherwise. For confirmed ones, give the exact fix to apply and the file it belongs in (correct the auditor\'s fix if it is wrong, incomplete or would not compile).\n\n' +
    'FINDINGS: ' + JSON.stringify((audit && audit.findings) || [])
}

phase('Audit')
const verified = await pipeline(
  AREAS,
  a => agent(auditPrompt(a), { label: 'audit:' + a.key, phase: 'Audit', schema: FINDINGS_SCHEMA }),
  (audit, a) => {
    const findings = (audit && audit.findings) || []
    if (findings.length === 0) {
      log(a.key + ': no findings')
      return { key: a.key, findings: [], verdicts: [] }
    }
    return agent(verifyPrompt(a, audit), { label: 'verify:' + a.key, phase: 'Verify', schema: VERDICT_SCHEMA, effort: 'high' })
      .then(v => ({ key: a.key, findings, verdicts: (v && v.verdicts) || [] }))
  }
)

// Join each confirmed verdict with its finding. Needs every area's result together to group by file.
const confirmed = []
const notConfirmed = []
for (const r of verified.filter(Boolean)) {
  for (const f of r.findings) {
    const v = r.verdicts.find(x => x.id === f.id)
    if (v && v.verdict === 'confirmed') {
      confirmed.push({ area: r.key, id: f.id, severity: f.severity, kind: f.kind, file: (v.file || f.file || '').trim(), summary: f.summary, scenario: f.scenario, evidence: f.evidence, fix: v.fix || f.fix, verifierNote: v.reason })
    } else {
      notConfirmed.push({ area: r.key, id: f.id, summary: f.summary, verdict: v ? v.verdict : 'no verdict', reason: v ? v.reason : '' })
    }
  }
}
log('confirmed ' + confirmed.length + ', not confirmed ' + notConfirmed.length)

// One fixer per file; files with several findings get them all at once so edits never race.
function baseFile(path) {
  let p = path.replace(/^.*ios\/MagicMaker\//, '')
  const paren = p.indexOf(' (')
  if (paren > 0) p = p.slice(0, paren)
  return p.trim()
}
const byFile = {}
for (const c of confirmed) {
  const key = baseFile(c.file) || 'unknown'
  if (!byFile[key]) byFile[key] = []
  byFile[key].push(c)
}
const unplaced = byFile['unknown'] || []
delete byFile['unknown']
if (unplaced.length) log(unplaced.length + ' confirmed finding(s) without a file go to the integrator')
const groups = Object.keys(byFile).map(k => ({ file: k, items: byFile[k] }))

phase('Fix')
const fixes = await parallel(groups.map(g => () => agent(
  CONTEXT + '\n\nTASK: apply verified fixes. Each finding below was reported by an auditor and confirmed by an independent verifier. Apply the fixes to ' + (g.file.startsWith('android/') ? R + g.file : IOS + g.file) + ' ONLY (other fixers are editing other files at the same time). If a fix also needs a change in another file, do not make it: describe it exactly in crossFileFollowUps (file, what to change, why).\n' +
  'Re-read the code before each edit; if a finding no longer applies or the fix would break something, skip it and say why. Keep edits minimal and in the existing style; the file compiles today and must still compile (IOS_PORT_RULES.md). Kotlin files: same rule, Android CI compiles them.\n' +
  'When done, re-read the whole changed region as the compiler would and count braces/parens/brackets with python.\n\n' +
  'FINDINGS: ' + JSON.stringify(g.items),
  { label: 'fix:' + g.file, phase: 'Fix', schema: FIX_SCHEMA }
)))

const fixReports = groups.map((g, i) => ({ file: g.file, report: fixes[i] }))
const followUps = fixReports.flatMap(f => ((f.report && f.report.crossFileFollowUps) || []).map(x => f.file + ' → ' + x))
for (const u of unplaced) followUps.push('UNPLACED FINDING (find the right file and fix it): ' + JSON.stringify(u))

phase('Integrate')
const integrate = await agent(
  CONTEXT + '\n\nTASK: integration after several engineers applied fixes to different files at the same time, without a compiler. You may edit any file under ' + IOS + ' (and the Android files named below) with the smallest possible edits.\n' +
  '1) Apply these cross-file follow-ups the fixers could not make themselves (check each still makes sense first): ' + JSON.stringify(followUps) + '\n' +
  '2) For every file changed (list: ' + JSON.stringify(fixReports.map(f => (f.report && f.report.filesChanged) || [])) + ' plus your own), read every changed region (use `git -C ' + R + ' diff`) as the Swift compiler would: names, argument labels, optionality, types, Int/Int64/Double conversions, @MainActor use, view-builder rules, exhaustive switches, duplicate declarations across the module, brace balance. Fix what is wrong.\n' +
  '3) Check the fixes did not conflict with each other (two fixes changing the same behaviour in different files in incompatible ways).\n' +
  'Report every edit you made, anything that still worries you, and the list of all files changed by this whole phase (from git diff --stat).',
  { label: 'integrate', phase: 'Integrate', effort: 'high', schema: {
    type: 'object',
    properties: {
      edits: { type: 'array', items: { type: 'string' } },
      risks: { type: 'array', items: { type: 'string' } },
      filesChanged: { type: 'array', items: { type: 'string' } },
      newFiles: { type: 'array', items: { type: 'string' } },
      summary: { type: 'string' },
    },
    required: ['edits', 'risks', 'filesChanged', 'summary'],
  } }
)

return { confirmed, notConfirmed, fixReports, integrate }
