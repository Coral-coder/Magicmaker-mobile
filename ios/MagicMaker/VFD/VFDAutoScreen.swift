import SwiftUI

/// AUTO tab in the VFD theme, laid out like tools/vfd/screens/auto.py: the arm header
/// (AUTO-RESPONSE, TRIGGER → STACKED TX, the RX | TX-AUTO counters and the arm switch), a dim rule,
/// the rule builder (RULE NAME field, WHEN I HEAR and ADD RESPONSE TO STACK picker fields, the
/// STACK rows with a remove × each, ADD RULE) and RULES (n) with one row per saved rule (name,
/// "<trigger id> → n pkts", enable switch, trash). Every control calls what AutoScreen calls:
/// ScanEngine.setAuto, MagicStore.addAutoRule / setAutoRuleEnabled / deleteAutoRule (after the
/// same "Delete auto rule?" question). The option pickers are VFD menus listing the same options
/// (system + user presets + learned packets, + New Wand codes for responses); the rule name is a
/// text prompt. The builder lives in this tab's UI state while the app runs (AutoScreen keeps it
/// in @State). The only true colours are the picker rows' swatches of wand colour codes (Starlight
/// colours, New Wand codes) in their glow colour; the pickers open at the field's current value.
@MainActor
enum VFDAutoScreen: VFDScreen {
    static let title: String = "AUTO"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        let ui: VFDUIState = autoUI(ctx)
        let b: VFDAutoBuilder = builder(ui)
        var y: Int = L.contentTop
        y = armHeader(ctx, fb, L, c, y, w)
        y = hairline(fb, c, y, w)
        y = VFDW.field(fb, L, c, y, w, "Rule name", b.ruleName, placeholder: "Rule name", action: {
            VFDAutoScreen.editRuleName(ctx)
        })
        let triggerText: String = triggerLabel(ui, b.triggerId)
        y = pickerField(fb, L, c, y, w, "When I hear", triggerText, action: {
            VFDAutoScreen.openPicker(ctx, trigger: true)
        })
        let responseText: String = responseLabel(ui, b.pickResponseId)
        y = pickerField(fb, L, c, y, w, "Add response to stack", responseText, action: {
            VFDAutoScreen.openPicker(ctx, trigger: false)
        })
        if !b.stack.isEmpty {
            y = stackBlock(ctx, fb, L, ui, b.stack, c, y, w)
        }
        let canAdd: Bool = !b.stack.isEmpty
        y = VFDW.button(fb, L, c, y + 2, nil, "Add rule", primary: true, enabled: canAdd, action: {
            VFDAutoScreen.addRule(ctx)
        })
        y = rulesBlock(ctx, fb, L, c, y, w)
        return y
    }
}

// MARK: - Keys and snapshots

/// This tab's in-memory UI keys (the rule builder's @State in AutoScreen).
private enum VFDAutoKeys {
    static let tab: String = "auto"
    static let ruleName: String = "auto.ruleName"
    static let triggerId: String = "auto.triggerId"
    static let pickResponseId: String = "auto.pickResponseId"
    /// The response stack: ids joined by `separator`, in order.
    static let stack: String = "auto.stack"
    static let separator: String = "\n"
    /// The label of a picked option, by id (the options' labels, as the picker showed them).
    static let triggerLabelPrefix: String = "auto.triggerLabel."
    static let responseLabelPrefix: String = "auto.responseLabel."
    static let defaultRuleName: String = "My rule"
}

/// The rule builder as one draw reads it.
private struct VFDAutoBuilder {
    let ruleName: String
    let triggerId: String
    let pickResponseId: String
    let stack: [String]
}

@MainActor
extension VFDAutoScreen {
    // MARK: geometry

    /// Square cell a pixel icon button is centred in (as VFDW.stepW).
    private static let iconBtn: Int = 13
    /// One rule row: two text lines, the divider (rule_row's geometry).
    private static let ruleRowH: Int = 3 + VFDW.line + 7 + 3 + 1

    /// 9 x 10 trash can (lid with handle, body with three slots).
    private static let trash: [String] = [
        "...###...",
        "#########",
        ".........",
        ".#######.",
        ".#.#.#.#.",
        ".#.#.#.#.",
        ".#.#.#.#.",
        ".#.#.#.#.",
        ".#.#.#.#.",
        ".#######.",
    ]

    // MARK: state

    private static func autoUI(_ ctx: VFDContext) -> VFDUIState {
        return ctx.uiState(for: VFDAutoKeys.tab)
    }

    /// Android starts the builder on the third system trigger ("Any starlight wand").
    private static var defaultTriggerId: String {
        let list: [PacketPattern] = PacketPatterns.systemTriggers
        return list.count > 2 ? list[2].id : "starlight"
    }

    /// ... and on the second system response ("Vibrate band").
    private static var defaultResponseId: String {
        let list: [PacketPattern] = PacketPatterns.systemResponses
        return list.count > 1 ? list[1].id : "resp_vibrate"
    }

    private static func builder(_ ui: VFDUIState) -> VFDAutoBuilder {
        return VFDAutoBuilder(
            ruleName: ui.string(VFDAutoKeys.ruleName, default: VFDAutoKeys.defaultRuleName),
            triggerId: ui.string(VFDAutoKeys.triggerId, default: defaultTriggerId),
            pickResponseId: ui.string(VFDAutoKeys.pickResponseId, default: defaultResponseId),
            stack: stack(ui)
        )
    }

    private static func stack(_ ui: VFDUIState) -> [String] {
        let raw: String = ui.string(VFDAutoKeys.stack, default: "")
        if raw.isEmpty { return [] }
        return raw.components(separatedBy: VFDAutoKeys.separator)
    }

    private static func setStack(_ ui: VFDUIState, _ ids: [String]) {
        ui.setString(VFDAutoKeys.stack, ids.joined(separator: VFDAutoKeys.separator))
    }

    /// AutoScreen.triggerLabel: the picked option's label, a system trigger's label, else the id.
    private static func triggerLabel(_ ui: VFDUIState, _ id: String) -> String {
        if let stored = ui.optionalString(VFDAutoKeys.triggerLabelPrefix + id) {
            return stored
        }
        if let system = PacketPatterns.systemTriggers.first(where: { (p: PacketPattern) -> Bool in p.id == id }) {
            return system.label
        }
        return id
    }

    /// AutoScreen.responseLabel: the picked option's label, a system response's label, else the id.
    private static func responseLabel(_ ui: VFDUIState, _ id: String) -> String {
        if let stored = ui.optionalString(VFDAutoKeys.responseLabelPrefix + id) {
            return stored
        }
        if let system = PacketPatterns.systemResponses.first(where: { (p: PacketPattern) -> Bool in p.id == id }) {
            return system.label
        }
        return id
    }

    /// AutoRuleRow.describe: "<trigger id> → n pkt(s)", a stackless rule counting as one.
    private static func describe(_ rule: AutoResponseRule) -> String {
        let stackSize: Int = max(rule.responseHexes.count, 1)
        let plural: String = stackSize == 1 ? "" : "s"
        return rule.triggerPatternId + " → " + String(stackSize) + " pkt" + plural
    }

    // MARK: small helpers

    /// Content rows [top, bottom) the current clip shows (rows outside it need no drawing).
    private static func visibleRows(_ fb: VFDFrameBuffer) -> (top: Int, bottom: Int) {
        let clip: (c: Int, r: Int, w: Int, h: Int) = fb.clipRect
        let oy: Int = fb.originY
        return (top: clip.r - oy, bottom: clip.r + clip.h - oy)
    }

    /// Light the '#' cells of a small pixel-art bitmap with its top-left at (x, y).
    private static func bitmap(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ rows: [String], _ color: UInt8) {
        var j: Int = 0
        for line in rows {
            var i: Int = 0
            for u in line.unicodeScalars {
                if u == "#" {
                    fb.set(x + i, y + j, color)
                }
                i += 1
            }
            j += 1
        }
    }

    /// " | "-separated tokens drawn as the telemetry line draws them (a 9-row bar, 4 empty cells
    /// each side), stopping with … at column `limit` (exclusive). Returns the end column.
    @discardableResult
    private static func tokens(_ fb: VFDFrameBuffer, _ x0: Int, _ r: Int, _ toks: [String], _ color: UInt8,
                               _ limit: Int) -> Int {
        var x: Int = x0
        var i: Int = 0
        for tok in toks {
            let tw: Int = VFDText.width(tok)
            if i > 0 {
                let bar: Int = x + 3
                let nxt: Int = bar + 5
                if nxt + tw > limit {
                    if x + VFDText.width(VFDText.ellipsis) <= limit {
                        x = fb.text(x, r, VFDText.ellipsis, .small, color)
                    }
                    return x
                }
                fb.vline(bar, r - 1, 9, color)
                x = nxt
            }
            if x + tw > limit {
                return fb.textFit(x, r, tok, limit - x, .small, color)
            }
            x = fb.text(x, r, tok, .small, color)
            i += 1
        }
        return x
    }

    /// A solid dim rule with 3 empty rows above it, closing the arm header off from the rule
    /// builder. Returns the next free row.
    private static func hairline(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int) -> Int {
        fb.hline(c, y + 1, w, VFDInk.dim)
        return y + 2
    }

    /// AutoPickerField: the caption and a boxed read-only field with the value (truncated with …)
    /// and a dim down-chevron 2 cells inside the right border. Taps "picker:<CAPTION>".
    private static func pickerField(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ y: Int, _ w: Int,
                                    _ caption: String, _ value: String, action: @escaping () -> Void) -> Int {
        let shown: String = VFDText.fit(value, w - 18)
        let y0: Int = VFDW.groupTop(L, y) + VFDW.labelH
        let next: Int = VFDW.field(fb, L, c, y, w, caption, shown, name: "picker:" + VFDW.upper(caption),
                                   action: action)
        VFDW.chevron(fb, c + w - 10, y0 + VFDW.ctrlText + 1, false, VFDInk.dim)
        return next
    }

    /// The stack row's xmark: a 7 x 7 dim ×, centred in an iconBtn square at (x, y).
    private static func removeX(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ name: String,
                                action: @escaping () -> Void) {
        let ox: Int = x + (iconBtn - 7) / 2
        let oy: Int = y + (iconBtn - 7) / 2
        for i in 0..<7 {
            fb.set(ox + i, oy + i, VFDInk.dim)
            fb.set(ox + 6 - i, oy + i, VFDInk.dim)
        }
        VFDW.tap(fb, x - 1, y, iconBtn + 2, iconBtn, name, action: action)
    }

    /// The rule's delete button: the pixel trash can in the alarm colour, centred in an iconBtn
    /// square at (x, y); on a red-ish base a solid highlight square with the can cut out. `hit`
    /// is the tap rectangle (the whole row height, from just past the switch to the screen edge).
    private static func trashButton(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ name: String,
                                    hit: (c: Int, r: Int, w: Int, h: Int), action: @escaping () -> Void) {
        let ox: Int = x + (iconBtn - 9) / 2
        let oy: Int = y + (iconBtn - 10) / 2
        if fb.alarmInverted {
            fb.fill(x, y, iconBtn, iconBtn, VFDInk.highlight)
            bitmap(fb, ox, oy, trash, VFDInk.unlit)
        } else {
            bitmap(fb, ox, oy, trash, VFDInk.alarm)
        }
        VFDW.tap(fb, hit.c, hit.r, hit.w, hit.h, name, action: action)
    }

    // MARK: sections

    /// AutoArmHeader: AUTO-RESPONSE (highlight), TRIGGER → STACKED TX (dim) and RX:n | TX-AUTO:n
    /// (dim) on three lines, the arm switch right-aligned and centred on them.
    private static func armHeader(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ y: Int,
                                  _ w: Int) -> Int {
        let scan: ScanEngine = ctx.scan
        let sx: Int = c + w - VFDW.switchW
        let tw: Int = sx - 6 - c
        let r: Int = y + 1
        fb.textFit(c, r, "AUTO-RESPONSE", tw, .small, VFDInk.highlight)
        fb.textFit(c, r + VFDW.line, "TRIGGER → STACKED TX", tw, .small, VFDInk.dim)
        let heard: String = "RX:" + String(scan.packetsHeard)
        let sent: String = "TX-AUTO:" + String(scan.autoResponsesSent)
        tokens(fb, c, r + 2 * VFDW.line, [heard, sent], VFDInk.dim, c + tw)
        let blockEnd: Int = r + 2 * VFDW.line + 7
        let sy: Int = r + (blockEnd - r - VFDW.ctrlH) / 2
        let armed: Bool = scan.autoEnabled
        VFDW.toggle(fb, L, sx, sy, VFDW.switchW, "", armed, name: "toggle:AUTO-RESPONSE", action: {
            scan.setAuto(!scan.autoEnabled)
        })
        return blockEnd + VFDW.gap
    }

    /// STACK (n): the caption, then one ctrlH row per stacked response, "n. <label>" (truncated)
    /// with the remove × at the right.
    private static func stackBlock(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ ui: VFDUIState,
                                   _ ids: [String], _ c: Int, _ top: Int, _ w: Int) -> Int {
        var y: Int = VFDW.label(fb, L, c, top, w, "Stack (" + String(ids.count) + ")")
        let bx: Int = c + w - iconBtn
        var i: Int = 0
        for id in ids {
            let text: String = String(i + 1) + ". " + responseLabel(ui, id)
            fb.textFit(c, y + VFDW.ctrlText, text, bx - 4 - c, .small, VFDInk.text)
            let index: Int = i
            removeX(fb, bx, y, "stack:remove:" + String(i), action: {
                VFDAutoScreen.removeFromStack(ctx, at: index)
            })
            y += VFDW.ctrlH + VFDW.gap
            i += 1
        }
        return y
    }

    /// RULES (n) and the rule rows (only the visible ones drawn), or NO RULES — CONFIGURE STACK
    /// ABOVE.
    private static func rulesBlock(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ top: Int,
                                   _ w: Int) -> Int {
        let rules: [AutoResponseRule] = ctx.store.autoRules
        var y: Int = VFDW.section(fb, L, c, top, w, "Rules (" + String(rules.count) + ")")
        if rules.isEmpty {
            return VFDW.statusLine(fb, L, c, y + 1, w, "NO RULES — CONFIGURE STACK ABOVE")
        }
        y -= VFDW.gap + 1
        let view: (top: Int, bottom: Int) = visibleRows(fb)
        var i: Int = 0
        for rule in rules {
            if y + ruleRowH <= view.top || y >= view.bottom {
                y += ruleRowH
            } else {
                y = ruleRow(ctx, fb, L, c, y, w, rule, i)
            }
            i += 1
        }
        return y
    }

    /// AutoRuleRow: the name (text) over its description (dim), the enable switch and the trash
    /// button on the right, both centred on the two lines; a dotted dim divider closes the row.
    private static func ruleRow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ y: Int,
                                _ w: Int, _ rule: AutoResponseRule, _ index: Int) -> Int {
        let store: MagicStore = ctx.store
        let trashX: Int = c + w - iconBtn
        let sx: Int = trashX - 4 - VFDW.switchW
        let tw: Int = sx - 6 - c
        let r1: Int = y + 3
        let r2: Int = y + 3 + VFDW.line
        fb.textFit(c + 2, r1, rule.name, tw - 2, .small, VFDInk.text)
        fb.textFit(c + 2, r2, describe(rule), tw - 2, .small, VFDInk.dim)
        let mid: Int = (r1 + r2 + 7) / 2
        let ruleId: Int64 = rule.id
        let enabled: Bool = rule.enabled
        VFDW.toggle(fb, L, sx, mid - VFDW.ctrlH / 2, VFDW.switchW, "", enabled, name: "rule:toggle:" + String(index),
                    action: {
                        store.setAutoRuleEnabled(id: ruleId, enabled: !enabled)
                    })
        let d: Int = r2 + 7 + 3
        let tc: Int = sx + VFDW.switchW + 1
        let ruleName: String = rule.name
        let hit: (c: Int, r: Int, w: Int, h: Int) = (c: tc, r: y, w: fb.cols - tc, h: d - y + 1)
        trashButton(fb, trashX, mid - iconBtn / 2, "rule:delete:" + String(index), hit: hit, action: {
            VFDAutoScreen.askDelete(ctx, id: ruleId, name: ruleName)
        })
        fb.hline(c, d, w, VFDInk.dim, step: 2)
        return d + 1
    }

    // MARK: actions

    /// The rule name TextField as a text prompt.
    private static func editRuleName(_ ctx: VFDContext) {
        let ui: VFDUIState = autoUI(ctx)
        let current: String = ui.string(VFDAutoKeys.ruleName, default: VFDAutoKeys.defaultRuleName)
        ctx.prompt(title: "Rule name", text: current, keyboard: .text, onDone: { (text: String) -> Void in
            ui.setString(VFDAutoKeys.ruleName, text)
        })
    }

    /// AutoScreen.openPicker: the option list (built from the library now, like reloadOptions)
    /// as a VFD menu; a pick sets the trigger, or picks a response and adds it to the stack.
    private static func openPicker(_ ctx: VFDContext, trigger: Bool) {
        let store: MagicStore = ctx.store
        let presets: [MagicPacket] = store.customPresets
        let learned: [MagicPacket] = store.allLearnedPackets
        var options: [PacketPattern] = []
        if trigger {
            options = PacketPatterns.buildTriggerOptions(userPresets: presets, learned: learned)
            if options.isEmpty {
                options = PacketPatterns.systemTriggers
            }
        } else {
            options = PacketPatterns.buildResponseOptions(userPresets: presets, learned: learned)
            if options.isEmpty {
                options = PacketPatterns.systemResponses
            }
        }
        // The field's current value is the selected row, and the list opens at it.
        let b: VFDAutoBuilder = builder(autoUI(ctx))
        let currentId: String = trigger ? b.triggerId : b.pickResponseId
        var selected: Int? = nil
        var items: [VFDMenuItem] = []
        items.reserveCapacity(options.count)
        var row: Int = 0
        for option in options {
            let picked: PacketPattern = option
            let text: String = option.label.isEmpty ? option.id : option.label
            if selected == nil && option.id == currentId {
                selected = row
            }
            items.append(VFDMenuItem(text, rgb: wandSwatch(option.defaultHex), action: {
                if trigger {
                    VFDAutoScreen.pickTrigger(ctx, picked)
                } else {
                    VFDAutoScreen.pickResponse(ctx, picked)
                }
            }))
            row += 1
        }
        let title: String = trigger ? "When I hear" : "Add response to stack"
        ctx.menu(title: title, items: items, selected: selected)
    }

    /// The glow colour of an option that is one wand colour code (a Starlight colour or a New Wand
    /// code), as the WAND tab shows it, for the option's menu swatch; nil for any other packet.
    private static func wandSwatch(_ hex: String) -> VFDRGB? {
        if hex.isEmpty { return nil }
        let model: BandEffectModel = BandEffectModel.from(hex)
        if model.kind != BandEffectModel.Kind.wand { return nil }
        let upper: String = HexUtils.canonicalHex(hex).uppercased()
        if upper.contains(NewWandCatalog.prefix) {
            // NewWandCatalog's colour: the last byte's low 5 bits.
            let value: Int = Int(String(upper.suffix(2)), radix: 16) ?? 0
            return VFDColors.starlightGlow(value & 0x1F)
        }
        return VFDColors.starlightGlow(MagicClassifier.starlightColorIndex(hex))
    }

    private static func pickTrigger(_ ctx: VFDContext, _ option: PacketPattern) {
        let ui: VFDUIState = autoUI(ctx)
        ui.setString(VFDAutoKeys.triggerLabelPrefix + option.id, option.label)
        ui.setString(VFDAutoKeys.triggerId, option.id)
    }

    private static func pickResponse(_ ctx: VFDContext, _ option: PacketPattern) {
        let ui: VFDUIState = autoUI(ctx)
        ui.setString(VFDAutoKeys.responseLabelPrefix + option.id, option.label)
        ui.setString(VFDAutoKeys.pickResponseId, option.id)
        var ids: [String] = stack(ui)
        if !ids.contains(option.id) {
            ids.append(option.id)
            setStack(ui, ids)
        }
    }

    private static func removeFromStack(_ ctx: VFDContext, at index: Int) {
        let ui: VFDUIState = autoUI(ctx)
        var ids: [String] = stack(ui)
        guard index >= 0, index < ids.count else { return }
        ids.remove(at: index)
        setStack(ui, ids)
    }

    /// AutoScreen.addRule: the stack's packets in order (a response with no packet of its own is
    /// left out of the hexes but keeps its id), then the stack is cleared.
    private static func addRule(_ ctx: VFDContext) {
        let ui: VFDUIState = autoUI(ctx)
        let store: MagicStore = ctx.store
        let ids: [String] = stack(ui)
        if ids.isEmpty { return }
        let options: [PacketPattern] = PacketPatterns.buildResponseOptions(userPresets: store.customPresets,
                                                                             learned: store.allLearnedPackets)
        var byId: [String: PacketPattern] = [:]
        for option in options where byId[option.id] == nil {
            byId[option.id] = option
        }
        var hexes: [String] = []
        for id in ids {
            var found: PacketPattern? = byId[id]
            if found == nil {
                found = PacketPatterns.systemResponses.first(where: { (p: PacketPattern) -> Bool in p.id == id })
            }
            let hex: String = found?.defaultHex ?? ""
            if !hex.isEmpty {
                hexes.append(hex)
            }
        }
        let name: String = ui.string(VFDAutoKeys.ruleName, default: VFDAutoKeys.defaultRuleName)
        let triggerId: String = ui.string(VFDAutoKeys.triggerId, default: defaultTriggerId)
        store.addAutoRule(name: name, triggerId: triggerId, responseIds: ids, responseHexes: hexes)
        setStack(ui, [])
    }

    /// confirmDelete with AutoScreen's request: "Delete auto rule?", the rule's name, DELETE.
    private static func askDelete(_ ctx: VFDContext, id: Int64, name: String) {
        let store: MagicStore = ctx.store
        let ruleId: Int64 = id
        ctx.confirm(title: "Delete auto rule?", message: name.uppercased(), confirmLabel: "DELETE",
                    destructive: true, action: {
                        store.deleteAutoRule(id: ruleId)
                    })
    }
}
