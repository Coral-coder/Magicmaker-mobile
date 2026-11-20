package com.magicmaker.android.ui.vfd

import com.magicmaker.android.core.AutoResponseRule
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.PacketPattern
import com.magicmaker.android.core.PacketPatterns
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.service.ServiceState

/**
 * AUTO tab in the VFD theme, laid out like tools/vfd/screens/auto.py (port of
 * ios/MagicMaker/VFD/VFDAutoScreen.swift, behaviour of the standard AutoTab): the arm header
 * (AUTO-RESPONSE, TRIGGER → STACKED TX, the RX | TX-AUTO counters and the arm switch), a dim rule,
 * the rule builder (RULE NAME field, WHEN I HEAR and ADD RESPONSE TO STACK picker fields, the
 * STACK rows with a remove × each, ADD RULE) and RULES (n) with one row per saved rule (name,
 * "<trigger id> → n pkts", enable switch, trash).
 *
 * Every control calls what AutoTab calls: ACTION_SET_AUTO, MagicStore.addAutoRule /
 * setAutoRuleEnabled / deleteAutoRule. The option pickers are VFD menus listing the same options
 * (PacketPatterns.buildTriggerOptions / buildResponseOptions on the library); the rule name is a
 * text prompt. The builder lives in this tab's UI state while the app runs (AutoTab keeps it in
 * remember). The standard AUTO tab shows no colour content, so nothing here uses true colours.
 */
object VFDAutoScreen : VFDScreen {
    override val title: String = "AUTO"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        val ui: VFDUIState = autoUI(ctx)
        val opts: AutoOptions = options(ctx)
        val b: AutoBuilder = builder(ui)
        var y: Int = L.contentTop
        y = armHeader(ctx, fb, L, ui, c, y, w)
        y = hairline(fb, c, y, w)
        y = VFDW.field(fb, L, c, y, w, "Rule name", b.ruleName, placeholder = "Rule name", action = {
            editRuleName(ctx)
        })
        y = pickerField(fb, L, c, y, w, "When I hear", opts.triggerLabel(b.triggerId), action = {
            openPicker(ctx, trigger = true)
        })
        y = pickerField(fb, L, c, y, w, "Add response to stack", opts.responseLabel(b.pickResponseId), action = {
            openPicker(ctx, trigger = false)
        })
        if (b.stack.isNotEmpty()) {
            y = stackBlock(ctx, fb, L, opts, b.stack, c, y, w)
        }
        val canAdd: Boolean = b.stack.isNotEmpty()
        y = VFDW.button(fb, L, c, y + 2, null, "Add rule", primary = true, enabled = canAdd, action = {
            addRule(ctx)
        })
        y = rulesBlock(ctx, fb, L, c, y, w)
        return y
    }

    // MARK: - Keys and snapshots

    private const val tabKey: String = "auto"
    private const val keyRuleName: String = "auto.ruleName"
    private const val keyTriggerId: String = "auto.triggerId"
    private const val keyPickResponseId: String = "auto.pickResponseId"
    /** The response stack, in order. */
    private const val keyStack: String = "auto.stack"
    /** AutoTab's `auto` switch state: its value and the service flag it was set against
     *  (remember(state.autoEnabled)). */
    private const val keyArm: String = "auto.arm"
    private const val keyArmBase: String = "auto.armBase"
    private const val defaultRuleName: String = "My rule"

    /** Square cell a pixel icon button is centred in (as VFDW.stepW). */
    private const val iconBtn: Int = 13
    /** One rule row: two text lines, the divider (rule_row's geometry). */
    private val ruleRowH: Int = 3 + VFDW.line + 7 + 3 + 1

    /** 9 x 10 trash can (lid with handle, body with three slots). */
    private val trash: List<String> = listOf(
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
    )

    /** The rule builder as one draw reads it. */
    private class AutoBuilder(
        val ruleName: String,
        val triggerId: String,
        val pickResponseId: String,
        val stack: List<String>,
    )

    /** AutoTab's `triggers` / `responses` (remember(storeRev)), with the first option of each id
     *  (its firstOrNull lookups). */
    private class AutoOptions(val triggers: List<PacketPattern>, val responses: List<PacketPattern>) {
        val triggerById: Map<String, PacketPattern> = firstById(triggers)
        val responseById: Map<String, PacketPattern> = firstById(responses)

        /** `triggers.firstOrNull { it.id == triggerId }?.label ?: triggerId`. */
        fun triggerLabel(id: String): String = triggerById[id]?.label ?: id

        /** `responses.firstOrNull { it.id == id }?.label ?: id`. */
        fun responseLabel(id: String): String = responseById[id]?.label ?: id

        private companion object {
            fun firstById(list: List<PacketPattern>): Map<String, PacketPattern> {
                val out = HashMap<String, PacketPattern>(list.size * 2)
                for (p in list) {
                    if (!out.containsKey(p.id)) out[p.id] = p
                }
                return out
            }
        }
    }

    // MARK: - State (read only)

    private fun autoUI(ctx: VFDContext): VFDUIState = ctx.uiState(tabKey)

    /** AutoTab starts the builder on the third system trigger ("Any starlight wand") ... */
    private val defaultTriggerId: String
        get() {
            val list: List<PacketPattern> = PacketPatterns.systemTriggers
            return if (list.size > 2) list[2].id else "starlight"
        }

    /** ... and on the second system response ("Vibrate band"). */
    private val defaultResponseId: String
        get() {
            val list: List<PacketPattern> = PacketPatterns.systemResponses
            return if (list.size > 1) list[1].id else "resp_vibrate"
        }

    private fun builder(ui: VFDUIState): AutoBuilder = AutoBuilder(
        ruleName = ui.string(keyRuleName, defaultRuleName),
        triggerId = ui.string(keyTriggerId, defaultTriggerId),
        pickResponseId = ui.string(keyPickResponseId, defaultResponseId),
        stack = stack(ui),
    )

    private fun stack(ui: VFDUIState): List<String> {
        val raw: String = ui.string(keyStack, "")
        if (raw.isEmpty()) return emptyList()
        return raw.split("\n")
    }

    private fun setStack(ui: VFDUIState, ids: List<String>) {
        ui.setString(keyStack, ids.joinToString("\n"))
    }

    /** The options built from the library at the current store revision (cached). */
    private fun options(ctx: VFDContext): AutoOptions =
        ctx.cached("auto.options", ctx.state.storeRevision) {
            val store: MagicStore = ctx.store
            val learned: List<MagicPacket> = store.allLearnedPackets
            val userPresets: List<MagicPacket> = store.customPresets
            AutoOptions(
                PacketPatterns.buildTriggerOptions(userPresets, learned),
                PacketPatterns.buildResponseOptions(userPresets, learned),
            )
        }

    private fun rules(ctx: VFDContext): List<AutoResponseRule> =
        ctx.cached("auto.rules", ctx.state.storeRevision) { ctx.store.autoRules }

    /** AutoTab's `auto`: the switch's own value until the service's flag changes. */
    private fun armed(ctx: VFDContext, ui: VFDUIState): Boolean {
        val service: Boolean = ctx.state.autoEnabled
        if (ui.has(keyArm) && ui.bool(keyArmBase) == service) {
            return ui.bool(keyArm)
        }
        return service
    }

    /** AutoRuleRow's description: "<trigger id> → n pkt(s)", a stackless rule counting as one. */
    private fun describe(rule: AutoResponseRule): String {
        val stackSize: Int = maxOf(rule.responseHexes.size, 1)
        return rule.triggerPatternId + " → " + stackSize + " pkt" + (if (stackSize == 1) "" else "s")
    }

    // MARK: - Small helpers

    /** Light the '#' cells of a small pixel-art bitmap with its top-left at (x, y). */
    private fun bitmap(fb: VFDFrameBuffer, x: Int, y: Int, rows: List<String>, color: Int) {
        for ((j, line) in rows.withIndex()) {
            for ((i, ch) in line.withIndex()) {
                if (ch == '#') fb.set(x + i, y + j, color)
            }
        }
    }

    /** " | "-separated tokens drawn as the telemetry line draws them (a 9-row bar, 4 empty cells
     *  each side), stopping with … at column [limit] (exclusive). Returns the end column. */
    private fun tokens(fb: VFDFrameBuffer, x0: Int, r: Int, toks: List<String>, color: Int, limit: Int): Int {
        var x: Int = x0
        for ((i, tok) in toks.withIndex()) {
            val tw: Int = VFDText.width(tok)
            if (i > 0) {
                val bar: Int = x + 3
                val nxt: Int = bar + 5
                if (nxt + tw > limit) {
                    if (x + VFDText.width(VFDText.ellipsis) <= limit) {
                        x = fb.text(x, r, VFDText.ellipsis, VFDSize.small, color)
                    }
                    return x
                }
                fb.vline(bar, r - 1, 9, color)
                x = nxt
            }
            if (x + tw > limit) {
                return fb.textFit(x, r, tok, limit - x, VFDSize.small, color)
            }
            x = fb.text(x, r, tok, VFDSize.small, color)
        }
        return x
    }

    /** A solid dim rule with 3 empty rows above it, closing the arm header off from the rule
     *  builder. Returns the next free row. */
    private fun hairline(fb: VFDFrameBuffer, c: Int, y: Int, w: Int): Int {
        fb.hline(c, y + 1, w, VFDInk.dim)
        return y + 2
    }

    /** AutoPickerField: the caption and a boxed read-only field with the value (truncated with …)
     *  and a dim down-chevron 2 cells inside the right border. Taps "picker:<CAPTION>". */
    private fun pickerField(fb: VFDFrameBuffer, L: VFDLayout, c: Int, y: Int, w: Int, caption: String, value: String,
                            action: () -> Unit): Int {
        val shown: String = VFDText.fit(value, w - 18)
        val y0: Int = VFDW.groupTop(L, y) + VFDW.labelH
        val next: Int = VFDW.field(fb, L, c, y, w, caption, shown, name = "picker:" + VFDW.upper(caption),
                                   action = action)
        VFDW.chevron(fb, c + w - 10, y0 + VFDW.ctrlText + 1, false, VFDInk.dim)
        return next
    }

    /** The stack row's xmark: a 7 x 7 dim ×, centred in an iconBtn square at (x, y). */
    private fun removeX(fb: VFDFrameBuffer, x: Int, y: Int, name: String, action: () -> Unit) {
        val ox: Int = x + (iconBtn - 7) / 2
        val oy: Int = y + (iconBtn - 7) / 2
        for (i in 0 until 7) {
            fb.set(ox + i, oy + i, VFDInk.dim)
            fb.set(ox + 6 - i, oy + i, VFDInk.dim)
        }
        VFDW.tap(fb, x - 1, y, iconBtn + 2, iconBtn, name, action = action)
    }

    /** The rule's delete button: the pixel trash can in the alarm colour, centred in an iconBtn
     *  square at (x, y); on a red-ish base a solid highlight square with the can cut out. [hit] is
     *  the tap rectangle (the whole row height, from just past the switch to the screen edge). */
    private fun trashButton(fb: VFDFrameBuffer, x: Int, y: Int, name: String, hit: VFDRect, action: () -> Unit) {
        val ox: Int = x + (iconBtn - 9) / 2
        val oy: Int = y + (iconBtn - 10) / 2
        if (fb.alarmInverted) {
            fb.fill(x, y, iconBtn, iconBtn, VFDInk.highlight)
            bitmap(fb, ox, oy, trash, VFDInk.unlit)
        } else {
            bitmap(fb, ox, oy, trash, VFDInk.alarm)
        }
        VFDW.tap(fb, hit.c, hit.r, hit.w, hit.h, name, action = action)
    }

    // MARK: - Sections

    /** AutoArmHeader: AUTO-RESPONSE (highlight), TRIGGER → STACKED TX (dim) and RX:n | TX-AUTO:n
     *  (dim) on three lines, the arm switch right-aligned and centred on them. */
    private fun armHeader(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, ui: VFDUIState, c: Int, y: Int,
                          w: Int): Int {
        val s: ServiceState.UiState = ctx.state
        val sx: Int = c + w - VFDW.switchW
        val tw: Int = sx - 6 - c
        val r: Int = y + 1
        fb.textFit(c, r, "AUTO-RESPONSE", tw, VFDSize.small, VFDInk.highlight)
        fb.textFit(c, r + VFDW.line, "TRIGGER → STACKED TX", tw, VFDSize.small, VFDInk.dim)
        val heard: String = "RX:" + s.packetsHeard
        val sent: String = "TX-AUTO:" + s.autoResponsesSent
        tokens(fb, c, r + 2 * VFDW.line, listOf(heard, sent), VFDInk.dim, c + tw)
        val blockEnd: Int = r + 2 * VFDW.line + 7
        val sy: Int = r + (blockEnd - r - VFDW.ctrlH) / 2
        val on: Boolean = armed(ctx, ui)
        VFDW.toggle(fb, L, sx, sy, VFDW.switchW, "", on, name = "toggle:AUTO-RESPONSE", action = {
            setArmed(ctx, !armed(ctx, autoUI(ctx)))
        })
        return blockEnd + VFDW.gap
    }

    /** STACK (n): the caption, then one ctrlH row per stacked response, "n. <label>" (truncated)
     *  with the remove × at the right. */
    private fun stackBlock(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, opts: AutoOptions, ids: List<String>,
                           c: Int, top: Int, w: Int): Int {
        var y: Int = VFDW.label(fb, L, c, top, w, "Stack (" + ids.size + ")")
        val bx: Int = c + w - iconBtn
        for ((i, id) in ids.withIndex()) {
            val text: String = (i + 1).toString() + ". " + opts.responseLabel(id)
            fb.textFit(c, y + VFDW.ctrlText, text, bx - 4 - c, VFDSize.small, VFDInk.text)
            val index: Int = i
            removeX(fb, bx, y, "stack:remove:$i") {
                removeFromStack(ctx, index)
            }
            y += VFDW.ctrlH + VFDW.gap
        }
        return y
    }

    /** RULES (n) and the rule rows (only the visible ones drawn), or NO RULES — CONFIGURE STACK
     *  ABOVE. */
    private fun rulesBlock(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, c: Int, top: Int, w: Int): Int {
        val list: List<AutoResponseRule> = rules(ctx)
        var y: Int = VFDW.section(fb, L, c, top, w, "Rules (" + list.size + ")")
        if (list.isEmpty()) {
            return VFDW.statusLine(fb, L, c, y + 1, w, "NO RULES — CONFIGURE STACK ABOVE")
        }
        y -= VFDW.gap + 1
        val clip: VFDRect = fb.clipRect
        val viewTop: Int = clip.r - fb.originY
        val viewBottom: Int = clip.r + clip.h - fb.originY
        for ((i, rule) in list.withIndex()) {
            if (y + ruleRowH <= viewTop || y >= viewBottom) {
                y += ruleRowH
            } else {
                y = ruleRow(ctx, fb, L, c, y, w, rule, i)
            }
        }
        return y
    }

    /** AutoRuleRow: the name (text) over its description (dim), the enable switch and the trash
     *  button on the right, both centred on the two lines; a dotted dim divider closes the row. */
    private fun ruleRow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, c: Int, y: Int, w: Int,
                        rule: AutoResponseRule, index: Int): Int {
        val trashX: Int = c + w - iconBtn
        val sx: Int = trashX - 4 - VFDW.switchW
        val tw: Int = sx - 6 - c
        val r1: Int = y + 3
        val r2: Int = y + 3 + VFDW.line
        fb.textFit(c + 2, r1, rule.name, tw - 2, VFDSize.small, VFDInk.text)
        fb.textFit(c + 2, r2, describe(rule), tw - 2, VFDSize.small, VFDInk.dim)
        val mid: Int = (r1 + r2 + 7) / 2
        val ruleId: Long = rule.id
        val enabled: Boolean = rule.enabled
        VFDW.toggle(fb, L, sx, mid - VFDW.ctrlH / 2, VFDW.switchW, "", enabled, name = "rule:toggle:$index",
                    action = {
                        ctx.store.setAutoRuleEnabled(ruleId, !enabled)
                    })
        val d: Int = r2 + 7 + 3
        val tc: Int = sx + VFDW.switchW + 1
        val ruleName: String = rule.name
        val hit = VFDRect(tc, y, fb.cols - tc, d - y + 1)
        trashButton(fb, trashX, mid - iconBtn / 2, "rule:delete:$index", hit) {
            askDelete(ctx, ruleId, ruleName)
        }
        fb.hline(c, d, w, VFDInk.dim, step = 2)
        return d + 1
    }

    // MARK: - Actions (run from taps, never from draw)

    /** The arm Switch: AutoTab sets its `auto` and sends ACTION_SET_AUTO with the new value. */
    private fun setArmed(ctx: VFDContext, on: Boolean) {
        val ui: VFDUIState = autoUI(ctx)
        ui.setBool(keyArmBase, ctx.state.autoEnabled)
        ui.setBool(keyArm, on)
        MagicMakerForegroundService.send(ctx.context, MagicMakerForegroundService.ACTION_SET_AUTO) {
            putExtra(MagicMakerForegroundService.EXTRA_AUTO, on)
        }
    }

    /** The rule name OutlinedTextField as a text prompt. */
    private fun editRuleName(ctx: VFDContext) {
        val ui: VFDUIState = autoUI(ctx)
        val current: String = ui.string(keyRuleName, defaultRuleName)
        ctx.prompt("RULE NAME", text = current, keyboard = VFDKeyboard.text) { text ->
            ui.setString(keyRuleName, text)
        }
    }

    /** The exposed dropdown as a VFD menu (a scrolling list, as the standard LazyColumn): a pick
     *  sets the trigger, or picks a response and adds it to the stack when not in it yet. */
    private fun openPicker(ctx: VFDContext, trigger: Boolean) {
        val opts: AutoOptions = options(ctx)
        val list: List<PacketPattern> = if (trigger) opts.triggers else opts.responses
        val items = ArrayList<VFDMenuItem>(list.size)
        for (option in list) {
            val picked: PacketPattern = option
            val text: String = option.label.ifEmpty { option.id }
            items.add(VFDMenuItem(text) {
                if (trigger) pickTrigger(ctx, picked) else pickResponse(ctx, picked)
            })
        }
        ctx.menu(if (trigger) "When I hear" else "Add response to stack", items)
    }

    private fun pickTrigger(ctx: VFDContext, option: PacketPattern) {
        autoUI(ctx).setString(keyTriggerId, option.id)
    }

    private fun pickResponse(ctx: VFDContext, option: PacketPattern) {
        val ui: VFDUIState = autoUI(ctx)
        ui.setString(keyPickResponseId, option.id)
        val ids: List<String> = stack(ui)
        if (option.id !in ids) {
            setStack(ui, ids + option.id)
        }
    }

    private fun removeFromStack(ctx: VFDContext, index: Int) {
        val ui: VFDUIState = autoUI(ctx)
        val ids: List<String> = stack(ui)
        if (index < 0 || index >= ids.size) return
        setStack(ui, ids.filterIndexed { i, _ -> i != index })
    }

    /** ADD RULE: the stacked responses' packets in order (a response without one is left out of the
     *  hexes but keeps its id), MagicStore.addAutoRule, then the stack is cleared. */
    private fun addRule(ctx: VFDContext) {
        val ui: VFDUIState = autoUI(ctx)
        val ids: List<String> = stack(ui)
        if (ids.isEmpty()) return
        val opts: AutoOptions = options(ctx)
        val hexes: List<String> = ids.mapNotNull { id ->
            opts.responseById[id]?.defaultHex?.takeIf { it.isNotEmpty() }
        }
        val name: String = ui.string(keyRuleName, defaultRuleName)
        val triggerId: String = ui.string(keyTriggerId, defaultTriggerId)
        ctx.store.addAutoRule(name, triggerId, ids, hexes)
        setStack(ui, emptyList())
    }

    /** The trash button. AutoTab deletes at once; the VFD row's delete tap spans the whole row
     *  height to the screen edge, so it asks first (as the iPhone AUTO tab does). */
    private fun askDelete(ctx: VFDContext, id: Long, name: String) {
        ctx.confirm("Delete auto rule?", VFDW.upper(name), confirmLabel = "DELETE", destructive = true) {
            ctx.store.deleteAutoRule(id)
        }
    }
}
