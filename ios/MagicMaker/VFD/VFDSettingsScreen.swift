import SwiftUI

/// SETTINGS tab in the VFD theme, exactly as tools/vfd/screens/settings.py draws it, on the
/// standard SettingsScreen's real values and actions: the screen note, APPEARANCE (THEME, then
/// BASE COLOUR with the stored colour's hex on its label row and a true-colour swatch in every
/// chip; CUSTOM opens the system colour picker in a sheet), TRANSMISSION SETTINGS (folds, under
/// the standard screen's preference key: relay note, TX MODE switch, BROADCAST STRENGTH, the WAKE
/// SLICE / COMMAND BURST / STARLIGHT WAND sliders), SCAN FILTER, BACKGROUND and ABOUT.
@MainActor
enum VFDSettingsScreen: VFDScreen {
    static let title: String = "SETTINGS"

    static let headerNote: String = "Global transmission tuning — applies to every TX."
    static let themes: [String] = ["STANDARD", "VFD"]

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        var y: Int = L.contentTop
        y = VFDW.textBlock(fb, L, c, y, w, headerNote, color: VFDInk.dim)
        y = appearance(ctx, c, y, w)
        y = transmission(ctx, c, y, w)
        y = scanFilter(ctx, c, y, w)
        y = background(ctx, c, y, w)
        y = about(ctx, c, y, w)
        return y
    }

    /// APPEARANCE: THEME [STANDARD] [VFD]; under VFD, BASE COLOUR (#RRGGBB right-aligned in
    /// highlight) and the chips, left-flowing like THEME.
    static func appearance(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let settings: VFDSettings = ctx.settings
        var y: Int = VFDW.section(fb, L, c, top, w, "APPEARANCE")
        let themeIndex: Int = settings.theme == .vfd ? 1 : 0
        y = VFDW.options(fb, L, c, y, w, themes, selected: themeIndex, label: "THEME", onSelect: { index in
            let next: VFDTheme = index == 0 ? VFDTheme.standard : VFDTheme.vfd
            settings.theme = next
        })
        if settings.theme != .vfd {
            return y
        }
        let r: Int = VFDW.groupTop(L, y)
        let hx: String = settings.base.rgb.hex
        let vw: Int = VFDText.width(hx)
        fb.text(c + w - vw, r, hx, .small, VFDInk.highlight)
        fb.textFit(c, r, "BASE COLOUR", w - vw - 6, .small, VFDInk.dim)
        return baseChips(ctx, c, r + VFDW.labelH, w)
    }

    /// The BASE COLOUR chips: VFDW.options geometry with one extra glyph slot after "[" holding a
    /// 5 x 5 swatch of the chip's own colour (CUSTOM: the stored custom colour). The selected chip
    /// is the solid block with its name cut out and an unlit ring around the swatch. Taps
    /// "option:BASE COLOUR:<ITEM>".
    static func baseChips(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let settings: VFDSettings = ctx.settings
        let items: [String] = VFDSettings.baseItems
        let selected: Int = settings.baseIndex
        let adv: Int = VFDW.adv
        var x: Int = c
        var y: Int = top
        var i: Int = 0
        for item in items {
            var ow: Int = VFDText.width(count: VFDText.length(item) + 3)
            if x > c && x + ow > c + w {
                x = c
                y += VFDW.ctrlH + VFDW.gap
            }
            ow = min(ow, c + w - x)
            let shown: String = VFDText.fit(item, ow - 3 * adv)
            let fw: Int = VFDText.width(count: VFDText.length(shown) + 3)
            let ty: Int = y + VFDW.ctrlText
            if i == selected {
                fb.fill(x, y + 1, fw, VFDW.ctrlH - 2, VFDInk.highlight)
                fb.fill(x + adv - 1, ty, 7, 7, VFDInk.unlit)
                fb.text(x + 2 * adv, ty, shown, .small, VFDInk.unlit)
            } else {
                fb.text(x, ty, "[", .small, VFDInk.dim)
                fb.text(x + 2 * adv, ty, shown, .small, VFDInk.text)
                fb.text(x + fw - 5, ty, "]", .small, VFDInk.dim)
            }
            let swatch: UInt8 = fb.rgb(settings.itemRGB(i))
            fb.fill(x + adv, ty + 1, 5, 5, swatch)
            let index: Int = i
            VFDW.tap(fb, x - VFDW.optGap / 2, y, ow + VFDW.optGap, VFDW.ctrlH, "option:BASE COLOUR:" + item,
                     action: {
                         VFDSettingsScreen.chooseBase(ctx, index)
                     })
            x += ow + VFDW.optGap
            i += 1
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /// A preset applies at once; CUSTOM selects the stored custom colour and opens the picker.
    static func chooseBase(_ ctx: VFDContext, _ index: Int) {
        ctx.settings.selectBase(index: index)
        if index >= VFDBase.presets.count {
            ctx.sheet(id: "vfd.customBase") {
                VFDCustomColorSheet()
            }
        }
    }
}

// MARK: - Copy and settings keys

private enum VFDSettingsCopy {
    /// SettingsScreenPrefs.transmissionCollapsedKey (Android's preference name).
    static let transmissionCollapsedKey: String = "lab_tx_settings_collapsed"
    /// settingsPowerNames: broadcast strength levels 0...3.
    static let powerNames: [String] = ["MIN", "LOW", "MED", "MAX"]
    static let linkedNote: String = "ANDROID RELAY LINKED — CHANGES ARE SENT TO IT TOO"
    static let esp32LinkedNote: String = "ESP32 LINKED — CHANGES ARE SENT TO IT TOO"
    static let unlinkedNote: String = "TX MODE AND STRENGTH APPLY ON THE RELAY (ANDROID OR ESP32)"
    static let interleaveHint: String = "Alternates wake/command slices — lighter, good in-park. WAKE=slice, COMMAND=total window."
    static let sustainedHint: String = "Sustained wake stream, then command stream — strongest wake. WAKE=wake length, COMMAND=command length."
    static let strengthHint: String = "Lower = shorter range, fewer nearby bands react · default MAX"
    static let filterHint: String = "Filter MagicBand/device noise out of the scan (default on); flip to see all raw."
    static let sep: String = " · "
}

// MARK: - Transmission, scan filter, about

extension VFDSettingsScreen {
    /// TRANSMISSION SETTINGS (folds; chevron down when folded, up when open): relay note, TX MODE,
    /// BROADCAST STRENGTH, WAKE SLICE / COMMAND BURST / STARLIGHT WAND.
    fileprivate static func transmission(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let ui: VFDUIState = ctx.uiState(for: "settings")
        let key: String = VFDSettingsCopy.transmissionCollapsedKey
        let collapsed: Bool = ui.storedBool(key, default: false)
        var y: Int = disclosureHeader(fb, L, c, top, w, "TRANSMISSION SETTINGS", collapsed, action: {
            let folded: Bool = ui.storedBool(key, default: false)
            ui.setStoredBool(key, !folded)
        })
        if collapsed {
            return y
        }
        let store: MagicStore = ctx.store
        var note: String = VFDSettingsCopy.unlinkedNote
        if relayTakesSettings(ctx) {
            note = ctx.vm.relayBackend == .esp32 ? VFDSettingsCopy.esp32LinkedNote : VFDSettingsCopy.linkedNote
        }
        y = VFDW.textBlock(fb, L, c, y, w, note, color: VFDInk.dim)

        let interleave: Bool = store.getTxInterleave()
        let mode: String = interleave ? "TX MODE: INTERLEAVE" : "TX MODE: SUSTAINED"
        y = VFDW.toggle(fb, L, c, y, w, mode, interleave, name: "toggle:TX MODE", labelColor: VFDInk.highlight,
                        action: {
                            let next: Bool = !ctx.store.getTxInterleave()
                            VFDSettingsScreen.setInterleave(ctx, next)
                        })
        let modeHint: String = interleave ? VFDSettingsCopy.interleaveHint : VFDSettingsCopy.sustainedHint
        y = hint(fb, c, y, w, modeHint)

        let power: Int? = store.getTxPowerLevel()
        let names: [String] = VFDSettingsCopy.powerNames
        y = VFDW.options(fb, L, c, y, w, names, selected: power, label: "BROADCAST STRENGTH", columns: names.count,
                         onSelect: { (level: Int) -> Void in
                             VFDSettingsScreen.setTxPower(ctx, level)
                         })
        y = hint(fb, c, y, w, VFDSettingsCopy.strengthHint)

        let wakeHint: String = "Each wake/command slice in the 1:1 interleave · default \(TransmitTiming.defaultWakeupPreludeMs)ms"
        y = timingSlider(ctx, c, y, w, title: "WAKE SLICE MS", name: "slider:WAKE SLICE", key: "wakeSlice",
                         value: store.getWakeupPreambleMs(), low: TransmitTiming.minWakeupPreludeMs,
                         high: TransmitTiming.maxWakeupPreludeMs, step: 50, hint: wakeHint,
                         commit: { (ms: Int) -> Void in
                             VFDSettingsScreen.commitPreamble(ctx, ms)
                         })
        let burstHint: String = "Total wake+command interleave window · default \(TransmitTiming.commandBurstMs)ms · global"
        y = timingSlider(ctx, c, y, w, title: "COMMAND BURST MS", name: "slider:COMMAND BURST", key: "commandBurst",
                         value: store.getCommandBurstMs(), low: TransmitTiming.minCommandBurstMs,
                         high: TransmitTiming.maxCommandBurstMs, step: 50, hint: burstHint,
                         commit: { (ms: Int) -> Void in
                             VFDSettingsScreen.commitBurst(ctx, ms)
                         })
        // Android gives this slider 18 inner stops over 250…5000 ms, which is one stop per 250 ms.
        let starHint: String = "On-air time for starlight wand TX · no band wakeup · default \(TransmitTiming.starlightBurstMs)ms"
        y = timingSlider(ctx, c, y, w, title: "STARLIGHT WAND MS", name: "slider:STARLIGHT WAND", key: "starlight",
                         value: store.getStarlightBurstMs(), low: TransmitTiming.minStarlightBurstMs,
                         high: TransmitTiming.maxStarlightBurstMs, step: 250, hint: starHint,
                         commit: { (ms: Int) -> Void in
                             VFDSettingsScreen.commitStarlight(ctx, ms)
                         })
        return y
    }

    /// SCAN FILTER: SHOW-CTRL / ALL RAW + switch (the iPhone's own filter; a linked Android relay is
    /// told too), then the hint.
    fileprivate static func scanFilter(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        var y: Int = VFDW.section(fb, L, c, top, w, "SCAN FILTER")
        let on: Bool = ctx.scan.showControlOnly
        let text: String = on ? "SHOW-CTRL" : "ALL RAW"
        y = VFDW.toggle(fb, L, c, y, w, text, on, name: "toggle:SCAN FILTER",
                        labelColor: on ? VFDInk.highlight : VFDInk.dim, action: {
                            let next: Bool = !ctx.scan.showControlOnly
                            ctx.scan.showControlOnly = next
                            VFDSettingsScreen.scanFilterChanged(ctx, next)
                        })
        return hint(fb, c, y, w, VFDSettingsCopy.filterHint)
    }

    /// BACKGROUND: the KEEP RUNNING switch, its state line (ALARM while it needs Location) and the
    /// note (SettingsBackgroundSection).
    fileprivate static func background(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let vm: AppViewModel = ctx.vm
        var y: Int = VFDW.section(fb, L, c, top, w, "BACKGROUND")
        let on: Bool = vm.keepRunningInBackground
        y = VFDW.toggle(fb, L, c, y, w, "KEEP RUNNING", on, name: "toggle:KEEP RUNNING",
                        labelColor: on ? VFDInk.highlight : VFDInk.dim, action: {
                            ctx.vm.setKeepRunningInBackground(!ctx.vm.keepRunningInBackground)
                        })
        let state: AppViewModel.BackgroundKeepAlive = vm.backgroundKeepAlive
        let stateColor: UInt8 = state == .needsLocation ? VFDInk.alarm : VFDInk.dim
        y = VFDW.textBlock(fb, L, c, y, w, state.text, color: stateColor)
        return VFDW.textBlock(fb, L, c, y, w, AppViewModel.backgroundKeepAliveNote, color: VFDInk.dim)
    }

    /// ABOUT: MAGICMAKER v<version> (<build>).
    fileprivate static func about(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let y: Int = VFDW.section(fb, L, c, top, w, "ABOUT")
        fb.textFit(c, y, "MAGICMAKER " + appVersionText(), w, .small, VFDInk.dim)
        return y + VFDW.line
    }

    /// "v1.3.0 (13)" from the bundle's short version and build number (settingsAppVersionText).
    fileprivate static func appVersionText() -> String {
        let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
        let short: String = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build: String = (info["CFBundleVersion"] as? String) ?? "?"
        return "v\(short) (\(build))"
    }

    // MARK: drawing pieces

    /// TRANSMISSION SETTINGS: section() geometry with the iOS up / down chevron (up when open);
    /// the whole line is the fold tap.
    fileprivate static func disclosureHeader(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ top: Int, _ w: Int,
                                             _ title: String, _ collapsed: Bool,
                                             action: @escaping () -> Void) -> Int {
        var r: Int = top
        if r > L.contentTop {
            r += VFDW.sectionGap - VFDW.gap
        }
        if collapsed {
            VFDW.chevron(fb, c, r, false, VFDInk.dim)
        } else {
            VFDW.chevronUp(fb, c, r, VFDInk.dim)
        }
        let upperTitle: String = VFDW.upper(title)
        fb.textFit(c + 11, r, upperTitle, w - 11, .small, VFDInk.highlight)
        fb.hline(c, r + 9, w, VFDInk.dim)
        VFDW.tap(fb, c, r - 3, w, 14, "section:" + upperTitle, action: action)
        return r + VFDW.sectionH + VFDW.gap
    }

    /// A dim wrapped hint under a control (as given), 1 row lower: lines every `line` rows, then
    /// gap. Returns the next free row.
    fileprivate static func hint(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int, _ s: String) -> Int {
        let lines: [String] = wrapHint(s, w)
        if lines.isEmpty { return y }
        var i: Int = 0
        for ln in lines {
            fb.text(c, y + 1 + i * VFDW.line, ln, .small, VFDInk.dim)
            i += 1
        }
        return y + 1 + lines.count * VFDW.line + VFDW.gap
    }

    /// Word-wrap a hint whose clauses are joined by " · ": a clause that does not fit on the
    /// current line but fits a line of its own starts the next line; a longer clause is
    /// word-wrapped from where the line is. No line starts or ends with "·"; over-long words are
    /// hard-broken (settings.py wrap_hint).
    fileprivate static func wrapHint(_ s: String, _ maxCols: Int) -> [String] {
        let n: Int = VFDText.maxChars(maxCols)
        if n <= 0 { return [] }
        let sep: String = VFDSettingsCopy.sep
        let sepLen: Int = VFDText.length(sep)
        var lines: [String] = []
        var cur: String = ""
        for clause in s.components(separatedBy: sep) {
            let words: [String] = clause.components(separatedBy: " ").filter { (word: String) -> Bool in
                !word.isEmpty
            }
            if words.isEmpty { continue }
            let text: String = words.joined(separator: " ")
            let curLen: Int = VFDText.length(cur)
            let textLen: Int = VFDText.length(text)
            if !cur.isEmpty && curLen + sepLen + textLen <= n {
                cur += sep + text
                continue
            }
            if !cur.isEmpty && textLen <= n {
                lines.append(cur)
                cur = text
                continue
            }
            var first: Bool = true
            for original in words {
                let joint: String = first ? sep : " "
                var word: [Unicode.Scalar] = VFDText.scalars(original)
                let need: Int = VFDText.length(cur) + VFDText.length(joint) + word.count
                if !cur.isEmpty && need <= n {
                    cur += joint + original
                } else {
                    if !cur.isEmpty {
                        lines.append(cur)
                    }
                    while word.count > n {
                        lines.append(VFDText.string(Array(word[0..<n])))
                        word = Array(word[n...])
                    }
                    cur = VFDText.string(word)
                }
                first = false
            }
        }
        if !cur.isEmpty {
            lines.append(cur)
        }
        return lines
    }

    /// SettingSlider: the title (unit in it) and the value on the label row, [-] LED bar [+], the
    /// wrapped hint. [-] / [+] commit one step; dragging the bar shows the value under the finger
    /// and commits it on release (a tap on the bar commits there).
    fileprivate static func timingSlider(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int, title: String,
                                         name: String, key: String, value: Int, low: Int, high: Int, step: Int,
                                         hint hintText: String, commit: @escaping (Int) -> Void) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let ui: VFDUIState = ctx.uiState(for: "settings")
        let dragKey: String = key + ".dragging"
        let draftKey: String = key + ".draft"
        let lo: Double = Double(low)
        let hi: Double = Double(high)
        let stepD: Double = Double(step)
        let current: Double = Double(value)
        let dragging: Bool = ui.bool(dragKey)
        let raw: Double = dragging ? ui.double(draftKey, default: current) : current
        let shown: Double = snap(raw, lo, hi, stepD)
        let span: Double = hi - lo
        let frac: Double = span > 0 ? (shown - lo) / span : 0
        let valueText: String = String(Int(shown.rounded()))
        let y: Int = VFDW.slider(fb, L, c, top, w, title, valueText, frac, name: name, canDec: current > lo,
                                 canInc: current < hi,
                                 onDec: {
                                     ui.setBool(dragKey, false)
                                     let next: Double = VFDSettingsScreen.snap(current - stepD, lo, hi, stepD)
                                     commit(VFDSettingsScreen.milliseconds(next))
                                 },
                                 onInc: {
                                     ui.setBool(dragKey, false)
                                     let next: Double = VFDSettingsScreen.snap(current + stepD, lo, hi, stepD)
                                     commit(VFDSettingsScreen.milliseconds(next))
                                 })
        // The bar's drag, over the slider's own bar hit.
        let barRow: Int = VFDW.groupTop(L, top) + VFDW.labelH
        let bx: Int = c + VFDW.stepW + 4
        let bw: Int = w - 2 * (VFDW.stepW + 4)
        VFDW.tap(fb, bx - 2, barRow, bw + 4, VFDW.ctrlH, name + ":bar",
                 drag: { (fraction: Double, ended: Bool) -> Void in
                     let width: Double = Double(bw + 4)
                     let barW: Double = Double(max(1, bw))
                     let pos: Double = (fraction * width - 2.0) / barW
                     let f: Double = min(max(pos, 0.0), 1.0)
                     let ms: Double = lo + f * span
                     if ended {
                         ui.setBool(dragKey, false)
                         let next: Double = VFDSettingsScreen.snap(ms, lo, hi, stepD)
                         commit(VFDSettingsScreen.milliseconds(next))
                     } else {
                         ui.setDouble(draftKey, ms)
                         ui.setBool(dragKey, true)
                     }
                 })
        return hint(fb, c, y, w, hintText)
    }

    /// SettingSlider.snap: the nearest multiple of step (halves up), kept inside the range.
    fileprivate static func snap(_ v: Double, _ low: Double, _ high: Double, _ step: Double) -> Double {
        if !v.isFinite { return low }
        if step <= 0 { return min(max(v, low), high) }
        let steps: Double = (v / step + 0.5).rounded(.down)
        return min(max(steps * step, low), high)
    }

    /// settingsMilliseconds: whole milliseconds.
    fileprivate static func milliseconds(_ value: Double) -> Int {
        if !value.isFinite { return 0 }
        let bounded: Double = min(max(value, -1_000_000), 1_000_000)
        return Int(bounded)
    }

    // MARK: actions (SettingsScreen)

    /// A relay is linked and takes commands: an Android relay (BLE or WiFi) or the ESP32, which
    /// keeps these settings in its RAM (the iPhone gives them again on every link).
    fileprivate static func relayTakesSettings(_ ctx: VFDContext) -> Bool {
        return ctx.vm.remoteLinkReady
    }

    /// An Android relay (BLE or WiFi) took the change. Otherwise it is noted for the Android
    /// relay's next link, as it was before the ESP32 took settings too.
    fileprivate static func androidRelayLinked(_ ctx: VFDContext) -> Bool {
        return ctx.vm.relayBackend != .esp32 && ctx.vm.remoteLinkReady
    }

    fileprivate static func setInterleave(_ ctx: VFDContext, _ on: Bool) {
        ctx.store.saveTxInterleave(on)
        if relayTakesSettings(ctx) {
            ctx.vm.sendRelaySetting("set_tx_interleave", ["enabled": on])
        }
        if !androidRelayLinked(ctx) {
            ctx.vm.noteRelaySettingPending("tx_interleave")
        }
    }

    fileprivate static func setTxPower(_ ctx: VFDContext, _ level: Int) {
        ctx.store.saveTxPowerLevel(level)
        if relayTakesSettings(ctx) {
            ctx.vm.sendRelaySetting("set_tx_power", ["level": level])
        }
        if !androidRelayLinked(ctx) {
            ctx.vm.noteRelaySettingPending("tx_power")
        }
    }

    fileprivate static func commitPreamble(_ ctx: VFDContext, _ ms: Int) {
        ctx.store.saveWakeupPreambleMs(ms)
        if relayTakesSettings(ctx) {
            ctx.vm.setAndroidWakeupPreamble(ms)
        }
        if !androidRelayLinked(ctx) {
            ctx.vm.noteRelaySettingPending("wakeup_preamble")
        }
    }

    fileprivate static func commitBurst(_ ctx: VFDContext, _ ms: Int) {
        ctx.store.saveCommandBurstMs(ms)
        if relayTakesSettings(ctx) {
            ctx.vm.setAndroidCommandBurst(ms)
        }
        if !androidRelayLinked(ctx) {
            ctx.vm.noteRelaySettingPending("command_burst")
        }
    }

    fileprivate static func commitStarlight(_ ctx: VFDContext, _ ms: Int) {
        ctx.store.saveStarlightBurstMs(ms)
        if relayTakesSettings(ctx) {
            ctx.vm.setAndroidStarlightBurst(ms)
        }
        if !androidRelayLinked(ctx) {
            ctx.vm.noteRelaySettingPending("starlight_burst")
        }
    }

    /// The ESP32 does not scan, so only an Android relay is told.
    fileprivate static func scanFilterChanged(_ ctx: VFDContext, _ on: Bool) {
        if androidRelayLinked(ctx) {
            ctx.vm.sendRelaySetting("set_show_control_only", ["enabled": on])
        } else {
            ctx.vm.noteRelaySettingPending("show_control_only")
        }
    }
}
