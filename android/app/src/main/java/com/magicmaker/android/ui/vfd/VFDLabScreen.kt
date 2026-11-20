package com.magicmaker.android.ui.vfd

import com.magicmaker.android.core.BandEffectModel
import com.magicmaker.android.core.ClassifiedPacket
import com.magicmaker.android.core.DisneyTlv
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.LabPacketBuilder
import com.magicmaker.android.core.LabPacketTools
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.PacketBuilder
import com.magicmaker.android.core.StarlightColors
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.ui.LED_MASKS
import kotlin.math.roundToInt

/**
 * LAB tab in the VFD theme: tools/vfd/screens/lab.py drawn from the standard LabTabScreen's real
 * state (LabTabScreen, LabModeBar, LabPacketBuilderPanel, PacketSummaryCard, PacketAnatomy,
 * PacketInspector, RandomLightShowSection, MY PRESETS). Port of ios/MagicMaker/VFD/VFDLabScreen.swift.
 *
 * The band preview is pinned under the header: the face's five LEDs in their true colours,
 * animated by BandLedAnimation exactly as BandPreview does (30 fps while something moves), the
 * BUZZ line blinking, and a legend of true-colour swatches with the colour names. Everything
 * under it scrolls in its own region (the page itself never scrolls): the mode bar, PACKET
 * BUILDER (type chips, summary card, the type's fields, FRAMING, PACKET ANATOMY, SEND NOW /
 * USE IN HEX FIELD / LOAD HEX), the HEX OUTPUT and LABEL fields, the PACKET INSPECTOR,
 * SEND / SAVE / TAG, RANDOM LIGHT SHOW and MY PRESETS. (MBLE TAP and HAWKEYE THEMES of lab.py are
 * iPhone-only sections; the Android Lab has neither.)
 *
 * The standard screen keeps its working state in remember {}; here it lives in this tab's
 * VFDUIState (see LabState), synced from the store on first entry and whenever another screen
 * sends a packet to the Lab (UiState.labLoadTick), as LabTabScreen's remember(labLoadTick) and
 * LabPacketBuilderPanel's LaunchedEffect(loadTick) do. Pickers open a VFD menu; text entry is a
 * prompt.
 */
object VFDLabScreen : VFDScreen {
    override val title: String = "LAB"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    /** The band preview is pinned and the body scrolls in its own region, so the page never
     *  scrolls: returns null. */
    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        // Back to origin 0 (the page never scrolls; this keeps the rows below in screen rows).
        val pageScroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + pageScroll, fb.cols, L.contentH, dy = pageScroll)
        val m: LabModel = makeModel(ctx)
        val div: Int = bandPreview(ctx, fb, c, L.contentTop, w, m.state.preview)
        val top: Int = div + 1
        val view: Int = L.contentBottom - top
        if (view > 0) {
            bodyWindow(ctx, fb, L, m, c, top, view, w)
        }
        fb.popClip()
        return null
    }

    // MARK: - State

    /** The standard Lab's working state: LabTabScreen's hex, label, preview packet and preset
     *  message plus LabPacketBuilderPanel's fields. */
    private class LabState(
        var hex: String,
        var label: String,
        var preview: String,
        var presetMsg: String?,
        var type: LabPacketBuilder.LabPacketType,
        var colors: List<Int>,
        var vibEnabled: Boolean,
        var vibPattern: Int,
        var rawHex: String,
        var framing: LabPacketBuilder.Framing,
        var showIndex: Int,
        var ledMask: Int,
        var loadMsg: String?,
    ) {
        /** LabPacketBuilderPanel.currentHex: what the builder currently describes ("" when it
         *  cannot be built). */
        fun built(extended: Boolean): String {
            return runCatching {
                val base: String = LabPacketBuilder.build(type, colors, vibEnabled, vibPattern, rawHex, framing,
                                                          showIndex)
                if (extended && type == LabPacketBuilder.LabPacketType.PRESET && ledMask != 7) {
                    PacketBuilder.withZoneMask(base, ledMask)
                } else {
                    base
                }
            }.getOrDefault("")
        }
    }

    /** PacketSummaryCard's content. tone: 0 known (cyan), 1 unknown (amber), 2 invalid (error). */
    private class LabSummary(
        val headline: String,
        val colors: String,
        val details: List<String>,
        val reject: String?,
        val tone: Int,
    )

    /** What the builder's packet derives (cached per packet). */
    private class BuiltInfo(
        val summary: LabSummary,
        val summarySwatches: List<VFDRGB>,
        val segments: List<DisneyTlv.Segment>,
        val slots: List<LabPacketBuilder.ColorSlot>,
        val slotValues: List<Int>,
        val sendable: Boolean,
    )

    /** What the hex field's packet derives (cached per packet). */
    private class HexInfo(
        val classified: ClassifiedPacket?,
        val swatches: List<VFDRGB>,
        val bytes: List<String>,
        val reject: String?,
        val vibration: Int?,
    )

    /** Everything one frame draws from, computed once per draw call (the body is drawn twice). */
    private class LabModel(
        val ui: VFDUIState,
        val state: LabState,
        val built: String,
        val extended: Boolean,
        val builtInfo: BuiltInfo,
        val hexInfo: HexInfo,
        val selectedSegment: Int?,
        val presets: List<MagicPacket>,
        val pingHex: String,
        val inspectorOpen: Boolean,
        val intervalMs: Double,
        val intervalDragging: Boolean,
        val intervalDraft: Double,
    )

    /** One legend entry under the preview text: a true-colour swatch (null = off ring) and the
     *  name. */
    private class LabLegend(val rgb: VFDRGB?, val name: String)

    /** One line of the preview's text column: text in an ink, or the colour legend. */
    private class LabLine(val text: String, val color: Int, val legend: List<LabLegend>, val isLegend: Boolean)

    /** Keys of the LAB tab's VFDUIState (in memory) and the standard screen's preference keys. */
    private object Keys {
        const val tab: String = "lab"
        const val region: String = "lab.body"
        /** labLoadTick the working state was last synced to (absent: never synced). */
        const val sync: String = "sync"
        const val hex: String = "hex"
        const val label: String = "label"
        const val preview: String = "preview"
        const val presetMsg: String = "presetMsg"
        const val packetType: String = "packetType"
        const val colors: String = "colors"
        const val vibOn: String = "vibOn"
        const val vibPattern: String = "vibPattern"
        const val rawHex: String = "rawHex"
        const val channel: String = "channelMarker"
        const val wake: String = "wakePrefix"
        const val timing: String = "timing"
        const val show: String = "showIndex"
        const val mask: String = "ledMask"
        const val loadMsg: String = "loadMsg"
        const val ping: String = "pingHex"
        const val inspector: String = "inspectorOpen"
        const val segment: String = "segment"
        const val segmentHex: String = "segmentHex"
        const val interval: String = "intervalMs"
        const val intervalDrag: String = "intervalDrag"
        const val intervalDraft: String = "intervalDraft"
        /** LabTabScreen's "lab_extended" in magicmaker_ui. */
        const val extended: String = "lab_extended"
    }

    // MARK: - Geometry, wording, option lists

    private const val FACE: Int = 55
    private const val LED: Int = 11
    private val LED_AT: IntArray = intArrayOf(8, 22, 36)
    /** Z1..Z5 as (column, row) in the face's 3 x 3 spots (BandPreview's point order). */
    private val ZONE_SPOT: List<Pair<Int, Int>> = listOf(0 to 2, 0 to 0, 1 to 1, 2 to 0, 2 to 2)
    private const val SWATCH: Int = 7
    private const val CHIP_H: Int = 23
    private const val TRASH_W: Int = 7
    private const val ADV: Int = 6
    private val TRASH: List<String> =
        listOf("..###..", "#######", ".#...#.", ".#.#.#.", ".#.#.#.", ".#.#.#.", ".#...#.", ".#####.")

    private const val standardDetail: String = "Everything here has been seen working."
    private const val extendedDetail: String =
        "Adds RGB sliders, single-LED masks and the Experiments list. Untested on a band."
    private const val awakeOnDetail: String =
        "Scanning paused · streaming pings · SEND goes out for the command interval, then pings resume"
    private const val awakeOffDetail: String =
        "Pause scanning and stream wake pings so the band stays listening between sends."
    private const val builderIntro: String =
        "Pick what the band should do, set the colors, and the card below tells you exactly what you're sending."
    private const val pingFields: String =
        "Nothing to set. Send this just before a command if a band isn't reacting."
    private const val showNote: String =
        "Recorded in the park. Change any colour below; everything else is replayed byte-for-byte."
    private const val ledNote: String =
        "Experimental: the top 3 bits of the colour byte pick which LEDs light. Two values are agreed; tell me what the rest do."
    private const val channelTitle: String = "Channel marker (E1 00)"
    private const val channelDetail: String =
        "Every effect recorded in the park carries this before the effect record. The esp32 presets never did. Try both — one may work where the other doesn't."
    private const val durationNote: String =
        "How long the band holds the effect — the timing byte. Default keeps the shape's own value (~21 s for the colour presets)."
    private const val wakeTitle: String = "Wake ping first (CC03 000100)"
    private const val wakeDetail: String =
        "Tells nearby bands to listen before the effect arrives. The captured show packets all start this way."
    private const val byteHint: String =
        "Color bytes use low 5 bits (00–1F). E0=preset · 80/80=dual · A0×5=rainbow · 40/40=xfade · tail B0|vib."
    private const val showText: String =
        "Shoots a surprise packet — colors, duals, fades, rainbows, effects — on a loop until stopped."
    private const val intervalHint: String =
        "Pause between packets (each packet also plays for the command burst time)."
    private const val savedMsg: String = "Saved preset — see TX + Auto tabs"
    private val rgbNames: List<String> = listOf("RED", "GREEN", "BLUE")
    private val zoneLabels: List<String> = listOf("BOT-L", "TOP-L", "CENTRE", "TOP-R", "BOT-R")

    private const val beaconPingHex: String = "8301CC03000000"
    private val pingOptions: List<Pair<Int, String>> =
        listOf(0 to "Wake ping (CC03 000100)", 1 to "Beacon ping (CC03 000000)")
    private val paletteOptions: List<Pair<Int, String>> by lazy {
        LabPacketBuilder.paletteColors.map { it.id to it.label }
    }
    private val vibrationOptions: List<Pair<Int, String>> by lazy {
        LabPacketBuilder.vibrationPatterns.map { it.id to it.label }
    }
    private val showOptions: List<Pair<Int, String>> by lazy {
        LabPacketBuilder.showEffects.mapIndexed { i, (name, _) -> i to name }
    }
    private val experimentOptions: List<Pair<Int, String>> by lazy {
        LabPacketBuilder.experiments.mapIndexed { i, e -> i to e.name }
    }

    /** The option's name for [id], "?" when it is not in the list (PaletteDropdown). */
    private fun optionName(options: List<Pair<Int, String>>, id: Int): String =
        options.firstOrNull { it.first == id }?.second ?: "?"

    /** A palette option ("#15 Red") as its true colour (swatchFor -> labSwatchColor); null for
     *  anything else. */
    private fun optionSwatch(optionLabel: String): VFDRGB? {
        if (!optionLabel.startsWith("#") || optionLabel.length < 3) return null
        val idx: Int = optionLabel.substring(1, 3).toIntOrNull(16) ?: return null
        return VFDColors.labSwatch(idx)
    }

    // MARK: - Text helpers (lab.py)

    private const val NBSP: String = " "
    private val UNITS: Set<String> =
        setOf("s", "ms", "sec", "min", "b", "byte", "bytes", "bit", "bits", "db", "dbm", "hz", "khz", "pt", "px", "%")

    private fun isUnit(word: String): Boolean = UNITS.contains(word.trimEnd(',', '.', ';', ':', ')', '!', '?').lowercase())

    /** VFDText.wrap, except that the space before a lone "·" and the space between a number and
     *  its unit never break (lab.py wrap). */
    private fun wrap(s: String, maxCols: Int, size: VFDSize = VFDSize.small): List<String> {
        val words: MutableList<String> = ArrayList()
        for (piece in s.split(" ")) {
            if (piece.isEmpty()) continue
            if (words.isNotEmpty()) {
                val prev: String = words[words.size - 1]
                val prevDigit: Boolean = prev.isNotEmpty() && prev.last().isDigit()
                if (piece == "·" || (prevDigit && isUnit(piece))) {
                    words[words.size - 1] = prev + NBSP + piece
                    continue
                }
            }
            words.add(piece)
        }
        return VFDText.wrap(words.joinToString(" "), maxCols, size).map { it.replace(NBSP, " ") }
    }

    /** Word-wrapped lines; with [maxLines] the last kept line ends with … when text was cut. */
    private fun wrapLines(s: String, maxCols: Int, maxLines: Int = 0, size: VFDSize = VFDSize.small): List<String> {
        val lines: MutableList<String> = wrap(s, maxCols, size).toMutableList()
        if (maxLines > 0 && lines.size > maxLines) {
            val kept: MutableList<String> = lines.subList(0, maxLines).toMutableList()
            kept[maxLines - 1] = VFDText.fit(kept[maxLines - 1] + " " + "W".repeat(40), maxCols, size)
            return kept
        }
        return lines
    }

    /** A title on one line if it fits, else broken before its "(...)" part (or word-wrapped), at
     *  most 2 lines. */
    private fun titleLines(s: String, maxCols: Int): List<String> {
        if (VFDText.width(s) <= maxCols) return listOf(s)
        val i: Int = s.indexOf(" (")
        if (i >= 0) {
            val head: String = s.substring(0, i)
            val tail: String = s.substring(i + 2)
            if (VFDText.width(head) <= maxCols) {
                return listOf(head, VFDText.fit("($tail", maxCols))
            }
        }
        return wrapLines(s, maxCols, maxLines = 2)
    }

    /** The summary headline in mid size: one line if it fits, else broken after the "Kind:"
     *  prefix (or word-wrapped), at most 2 lines. */
    private fun midHeadline(s: String, maxCols: Int): List<String> {
        if (VFDText.width(s, VFDSize.mid) <= maxCols) return listOf(s)
        val i: Int = s.indexOf(": ")
        if (i >= 0) {
            val head: String = s.substring(0, i) + ":"
            val tail: String = s.substring(i + 2)
            return listOf(VFDText.fit(head, maxCols, VFDSize.mid), VFDText.fit(tail, maxCols, VFDSize.mid))
        }
        return wrapLines(s, maxCols, maxLines = 2, size = VFDSize.mid)
    }

    /** Parts joined with " · ", wrapping only between parts; a part longer than a line is
     *  word-wrapped on its own. */
    private fun sepLines(parts: List<String>, maxCols: Int): List<String> {
        val sep = " · "
        val lines: MutableList<String> = ArrayList()
        var cur = ""
        for (part in parts) {
            val cand: String = if (cur.isEmpty()) part else cur + sep + part
            if (VFDText.width(cand) <= maxCols) {
                cur = cand
                continue
            }
            if (cur.isNotEmpty()) {
                lines.add(cur)
            }
            if (VFDText.width(part) > maxCols) {
                val wrapped: List<String> = VFDText.wrap(part, maxCols)
                if (wrapped.size > 1) {
                    lines.addAll(wrapped.subList(0, wrapped.size - 1))
                }
                cur = wrapped.lastOrNull() ?: ""
            } else {
                cur = part
            }
        }
        if (cur.isNotEmpty()) {
            lines.add(cur)
        }
        return lines
    }

    private fun encodeInts(values: List<Int>): String = values.joinToString(",")

    private fun decodeInts(s: String): List<Int> = s.split(",").mapNotNull { it.trim().toIntOrNull() }

    // MARK: - State sync and actions

    private fun labUI(ctx: VFDContext): VFDUIState = ctx.uiState(Keys.tab)

    private fun extendedOn(ui: VFDUIState): Boolean = ui.storedBool(Keys.extended, false)

    /** The working state as stored (defaults: a fresh LabPacketBuilderPanel). */
    private fun storedState(ui: VFDUIState): LabState {
        val preset: LabPacketBuilder.LabPacketType = LabPacketBuilder.LabPacketType.PRESET
        val raw: String = ui.string(Keys.packetType, preset.name)
        val type: LabPacketBuilder.LabPacketType =
            LabPacketBuilder.LabPacketType.entries.firstOrNull { it.name == raw } ?: preset
        val colors: List<Int> = if (ui.has(Keys.colors)) {
            decodeInts(ui.string(Keys.colors))
        } else {
            LabPacketBuilder.defaultColors(preset)
        }
        val fallback: LabPacketBuilder.Framing = LabPacketBuilder.defaultFraming(preset)
        val framing = LabPacketBuilder.Framing(
            channelMarker = ui.bool(Keys.channel, fallback.channelMarker),
            wakePrefix = ui.bool(Keys.wake, fallback.wakePrefix),
            timing = ui.int(Keys.timing, PacketBuilder.Timing.DEFAULT),
        )
        return LabState(
            hex = ui.string(Keys.hex),
            label = ui.string(Keys.label),
            preview = ui.string(Keys.preview),
            presetMsg = ui.optionalString(Keys.presetMsg),
            type = type,
            colors = colors,
            vibEnabled = ui.bool(Keys.vibOn, false),
            vibPattern = ui.int(Keys.vibPattern, PacketBuilder.Vibration.TRIPLE),
            rawHex = ui.string(Keys.rawHex),
            framing = framing,
            showIndex = ui.int(Keys.show, 0),
            ledMask = ui.int(Keys.mask, 7),
            loadMsg = ui.optionalString(Keys.loadMsg),
        )
    }

    /** The working state as the standard Lab would show it now (pure): on first entry the store's
     *  packet (decoded into the builder when one was sent here) and the preview on the builder's
     *  packet (LaunchedEffect(currentHex)); after another screen sent a packet here (labLoadTick
     *  moved) the store's packet reloaded and decoded (remember(labLoadTick) +
     *  LaunchedEffect(loadTick)). */
    private fun resolve(ctx: VFDContext): LabState {
        val ui: VFDUIState = labUI(ctx)
        val tick: Int = ctx.state.labLoadTick
        val ext: Boolean = extendedOn(ui)
        val st: LabState = storedState(ui)
        if (!ui.has(Keys.sync)) {
            val saved: String = ctx.store.getLabHex()
            st.hex = saved
            st.label = ctx.store.getLabLabel()
            st.preview = saved
            if (tick > 0) {
                decodeInto(st, saved, "received packet")
            }
            applyExtended(st, ext)
            val current: String = st.built(ext)
            if (current.isNotBlank()) {
                st.preview = current
            }
        } else if (ui.int(Keys.sync, 0) != tick) {
            val before: String = st.built(ext)
            val saved: String = ctx.store.getLabHex()
            st.hex = saved
            st.label = ctx.store.getLabLabel()
            st.preview = saved
            if (tick > 0) {
                val decoded: Boolean = decodeInto(st, saved, "received packet")
                val after: String = st.built(ext)
                if (decoded && after != before && after.isNotBlank()) {
                    st.preview = after
                }
            }
        }
        // Extended switched off elsewhere (the standard theme): LaunchedEffect(extended).
        if (!ext && (st.type.experimental || st.ledMask != 7)) {
            val before: String = st.built(ext)
            applyExtended(st, false)
            val after: String = st.built(ext)
            if (after != before && after.isNotBlank()) {
                st.preview = after
            }
        }
        return st
    }

    private fun saveState(ctx: VFDContext, st: LabState) {
        val ui: VFDUIState = labUI(ctx)
        ui.setString(Keys.hex, st.hex)
        ui.setString(Keys.label, st.label)
        ui.setString(Keys.preview, st.preview)
        ui.setOptionalString(Keys.presetMsg, st.presetMsg)
        ui.setString(Keys.packetType, st.type.name)
        ui.setString(Keys.colors, encodeInts(st.colors))
        ui.setBool(Keys.vibOn, st.vibEnabled)
        ui.setInt(Keys.vibPattern, st.vibPattern)
        ui.setString(Keys.rawHex, st.rawHex)
        ui.setBool(Keys.channel, st.framing.channelMarker)
        ui.setBool(Keys.wake, st.framing.wakePrefix)
        ui.setInt(Keys.timing, st.framing.timing)
        ui.setInt(Keys.show, st.showIndex)
        ui.setInt(Keys.mask, st.ledMask)
        ui.setOptionalString(Keys.loadMsg, st.loadMsg)
        ui.setInt(Keys.sync, ctx.state.labLoadTick)
    }

    /** LabPacketBuilderPanel.applyDecoded + the load message. False when there is nothing to
     *  decode. */
    private fun decodeInto(st: LabState, hex: String, source: String): Boolean {
        val d: LabPacketBuilder.Decoded = runCatching { LabPacketBuilder.decode(hex) }.getOrNull() ?: return false
        st.type = d.type
        st.colors = if (d.colors.isNotEmpty()) d.colors else LabPacketBuilder.defaultColors(d.type)
        st.vibEnabled = d.vibEnabled
        st.vibPattern = d.vibPattern
        st.rawHex = d.rawHex
        st.framing = d.framing
        st.showIndex = d.showIndex
        st.loadMsg = "Loaded ${d.type.label} from $source"
        return true
    }

    /** LabPacketBuilderPanel.selectType. */
    private fun selectType(st: LabState, type: LabPacketBuilder.LabPacketType) {
        if (type == st.type) return
        st.type = type
        st.colors = LabPacketBuilder.defaultColors(type)
        st.framing = LabPacketBuilder.defaultFraming(type)
        if (type == LabPacketBuilder.LabPacketType.RAW && st.rawHex.isBlank()) {
            st.rawHex = st.hex
        }
        st.loadMsg = null
    }

    /** LaunchedEffect(extended): leaving Extended drops back to a Standard type and all LEDs. */
    private fun applyExtended(st: LabState, on: Boolean) {
        if (!on && st.type.experimental) {
            selectType(st, LabPacketBuilder.LabPacketType.PRESET)
        }
        if (!on) {
            st.ledMask = 7
        }
    }

    /** A change the user made in the builder: the pinned preview follows the new packet
     *  (LaunchedEffect(currentHex) -> onHexChanged); the hex field keeps its packet. */
    private fun userEdit(ctx: VFDContext, change: (LabState) -> Unit) {
        val ext: Boolean = extendedOn(labUI(ctx))
        val st: LabState = resolve(ctx)
        val before: String = st.built(ext)
        change(st)
        val after: String = st.built(ext)
        if (after != before && after.isNotBlank()) {
            st.preview = after
        }
        saveState(ctx, st)
    }

    /** The Standard / Extended switch: "lab_extended", then LaunchedEffect(extended). */
    private fun toggleExtended(ctx: VFDContext) {
        val ui: VFDUIState = labUI(ctx)
        val st: LabState = resolve(ctx)
        val wasOn: Boolean = extendedOn(ui)
        val before: String = st.built(wasOn)
        val on: Boolean = !wasOn
        ui.setStoredBool(Keys.extended, on)
        applyExtended(st, on)
        val after: String = st.built(on)
        if (after != before && after.isNotBlank()) {
            st.preview = after
        }
        saveState(ctx, st)
    }

    private fun currentPing(ctx: VFDContext): String = labUI(ctx).string(Keys.ping, PacketBuilder.WAKEUP_PING)

    /** KEEP BAND AWAKE's switch (LabModeBar). */
    private fun toggleKeepAwake(ctx: VFDContext) {
        MagicMakerForegroundService.setKeepAwake(ctx.context, !ctx.state.keepAwakeActive, currentPing(ctx))
    }

    /** The PING picker: a running keep-awake switches to the new ping at once. */
    private fun pickPing(ctx: VFDContext, picked: Int) {
        val next: String = if (picked == 1) beaconPingHex else PacketBuilder.WAKEUP_PING
        labUI(ctx).setString(Keys.ping, next)
        if (ctx.state.keepAwakeActive) {
            MagicMakerForegroundService.setKeepAwake(ctx.context, true, next)
        }
    }

    /** SEND NOW (the builder's onTransmit): the built packet into the hex field and the store,
     *  then on the air. */
    private fun sendBuilt(ctx: VFDContext) {
        val ext: Boolean = extendedOn(labUI(ctx))
        val st: LabState = resolve(ctx)
        val current: String = st.built(ext)
        if (current.isBlank()) return
        st.hex = current
        ctx.store.saveLabHex(current)
        saveState(ctx, st)
        MagicMakerForegroundService.transmit(ctx.context, current)
    }

    /** USE IN HEX FIELD (the builder's onHexBuilt). */
    private fun useBuilt(ctx: VFDContext) {
        val ext: Boolean = extendedOn(labUI(ctx))
        val st: LabState = resolve(ctx)
        val current: String = st.built(ext)
        if (current.isBlank()) return
        st.hex = current
        st.preview = current
        ctx.store.saveLabHex(current)
        saveState(ctx, st)
    }

    /** LOAD HEX: decode the hex field into the builder. */
    private fun loadFromHexField(ctx: VFDContext) {
        userEdit(ctx) { st ->
            if (!decodeInto(st, st.hex, "hex field")) {
                st.loadMsg = "Hex field is empty"
            }
        }
    }

    /** Typing in the hex field also drives the preview. */
    private fun setHexField(ctx: VFDContext, typed: String) {
        val st: LabState = resolve(ctx)
        st.hex = typed.uppercase()
        st.preview = st.hex
        saveState(ctx, st)
    }

    private fun setLabelField(ctx: VFDContext, typed: String) {
        val st: LabState = resolve(ctx)
        st.label = typed
        saveState(ctx, st)
    }

    /** PacketInspector's onHexChange: the hex field and the store, not the preview. */
    private fun inspectorEdited(ctx: VFDContext, edited: String) {
        val st: LabState = resolve(ctx)
        st.hex = edited
        ctx.store.saveLabHex(edited)
        saveState(ctx, st)
    }

    private fun stepVibration(ctx: VFDContext, delta: Int) {
        val st: LabState = resolve(ctx)
        val vib: Int = LabPacketTools.tailVibration(st.hex) ?: return
        val next: Int = minOf(maxOf(vib + delta, 0), 15)
        inspectorEdited(ctx, LabPacketTools.withVibration(st.hex, next))
    }

    /** One byte typed over: hex digits only, uppercased, at most two; the whole hex is rebuilt
     *  from the grid (the byte cell's onValueChange). */
    private fun editByte(ctx: VFDContext, index: Int, typed: String) {
        val st: LabState = resolve(ctx)
        val bytes: MutableList<String> = LabPacketTools.toBytes(st.hex).toMutableList()
        if (index < 0 || index >= bytes.size) return
        val cleaned: String = typed.uppercase().filter { it in "0123456789ABCDEF" }.take(2)
        if (cleaned == bytes[index]) return
        bytes[index] = cleaned
        inspectorEdited(ctx, LabPacketTools.fromBytes(bytes))
    }

    private fun promptByte(ctx: VFDContext, index: Int, value: String, count: Int) {
        ctx.prompt("BYTE ${index + 1} OF $count", text = value, keyboard = VFDKeyboard.hex) { typed ->
            editByte(ctx, index, typed)
        }
    }

    private fun toggleSegment(ctx: VFDContext, index: Int, built: String) {
        val ui: VFDUIState = labUI(ctx)
        val current: Int? = selectedSegment(ui, built)
        ui.setString(Keys.segmentHex, built)
        ui.setInt(Keys.segment, if (current == index) -1 else index)
    }

    /** The tapped anatomy block, while the packet it belongs to is still the builder's
     *  (remember(hex) in PacketAnatomy). */
    private fun selectedSegment(ui: VFDUIState, built: String): Int? {
        if (ui.string(Keys.segmentHex) != built) return null
        val v: Int = ui.int(Keys.segment, -1)
        return if (v >= 0) v else null
    }

    // MARK: SEND / SAVE / TAG, presets

    private fun sendPacket(ctx: VFDContext) {
        val st: LabState = resolve(ctx)
        ctx.store.saveLabHex(st.hex)
        ctx.store.saveLabLabel(st.label)
        MagicMakerForegroundService.transmit(ctx.context, st.hex)
    }

    private fun savePreset(ctx: VFDContext) {
        val st: LabState = resolve(ctx)
        ctx.store.saveLabHex(st.hex)
        ctx.store.saveLabLabel(st.label)
        val err: String? = ctx.store.saveCustomPreset(st.label, st.hex)
        st.presetMsg = err ?: savedMsg
        saveState(ctx, st)
    }

    private fun tagRaw(ctx: VFDContext) {
        val st: LabState = resolve(ctx)
        ctx.store.saveLabHex(st.hex)
        ctx.store.saveLabLabel(st.label)
        ctx.store.applyLabLabelToMatchingRaw()
        st.presetMsg = "Raw tag updated"
        saveState(ctx, st)
    }

    /** A preset row's tap: its hex and label into the fields and the store. */
    private fun loadPreset(ctx: VFDContext, preset: MagicPacket) {
        val st: LabState = resolve(ctx)
        st.hex = preset.hex
        st.label = preset.label
        ctx.store.saveLabHex(preset.hex)
        ctx.store.saveLabLabel(preset.label)
        saveState(ctx, st)
    }

    /** The bin: "Delete preset?" with the label and hex, DELETE / CANCEL, then deleteCustomPreset
     *  and "Preset deleted". */
    private fun askDelete(ctx: VFDContext, preset: MagicPacket) {
        val id: Long = preset.id
        val label: String = preset.label.uppercase()
        val message: String = when {
            preset.hex.isEmpty() -> label
            label.isEmpty() -> preset.hex
            else -> label + "\n" + preset.hex
        }
        ctx.confirm("Delete preset?", message, confirmLabel = "DELETE", destructive = true) {
            ctx.store.deleteCustomPreset(id)
            val st: LabState = resolve(ctx)
            st.presetMsg = "Preset deleted"
            saveState(ctx, st)
        }
    }

    /** HOLD on a preset: its two actions. */
    private fun presetMenu(ctx: VFDContext, preset: MagicPacket) {
        ctx.menu(preset.label, listOf(
            VFDMenuItem("LOAD IN LAB") { loadPreset(ctx, preset) },
            VFDMenuItem("DELETE", destructive = true) { askDelete(ctx, preset) },
        ))
    }

    // MARK: random show

    private fun intervalValue(ctx: VFDContext): Double {
        val ui: VFDUIState = labUI(ctx)
        if (ui.has(Keys.interval)) {
            return ui.double(Keys.interval, 3000.0)
        }
        return ctx.state.randomShowIntervalMs.toDouble()
    }

    /** The INTERVAL slider's onCommit: a new pace applies to a running show at once. */
    private fun commitInterval(ctx: VFDContext, ms: Double) {
        labUI(ctx).setDouble(Keys.interval, ms)
        if (ctx.state.randomShowEnabled) {
            MagicMakerForegroundService.setRandomShow(ctx.context, true, ms.toLong())
        }
    }

    private fun toggleShow(ctx: VFDContext) {
        MagicMakerForegroundService.setRandomShow(ctx.context, enabled = !ctx.state.randomShowEnabled,
                                                  intervalMs = intervalValue(ctx).toLong())
    }

    /** SettingSlider.snap: the nearest multiple of step, kept inside the range. */
    private fun snap(v: Double, low: Double, high: Double, step: Double): Double {
        if (!v.isFinite()) return low
        if (step <= 0) return minOf(maxOf(v, low), high)
        return minOf(maxOf(Math.round(v / step).toDouble() * step, low), high)
    }

    // MARK: pickers

    /** PaletteDropdown's dialog as a VFD menu: one row per option, the current one ticked. */
    private fun openPicker(ctx: VFDContext, title: String, options: List<Pair<Int, String>>, selected: Int,
                           pick: (Int) -> Unit) {
        if (options.isEmpty()) return
        val items: List<VFDMenuItem> = options.map { (id, name) ->
            VFDMenuItem(if (id == selected) "$name ✓" else name) { pick(id) }
        }
        ctx.menu(title.uppercase(), items)
    }

    // MARK: colour names with their swatches

    /** The true colours behind a classifier's colour names: each distinct palette colour that
     *  BandEffectModel reads from [hex] (a wand code's own colour when it reads none) and whose
     *  name is in [names], in the order the names first appear there; at most five, OFF left out. */
    private fun namedSwatches(hex: String, names: String): List<VFDRGB> {
        val text: String = names.lowercase()
        if (text.isBlank()) return emptyList()
        val model: BandEffectModel = VFDColors.bandModel(hex)
        val indices: MutableList<Int> = ArrayList(model.colors)
        for (zone in model.perLed) {
            if (zone != null) indices.add(zone)
        }
        if (indices.isEmpty()) {
            val upperHex: String = hex.uppercase()
            if (upperHex.contains("CF9B") || upperHex.contains("CF0B")) {
                runCatching { MagicClassifier.starlightColorIndex(hex) }.getOrNull()?.let { indices.add(it) }
            }
        }
        val found: MutableList<Triple<Int, Int, VFDRGB>> = ArrayList()
        val seen: MutableSet<Int> = HashSet()
        for (raw in indices) {
            val index: Int = raw and 0x1F
            if (!seen.add(index)) continue
            val name: String = StarlightColors.nameFor(index).lowercase()
            if (name == "off") continue
            val pos: Int = text.indexOf(name)
            if (pos < 0) continue
            found.add(Triple(pos, found.size, VFDColors.labSwatch(index)))
        }
        found.sortWith(compareBy<Triple<Int, Int, VFDRGB>> { it.first }.thenBy { it.second })
        return found.take(5).map { it.third }
    }

    /** [swatches] as 5 x 5 true-colour squares 7 cells apart from column x0 on text row r, then
     *  [names] 2 cells after the last one, cut to end before [limit]; without swatches (or room
     *  for them) just the names at x0. Returns the end column. */
    private fun swatchNames(fb: VFDFrameBuffer, x0: Int, r: Int, swatches: List<VFDRGB>, names: String, limit: Int,
                            color: Int): Int {
        var n: Int = swatches.size
        // Keep room for at least two characters of the names.
        while (n > 0 && x0 + 7 * n + 2 + VFDText.width(count = 2) > limit) {
            n -= 1
        }
        var x: Int = x0
        if (n > 0) {
            for (i in 0 until n) {
                fb.fill(x0 + 7 * i, r + 1, 5, 5, fb.rgb(swatches[i]))
            }
            x = x0 + 7 * n + 2
        }
        return fb.textFit(x, r, names, limit - x, VFDSize.small, color)
    }

    // MARK: - Model

    /** PacketSummaryCard's sentence, details and tone for [hex]. */
    private fun summaryOf(hex: String): LabSummary {
        val canonical: String = HexUtils.canonicalHex(hex)
        val classified: ClassifiedPacket? = runCatching { MagicClassifier.classify(canonical) }.getOrNull()
        val parsed: DisneyTlv.Parsed? = runCatching { DisneyTlv.parse(canonical) }.getOrNull()
        val reject: String? = runCatching { HexUtils.legacyAdvertiseRejectReason(canonical) }.getOrNull()
        val bytes: Int = HexUtils.hexToBytes(canonical).size
        val headline: String = classified?.label ?: parsed?.records?.firstOrNull()?.let { r ->
            if (r.isChannelMarker()) "Channel marker only — no effect" else "Unrecognised packet (type ${r.typeHex()})"
        } ?: "Empty packet"
        val details: MutableList<String> = ArrayList()
        if (parsed != null) {
            if (parsed.records.firstOrNull()?.type == DisneyTlv.TYPE_PING && parsed.effect != null) {
                details.add("wake ping first")
            }
            val ch: DisneyTlv.Record? = parsed.channel
            if (ch != null) {
                details.add("channel ${ch.type - DisneyTlv.TYPE_CHANNEL_1 + 1}")
            } else if (parsed.effect != null) {
                details.add("no channel marker")
            }
            val e: DisneyTlv.Record? = parsed.effect
            if (e != null) {
                val tail: Int? = e.value.lastOrNull()?.toInt()?.and(0xFF)
                if (tail != null && (tail and 0xF0) == 0xB0) {
                    val vib: Int = tail and 0x0F
                    val name: String = LabPacketBuilder.vibrationPatterns.firstOrNull { it.id == vib }?.label ?: "#$vib"
                    details.add(if (vib == 0) "no buzz" else "buzz " + name.lowercase())
                }
            }
            if (!parsed.exact) details.add("MALFORMED")
        }
        details.add("$bytes bytes")
        details.add(if (reject == null) "fits in BLE" else "TOO LONG")
        val tone: Int = when {
            reject != null || parsed?.exact == false -> 2
            classified != null -> 0
            else -> 1
        }
        return LabSummary(headline, classified?.colors.orEmpty(), details, reject, tone)
    }

    private fun builtInfo(hex: String): BuiltInfo {
        val summary: LabSummary = summaryOf(hex)
        val swatches: List<VFDRGB> = if (summary.colors.isNotBlank()) namedSwatches(hex, summary.colors) else emptyList()
        val segments: List<DisneyTlv.Segment> =
            if (hex.isBlank()) emptyList() else runCatching { DisneyTlv.anatomy(hex) }.getOrDefault(emptyList())
        val slots: List<LabPacketBuilder.ColorSlot> =
            runCatching { LabPacketBuilder.editableSlots(hex) }.getOrDefault(emptyList())
        val values: List<Int> = runCatching { LabPacketBuilder.slotColors(hex) }.getOrDefault(emptyList())
        val sendable: Boolean = hex.isNotBlank() &&
            runCatching { HexUtils.legacyAdvertiseRejectReason(hex) }.getOrNull() == null
        return BuiltInfo(summary, swatches, segments, slots, values, sendable)
    }

    private fun hexInfo(hex: String): HexInfo {
        val classified: ClassifiedPacket? =
            runCatching { MagicClassifier.classify(HexUtils.canonicalHex(hex)) }.getOrNull()
        val colors: String = classified?.colors.orEmpty()
        val swatches: List<VFDRGB> = if (colors.isNotBlank()) namedSwatches(hex, colors) else emptyList()
        return HexInfo(
            classified = classified,
            swatches = swatches,
            bytes = LabPacketTools.toBytes(hex),
            reject = runCatching { HexUtils.legacyAdvertiseRejectReason(hex) }.getOrNull(),
            vibration = LabPacketTools.tailVibration(hex),
        )
    }

    private fun makeModel(ctx: VFDContext): LabModel {
        val ui: VFDUIState = labUI(ctx)
        val st: LabState = resolve(ctx)
        val extended: Boolean = extendedOn(ui)
        val built: String = st.built(extended)
        val bInfo: BuiltInfo = ctx.cached("lab.built", built) { builtInfo(built) }
        val hInfo: HexInfo = ctx.cached("lab.hex", st.hex) { hexInfo(st.hex) }
        val presets: List<MagicPacket> = ctx.cached("lab.presets", ctx.state.storeRevision) {
            ctx.store.customPresets.sortedBy { it.label.lowercase() }
        }
        val interval: Double = intervalValue(ctx)
        return LabModel(
            ui = ui,
            state = st,
            built = built,
            extended = extended,
            builtInfo = bInfo,
            hexInfo = hInfo,
            selectedSegment = selectedSegment(ui, built),
            presets = presets,
            pingHex = ui.string(Keys.ping, PacketBuilder.WAKEUP_PING),
            inspectorOpen = ui.bool(Keys.inspector),
            intervalMs = interval,
            intervalDragging = ui.bool(Keys.intervalDrag),
            intervalDraft = ui.double(Keys.intervalDraft, interval),
        )
    }

    // MARK: - Pinned band preview

    /** BandPreview: the face on the left with its LEDs in true colour at ctx.time, the text column
     *  beside it (the shorter of the two centred on the other), then the divider. Returns the
     *  divider row. */
    private fun bandPreview(ctx: VFDContext, fb: VFDFrameBuffer, c: Int, y: Int, w: Int, hex: String): Int {
        val model: BandEffectModel = VFDColors.bandModel(hex)
        val tx: Int = c + FACE + 8
        val tw: Int = c + w - tx
        val lines: List<LabLine> = previewLines(model, tw, ctx.time)
        val textH: Int = (lines.size - 1) * VFDW.line + 7
        val top: Int = y + 1
        val faceTop: Int = top + maxOf(0, VFDMath.floorDiv(textH - FACE, 2))
        val textTop: Int = top + maxOf(0, VFDMath.floorDiv(FACE - textH, 2))
        bandFace(fb, c, faceTop, model, ctx.time)
        if (animates(model)) {
            fb.wantsAnimation = true
        }
        var r: Int = textTop
        for (line in lines) {
            if (line.isLegend) {
                drawLegend(fb, line.legend, tx, r, tw)
            } else {
                fb.textFit(tx, r, line.text, tw, VFDSize.small, line.color)
            }
            r += VFDW.line
        }
        val bottom: Int = top + maxOf(textH, FACE)
        val div: Int = bottom + 3
        fb.hline(c, div, w, VFDInk.dim)
        return div
    }

    /** BandPreview's text column (non-compact) plus the colour legend. */
    private fun previewLines(model: BandEffectModel, tw: Int, time: Double): List<LabLine> {
        val out: MutableList<LabLine> = ArrayList()
        out.add(LabLine("BAND PREVIEW", VFDInk.dim, emptyList(), false))
        val none: Boolean = model.kind == BandEffectModel.Kind.NONE
        if (none) {
            out.add(LabLine("NO EFFECT", VFDInk.dim, emptyList(), false))
        } else {
            out.add(LabLine(model.kind.name.replace('_', ' '), VFDInk.highlight, emptyList(), false))
        }
        val noteText: String = VFDW.upper(model.note) + (if (model.approximate) " · APPROX." else "")
        val noteColor: Int = if (model.approximate) VFDInk.text else VFDInk.dim
        for (ln in wrapLines(noteText, tw, maxLines = 2)) {
            out.add(LabLine(ln, noteColor, emptyList(), false))
        }
        if (model.durationMs > 0 || model.alwaysOn) {
            val dur: String = if (model.alwaysOn) {
                "ALWAYS ON"
            } else {
                "~${model.durationMs / 1000}S" + (if (model.fadeMs > 0) " · ${model.fadeMs / 1000}S FADE" else "")
            }
            out.add(LabLine(dur, VFDInk.dim, emptyList(), false))
        }
        if (model.buzz > 0) {
            val name: String = LabPacketBuilder.vibrationPatterns.firstOrNull { it.id == model.buzz }?.label
                ?: "#${model.buzz}"
            val on: Boolean = VFDColors.buzzOn(time)
            out.add(LabLine("BUZZ · " + VFDW.upper(name), if (on) VFDInk.highlight else VFDInk.dim, emptyList(), false))
        }
        if (!none && model.kind != BandEffectModel.Kind.PING) {
            val items: List<LabLegend> = legend(model)
            if (items.isNotEmpty()) {
                out.add(LabLine("", VFDInk.text, items, true))
            }
        }
        return out
    }

    /** Whether the preview changes over time (BandLedAnimation moves the LEDs, or BUZZ blinks). */
    private fun animates(model: BandEffectModel): Boolean {
        if (model.buzz > 0) return true
        return when (model.kind) {
            BandEffectModel.Kind.NONE, BandEffectModel.Kind.PING, BandEffectModel.Kind.DUAL -> false
            BandEffectModel.Kind.RAINBOW -> model.approximate && model.colors.size == 5 &&
                model.perLed.all { it != null } && model.note.contains("cycle")
            BandEffectModel.Kind.STEPPER -> model.colors.size > 1
            else -> true
        }
    }

    /** The band's square face (dim, rounded corners) with its five round LED zones in their true
     *  colour at [time]; an off zone is a dotted dim ring. */
    private fun bandFace(fb: VFDFrameBuffer, x: Int, y: Int, model: BandEffectModel, time: Double) {
        val e: Int = FACE - 1
        fb.hline(x + 4, y, FACE - 8, VFDInk.dim)
        fb.hline(x + 4, y + e, FACE - 8, VFDInk.dim)
        fb.vline(x, y + 4, FACE - 8, VFDInk.dim)
        fb.vline(x + e, y + 4, FACE - 8, VFDInk.dim)
        for ((dx, dy) in listOf(2 to 1, 3 to 1, 1 to 2, 1 to 3)) {
            fb.set(x + dx, y + dy, VFDInk.dim)
            fb.set(x + e - dx, y + dy, VFDInk.dim)
            fb.set(x + dx, y + e - dy, VFDInk.dim)
            fb.set(x + e - dx, y + e - dy, VFDInk.dim)
        }
        for ((z, spot) in ZONE_SPOT.withIndex()) {
            val lx: Int = x + LED_AT[spot.first]
            val ly: Int = y + LED_AT[spot.second]
            val rgb: VFDRGB? = VFDColors.bandLED(model, z, time)
            if (rgb != null) {
                VFDW.led(fb, lx, ly, 0, size = LED, fill = rgb)
            } else {
                VFDW.led(fb, lx, ly, null, size = LED)
            }
        }
    }

    /** The colour names of Z1..Z5 (palette names, first-appearance order) with their true colour,
     *  then OFF when a zone is unlit. A custom RGB effect names its #RRGGBB. */
    private fun legend(model: BandEffectModel): List<LabLegend> {
        if (model.kind == BandEffectModel.Kind.RGB) {
            val rgb: VFDRGB = VFDColors.rgb(model.rgb ?: 0x9E9E9E)
            return listOf(LabLegend(rgb, rgb.hex))
        }
        val out: MutableList<LabLegend> = ArrayList()
        val seen: MutableSet<String> = HashSet()
        var anyOff = false
        for (z in 0 until 5) {
            val idx: Int? = model.perLed.getOrNull(z)
            if (idx == null) {
                anyOff = true
                continue
            }
            val name: String = StarlightColors.nameFor(idx)
            if (name.lowercase() == "off") {
                anyOff = true
                continue
            }
            val key: String = VFDW.upper(name)
            if (!seen.add(key)) continue
            out.add(LabLegend(VFDColors.labSwatch(idx), key))
        }
        if (anyOff) {
            out.add(LabLegend(null, "OFF"))
        }
        return out
    }

    private fun swatchLED(fb: VFDFrameBuffer, x: Int, y: Int, rgb: VFDRGB?) {
        if (rgb != null) {
            VFDW.led(fb, x, y, 0, size = SWATCH, fill = rgb)
        } else {
            VFDW.led(fb, x, y, null, size = SWATCH)
        }
    }

    /** Swatch + colour name, as many as fit in [tx, tx + tw). */
    private fun drawLegend(fb: VFDFrameBuffer, items: List<LabLegend>, tx: Int, r: Int, tw: Int) {
        val limit: Int = tx + tw
        var x: Int = tx
        for (item in items) {
            val need: Int = SWATCH + 3 + VFDText.width(item.name)
            if (x + need > limit) {
                val short: String = item.name.take(1) + VFDText.ellipsis
                if (x + SWATCH + 3 + VFDText.width(short) <= limit) {
                    swatchLED(fb, x, r, item.rgb)
                    fb.textFit(x + SWATCH + 3, r, item.name, limit - x - SWATCH - 3, VFDSize.small, VFDInk.text)
                }
                break
            }
            swatchLED(fb, x, r, item.rgb)
            val color: Int = if (item.rgb == null) VFDInk.dim else VFDInk.text
            x = fb.text(x + SWATCH + 3, r, item.name, VFDSize.small, color) + 6
        }
    }

    // MARK: - Scrolling body

    /** Scratch buffer for the probe pass (reused; main thread only). */
    private var scratch: VFDFrameBuffer? = null

    private fun scratchBuffer(fb: VFDFrameBuffer): VFDFrameBuffer {
        val b: VFDFrameBuffer? = scratch
        val buf: VFDFrameBuffer = if (b != null && b.cols == fb.cols && b.rows == fb.rows) {
            b.reset()
            b
        } else {
            VFDFrameBuffer(fb.cols, fb.rows).also { scratch = it }
        }
        buf.alarmInverted = fb.alarmInverted
        buf.base = fb.base
        return buf
    }

    /** The body in screen rows [top, top + view), scrolled by its own region, a line cut by either
     *  edge hidden (lab.py snapped_window), the taps the edges cut dropped, its scroll indicator. */
    private fun bodyWindow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                           view: Int, w: Int) {
        val y0: Int = top + 4
        var off: Int = maxOf(0, ctx.scroll(Keys.region))
        val probe: VFDFrameBuffer = scratchBuffer(fb)
        var end: Int = probeBody(ctx, probe, fb, L, m, c, y0, w, off)
        val total: Int = end - top
        val limit: Int = maxOf(0, total - view)
        if (off > limit) {
            off = limit
            scratchBuffer(fb)
            end = probeBody(ctx, probe, fb, L, m, c, y0, w, off)
        }
        val win: VFDWindow = snapWindow(probe, top, top + view)
        fb.pushClip(0, top, fb.cols, view, dy = -off)
        fb.pushClip(0, win.top - fb.originY, fb.cols, maxOf(0, win.bottom - win.top))
        val firstTap: Int = fb.taps.size
        body(ctx, fb, L, m, c, y0, w)
        fb.popClip()
        fb.popClip()
        dropShortTaps(fb, firstTap)
        registerRegion(fb, Keys.region, top, view, limit)
        VFDW.listScrollbar(fb, top, view, total, off)
    }

    /** The body drawn unclipped on the scratch buffer scrolled by [off]. Returns the end row. */
    private fun probeBody(ctx: VFDContext, buf: VFDFrameBuffer, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel,
                          c: Int, y0: Int, w: Int, off: Int): Int {
        buf.pushClip(0, 0, fb.cols, fb.rows, dy = fb.originY - off)
        val end: Int = body(ctx, buf, L, m, c, y0, w)
        while (buf.clipDepth > 0) {
            buf.popClip()
        }
        return end
    }

    /** Rows (top, bottom) the body may use: while some column is lit on both sides of an edge (a
     *  glyph stroke, a control's side; runs of 40 rows or more excepted) the edge moves inward. */
    private fun snapWindow(probe: VFDFrameBuffer, top: Int, bottom: Int): VFDWindow {
        val cols: Int = probe.cols
        val rows: Int = probe.rows
        val cells: ByteArray = probe.cells
        fun lit(x: Int, r: Int): Boolean = r in 0 until rows && cells[r * cols + x].toInt() != 0
        fun run(x: Int, r: Int): Int {
            var a: Int = r
            while (lit(x, a - 1)) a -= 1
            var b: Int = r
            while (lit(x, b + 1)) b += 1
            return b - a + 1
        }
        fun crossed(k: Int): Boolean {
            for (x in 0 until cols) {
                if (lit(x, k - 1) && lit(x, k) && run(x, k) < 40) return true
            }
            return false
        }
        var t: Int = top
        var b: Int = bottom
        while (t < b && crossed(t)) t += 1
        while (b > t && crossed(b)) b -= 1
        return VFDWindow(t, b)
    }

    private fun dropShortTaps(fb: VFDFrameBuffer, from: Int) {
        val taps: MutableList<VFDHit> = fb.taps
        var i: Int = taps.size - 1
        while (i >= from) {
            if (taps[i].h < VFDW.tapRows) {
                taps.removeAt(i)
            }
            i -= 1
        }
    }

    /** A scroll region over screen rows [top, top + h) whose drag limit is [limit] rows, even when
     *  the page window cuts the region shorter. Nothing when it cannot scroll. */
    private fun registerRegion(fb: VFDFrameBuffer, id: String, top: Int, h: Int, limit: Int) {
        val clip: VFDRect = fb.clipRect
        val oy: Int = fb.originY
        val r0: Int = maxOf(top + oy, clip.r)
        val r1: Int = minOf(top + h + oy, clip.r + clip.h)
        val shown: Int = maxOf(0, r1 - r0)
        if (shown <= 0 || limit <= 0) return
        fb.scrollRegion(id, 0, top, fb.cols, h, limit + shown)
    }

    /** Whether rows [r, r + h) (drawing rows) reach the current clip. */
    private fun rowVisible(fb: VFDFrameBuffer, r: Int, h: Int): Boolean {
        val clip: VFDRect = fb.clipRect
        val t: Int = r + fb.originY
        return t + h > clip.r && t < clip.r + clip.h
    }

    /** Everything in the Lab's scrolling column. Returns the next free row. */
    private fun body(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, y: Int, w: Int): Int {
        var r: Int = builderGroup(ctx, fb, L, m, c, y, w)
        r = editGroup(ctx, fb, L, m, c, r, w)
        return extrasGroup(ctx, fb, L, m, c, r, w)
    }

    // MARK: - Pieces

    /** A solid dim rule with 3 empty rows each side (the HorizontalDivider). Returns the next
     *  row. */
    private fun hairline(fb: VFDFrameBuffer, c: Int, y: Int, w: Int): Int {
        fb.hline(c, y + 3, w, VFDInk.dim)
        return y + 7
    }

    /** Text lines `line` rows apart. Returns the row after the last line (+ gap). */
    private fun linesBlock(fb: VFDFrameBuffer, c: Int, y: Int, lines: List<String>, color: Int): Int {
        var r: Int = y
        for (ln in lines) {
            fb.text(c, r, ln, VFDSize.small, color)
            r += VFDW.line
        }
        return if (lines.isEmpty()) r else r + VFDW.gap
    }

    /** techLabel text wrapped full width, as given. Returns the next free row. */
    private fun note(fb: VFDFrameBuffer, c: Int, y: Int, w: Int, s: String, color: Int = VFDInk.dim): Int {
        return linesBlock(fb, c, y, wrap(s, w), color)
    }

    /** An up and a down triangle beside small caps at row r: 5 x 7 cells. */
    private fun updown(fb: VFDFrameBuffer, c: Int, r: Int, color: Int) {
        for (i in 0 until 3) {
            fb.hline(c + 2 - i, r + i, 1 + 2 * i, color)
            fb.hline(c + 2 - i, r + 6 - i, 1 + 2 * i, color)
        }
    }

    private fun trash(fb: VFDFrameBuffer, c: Int, r: Int, color: Int) {
        for ((j, row) in TRASH.withIndex()) {
            for ((i, ch) in row.withIndex()) {
                if (ch == '#') fb.set(c + i, r + j, color)
            }
        }
    }

    /** PaletteDropdown at (x, y): a dim-bordered button "LABEL: VALUE" in highlight (a palette value
     *  with its true-colour swatch first) and a dim up/down chevron, hugging its text; a tap opens
     *  the options. Returns the end column. */
    private fun pickerAt(fb: VFDFrameBuffer, x: Int, y: Int, maxW: Int, label: String, value: String,
                         action: () -> Unit): Int {
        val swatch: VFDRGB? = optionSwatch(value)
        val sw: Int = if (swatch != null) 9 else 0
        val s: String = VFDText.fit(VFDW.upper(label) + ": " + VFDW.upper(value), maxW - 21 - sw)
        val bw: Int = 6 + sw + VFDText.width(s) + 4 + 5 + 6
        fb.box(x, y, bw, VFDW.ctrlH, VFDInk.dim)
        if (swatch != null) {
            fb.fill(x + 6, y + VFDW.ctrlText + 1, 5, 5, fb.rgb(swatch))
        }
        val end: Int = fb.text(x + 6 + sw, y + VFDW.ctrlText, s, VFDSize.small, VFDInk.highlight)
        updown(fb, end + 3, y + VFDW.ctrlText, VFDInk.dim)
        VFDW.tap(fb, x, y, bw, VFDW.ctrlH, "picker:" + VFDW.upper(label), action = action)
        return x + bw
    }

    /** A picker on its own row. Returns the next free row. */
    private fun pickerRow(fb: VFDFrameBuffer, c: Int, y: Int, w: Int, label: String, value: String,
                          action: () -> Unit): Int {
        pickerAt(fb, c, y, w, label, value, action)
        return y + VFDW.ctrlH + VFDW.gap
    }

    /** A Lab switch row: the title with the ON/OFF switch on the right, the description wrapped
     *  full width under it in dim. Returns the next free row. */
    private fun toggleBlock(fb: VFDFrameBuffer, L: VFDLayout, c: Int, y: Int, w: Int, title: String, on: Boolean,
                            detail: String, titleColor: Int, action: () -> Unit): Int {
        var r: Int = VFDW.toggle(fb, L, c, y, w, title, on, name = "toggle:" + VFDW.upper(title),
                                 labelColor = titleColor, action = action)
        r -= VFDW.gap - 1
        return linesBlock(fb, c, r, wrap(detail, w), VFDInk.dim)
    }

    /** FramingToggle: the switch first (left), the title beside it, the detail wrapped full width
     *  under them in dim. Returns the next free row. */
    private fun framingToggle(fb: VFDFrameBuffer, L: VFDLayout, c: Int, y: Int, w: Int, title: String, on: Boolean,
                              detail: String, action: () -> Unit): Int {
        val name: String = "toggle:" + VFDW.upper(title)
        VFDW.toggle(fb, L, c, y, VFDW.switchW, "", on, name = name, action = action)
        val tx: Int = c + VFDW.switchW + 6
        val tlines: List<String> = titleLines(VFDW.upper(title), c + w - tx)
        for ((i, ln) in tlines.withIndex()) {
            fb.text(tx, y + VFDW.ctrlText + i * VFDW.line, ln, VFDSize.small, VFDInk.text)
        }
        VFDW.tap(fb, c, y, w, VFDW.ctrlH, name, action = action)
        val r: Int = y + maxOf(VFDW.ctrlH + 1, VFDW.ctrlText + tlines.size * VFDW.line)
        return linesBlock(fb, c, r, wrap(detail, w), VFDInk.dim)
    }

    /** A cyanDim bordered button: dim border, text label. Returns its end column. */
    private fun ghostButton(fb: VFDFrameBuffer, c: Int, y: Int, label: String, action: () -> Unit): Int {
        val s: String = VFDW.upper(label)
        val bw: Int = VFDText.width(s) + 12
        fb.box(c, y, bw, VFDW.ctrlH, VFDInk.dim)
        fb.text(c + 6, y + VFDW.ctrlText, s, VFDSize.small, VFDInk.text)
        VFDW.tap(fb, c, y, bw, VFDW.ctrlH, "button:$s", action = action)
        return c + bw
    }

    /** Anatomy block tone (segmentColor): cyan -> highlight, amber -> text, others dim, red alarm. */
    private fun segmentInk(kind: DisneyTlv.SegmentKind): Int = when (kind) {
        DisneyTlv.SegmentKind.COMPANY -> VFDInk.dim
        DisneyTlv.SegmentKind.CHANNEL -> VFDInk.text
        DisneyTlv.SegmentKind.PING -> VFDInk.text
        DisneyTlv.SegmentKind.EFFECT_HEAD -> VFDInk.highlight
        DisneyTlv.SegmentKind.HEADER -> VFDInk.dim
        DisneyTlv.SegmentKind.COLOR -> VFDInk.highlight
        DisneyTlv.SegmentKind.DATA -> VFDInk.dim
        DisneyTlv.SegmentKind.TAIL -> VFDInk.dim
        DisneyTlv.SegmentKind.WAND -> VFDInk.highlight
        DisneyTlv.SegmentKind.BEACON -> VFDInk.dim
        DisneyTlv.SegmentKind.OTHER -> VFDInk.dim
        DisneyTlv.SegmentKind.ERROR -> VFDInk.alarm
    }

    // MARK: - Builder group

    private fun builderGroup(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                             w: Int): Int {
        var y: Int = modeBar(ctx, fb, L, m, c, top, w)
        y = hairline(fb, c, y - 1, w)
        y = VFDW.section(fb, L, c, y - (VFDW.sectionGap - VFDW.gap) + 3, w, "PACKET BUILDER")
        y = note(fb, c, y, w, builderIntro)
        y = typeSection(ctx, fb, L, m, c, y, w)
        y = summaryCard(fb, m.builtInfo, c, y + 2, w)
        y = typeFields(ctx, fb, L, m, c, y, w)
        if (LabPacketBuilder.framingApplies(m.state.type)) {
            y = framingSection(ctx, fb, L, m, c, y, w)
        }
        if (m.built.isNotBlank()) {
            y = anatomy(ctx, fb, L, m, c, y, w)
        }
        return builderActions(ctx, fb, L, m, c, y + 2, w)
    }

    /** LabModeBar: Standard / Extended, keep-awake, the PING picker. */
    private fun modeBar(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                        w: Int): Int {
        var y: Int = top
        val toggleMode: () -> Unit = { toggleExtended(ctx) }
        y = if (m.extended) {
            toggleBlock(fb, L, c, y, w, "EXTENDED · EXPERIMENTAL", true, extendedDetail, VFDInk.text, toggleMode)
        } else {
            toggleBlock(fb, L, c, y, w, "STANDARD · KNOWN & TESTED", false, standardDetail, VFDInk.highlight,
                        toggleMode)
        }
        val awake: Boolean = ctx.state.keepAwakeActive
        y = toggleBlock(fb, L, c, y, w, "KEEP BAND AWAKE", awake, if (awake) awakeOnDetail else awakeOffDetail,
                        if (awake) VFDInk.highlight else VFDInk.text, action = { toggleKeepAwake(ctx) })
        if (awake || m.extended) {
            val selected: Int = if (m.pingHex == beaconPingHex) 1 else 0
            y = pickerRow(fb, c, y + 1, w, "PING", optionName(pingOptions, selected), action = {
                openPicker(ctx, "PING", pingOptions, selected) { picked -> pickPing(ctx, picked) }
            })
        }
        return y
    }

    /** WHAT DO YOU WANT THE BAND TO DO?, the type chips (wrapping), the blurb, the load message. */
    private fun typeSection(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                            w: Int): Int {
        var y: Int = VFDW.label(fb, L, c, top, w, "WHAT DO YOU WANT THE BAND TO DO?")
        val extended: Boolean = m.extended
        val visible: List<LabPacketBuilder.LabPacketType> =
            LabPacketBuilder.LabPacketType.entries.filter { extended || !it.experimental }
        val selected: Int? = visible.indexOf(m.state.type).takeIf { it >= 0 }
        y = VFDW.options(fb, L, c, y, w, visible.map { it.label }, selected = selected, name = "type",
                         onSelect = { index ->
                             if (index in visible.indices) {
                                 val picked: LabPacketBuilder.LabPacketType = visible[index]
                                 userEdit(ctx) { st -> selectType(st, picked) }
                             }
                         })
        y = note(fb, c, y + 1, w, m.state.type.blurb)
        val msg: String? = m.state.loadMsg
        if (msg != null) {
            y = note(fb, c, y - VFDW.gap, w, msg, VFDInk.highlight)
        }
        return y
    }

    /** PacketSummaryCard: a 1-cell box in the tone colour around YOU ARE BUILDING, the headline
     *  (mid, tone), the colours (after true-colour swatches), the details (wrapped at " · ") and
     *  the reject reason (alarm). */
    private fun summaryCard(fb: VFDFrameBuffer, info: BuiltInfo, c: Int, top: Int, w: Int): Int {
        val s: LabSummary = info.summary
        val tone: Int = when (s.tone) {
            0 -> VFDInk.highlight
            1 -> VFDInk.text
            else -> VFDInk.alarm
        }
        val ic: Int = c + 5
        val iw: Int = w - 10
        val y: Int = top + 1
        var r: Int = y + 4
        fb.text(ic, r, "YOU ARE BUILDING", VFDSize.small, VFDInk.dim)
        r += VFDW.line + 1
        for (ln in midHeadline(VFDW.upper(s.headline), iw - 2)) {
            if (tone == VFDInk.alarm && fb.alarmInverted) {
                fb.fill(ic - 2, r - 2, VFDText.width(ln, VFDSize.mid) + 4, 18, VFDInk.highlight)
                fb.text(ic, r, ln, VFDSize.mid, VFDInk.unlit)
            } else {
                fb.text(ic, r, ln, VFDSize.mid, tone)
            }
            r += 20
        }
        r -= 1
        if (s.colors.isNotBlank()) {
            swatchNames(fb, ic, r, info.summarySwatches, VFDW.upper(s.colors), ic + iw, VFDInk.dim)
            r += VFDW.line
        }
        for (ln in sepLines(s.details.map { VFDW.upper(it) }, iw)) {
            fb.text(ic, r, ln, VFDSize.small, VFDInk.dim)
            r += VFDW.line
        }
        val reject: String? = s.reject
        if (reject != null) {
            for (ln in wrapLines(reject, iw - 4, maxLines = 2)) {
                VFDW.alarmText(fb, ic, r, ln)
                r += VFDW.line
            }
        }
        val bottom: Int = r - VFDW.line + 7 + 4
        val border: Int = when (tone) {
            VFDInk.text -> VFDInk.dim
            VFDInk.alarm -> if (fb.alarmInverted) VFDInk.highlight else VFDInk.alarm
            else -> VFDInk.highlight
        }
        fb.box(c, y, w, bottom - y + 1, border)
        return bottom + 1 + VFDW.gap
    }

    /** The fields of the chosen type (LabPacketBuilderPanel's when (selectedType)). */
    private fun typeFields(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                           w: Int): Int {
        return when (m.state.type) {
            LabPacketBuilder.LabPacketType.RAW -> rawFields(ctx, fb, L, m, c, top, w)
            LabPacketBuilder.LabPacketType.PING -> note(fb, c, VFDW.groupTop(L, top), w, pingFields)
            LabPacketBuilder.LabPacketType.RGB -> {
                val y: Int = rgbFields(ctx, fb, L, m, c, top, w)
                buzzRow(ctx, fb, L, m, c, y + 1, w)
            }
            LabPacketBuilder.LabPacketType.EXPERIMENT -> experimentFields(ctx, fb, L, m, c, top, w)
            LabPacketBuilder.LabPacketType.SHOW -> showFields(ctx, fb, L, m, c, top, w)
            else -> standardFields(ctx, fb, L, m, c, top, w)
        }
    }

    /** LEDS (Extended single colour), the colour slots, the BUZZ row. */
    private fun standardFields(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                               w: Int): Int {
        val st: LabState = m.state
        var y: Int = top
        if (m.extended && st.type == LabPacketBuilder.LabPacketType.PRESET) {
            val mask: Int = st.ledMask
            y = pickerRow(fb, c, VFDW.groupTop(L, y), w, "LEDS", optionName(LED_MASKS, mask), action = {
                openPicker(ctx, "LEDS", LED_MASKS, mask) { picked ->
                    userEdit(ctx) { s -> s.ledMask = picked }
                }
            })
            y = note(fb, c, y + 1, w, ledNote, VFDInk.text)
        }
        val slots: Int = st.type.colorSlots
        if (slots > 0) {
            y = VFDW.label(fb, L, c, y, w, if (slots == 1) "COLOR" else "COLORS")
            for (index in 0 until slots) {
                val current: Int = st.colors.getOrElse(index) { 0 }
                val slotName: String = slotLabel(st.type, index)
                y = pickerRow(fb, c, y, w, slotName, optionName(paletteOptions, current), action = {
                    openPicker(ctx, slotName, paletteOptions, current) { picked ->
                        userEdit(ctx) { s ->
                            val next: MutableList<Int> = s.colors.toMutableList()
                            while (next.size <= index) next.add(0)
                            next[index] = picked
                            s.colors = next
                        }
                    }
                })
            }
        }
        if (st.type.supportsVib) {
            y = buzzRow(ctx, fb, L, m, c, y + 1, w)
        }
        return y
    }

    /** ColorSlots' slot labels. */
    private fun slotLabel(type: LabPacketBuilder.LabPacketType, index: Int): String = when (type) {
        LabPacketBuilder.LabPacketType.DUAL -> if (index == 0) "INNER" else "OUTER"
        LabPacketBuilder.LabPacketType.CROSSFADE -> if (index == 0) "FROM" else "TO"
        LabPacketBuilder.LabPacketType.CIRCLE -> "P${index + 1}"
        LabPacketBuilder.LabPacketType.RAINBOW, LabPacketBuilder.LabPacketType.ROTATE ->
            zoneLabels.getOrElse(index) { "${index + 1}" }
        else -> "${index + 1}"
    }

    /** BUZZ (dim) + switch, then the PATTERN picker while it is on, on one row. */
    private fun buzzRow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, y: Int, w: Int): Int {
        val st: LabState = m.state
        fb.text(c, y + VFDW.ctrlText, "BUZZ", VFDSize.small, VFDInk.dim)
        val sx: Int = c + VFDText.width("BUZZ") + 6
        VFDW.toggle(fb, L, sx, y, VFDW.switchW, "", st.vibEnabled, name = "toggle:BUZZ", action = {
            userEdit(ctx) { s -> s.vibEnabled = !s.vibEnabled }
        })
        if (st.vibEnabled) {
            val px: Int = sx + VFDW.switchW + 6
            val pattern: Int = st.vibPattern
            pickerAt(fb, px, y, c + w - px, "PATTERN", optionName(vibrationOptions, pattern), action = {
                openPicker(ctx, "PATTERN", vibrationOptions, pattern) { picked ->
                    userEdit(ctx) { s -> s.vibPattern = picked }
                }
            })
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /** RAW HEX field and the colour pickers of whatever recolourable bytes it carries. */
    private fun rawFields(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                          w: Int): Int {
        val raw: String = m.state.rawHex
        var y: Int = VFDW.field(fb, L, c, top, w, "RAW HEX (8301…)", raw, placeholder = "RAW HEX (8301…)",
                                name = "field:RAW HEX", valueColor = VFDInk.dim, action = {
                                    ctx.prompt("RAW HEX (8301…)", text = raw, keyboard = VFDKeyboard.hex) { typed ->
                                        userEdit(ctx) { s -> s.rawHex = typed.uppercase() }
                                    }
                                })
        y = slotPickers(ctx, fb, L, m, c, y, w) { s, next -> s.rawHex = LabPacketBuilder.withColors(s.rawHex, next) }
        return y
    }

    /** TEST picker, WATCH FOR, the experiment's colours. */
    private fun experimentFields(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                                 w: Int): Int {
        val index: Int = m.state.showIndex
        val list: List<LabPacketBuilder.Experiment> = LabPacketBuilder.experiments
        val watch: String = (list.getOrNull(index) ?: list.firstOrNull())?.watch ?: ""
        var y: Int = pickerRow(fb, c, VFDW.groupTop(L, top), w, "TEST", optionName(experimentOptions, index), action = {
            openPicker(ctx, "TEST", experimentOptions, index) { picked -> pickShow(ctx, picked) }
        })
        y = note(fb, c, y + 1, w, "WATCH FOR: $watch", VFDInk.text)
        y = slotPickers(ctx, fb, L, m, c, y, w) { s, next -> s.colors = next }
        return y
    }

    /** SHOW picker, its note, the show's colours. */
    private fun showFields(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                           w: Int): Int {
        val index: Int = m.state.showIndex
        var y: Int = pickerRow(fb, c, VFDW.groupTop(L, top), w, "SHOW", optionName(showOptions, index), action = {
            openPicker(ctx, "SHOW", showOptions, index) { picked -> pickShow(ctx, picked) }
        })
        y = note(fb, c, y + 1, w, showNote)
        y = slotPickers(ctx, fb, L, m, c, y, w) { s, next -> s.colors = next }
        return y
    }

    /** Picking a show or an experiment starts from its captured colours. */
    private fun pickShow(ctx: VFDContext, picked: Int) {
        userEdit(ctx) { s ->
            s.showIndex = picked
            s.colors = emptyList()
        }
    }

    /** SlotPickers: COLORS and one palette picker per recolourable byte of the builder's packet,
     *  labelled by where it lands. */
    private fun slotPickers(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                            w: Int, apply: (LabState, List<Int>) -> Unit): Int {
        val slots: List<LabPacketBuilder.ColorSlot> = m.builtInfo.slots
        val values: List<Int> = m.builtInfo.slotValues
        if (slots.isEmpty() || values.size != slots.size) return top
        var y: Int = VFDW.label(fb, L, c, top, w, "COLORS")
        for (index in slots.indices) {
            val current: Int = values[index]
            val slotName: String = slots[index].label
            y = pickerRow(fb, c, y, w, slotName, optionName(paletteOptions, current), action = {
                openPicker(ctx, slotName, paletteOptions, current) { picked ->
                    val next: MutableList<Int> = values.toMutableList()
                    next[index] = picked
                    userEdit(ctx) { s -> apply(s, next) }
                }
            })
        }
        return y
    }

    /** RgbSliders: a true-colour swatch with its R · G · B (#RRGGBB) caption, then RED / GREEN /
     *  BLUE sliders 0-63 (E908 is six bits per channel). */
    private fun rgbFields(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                          w: Int): Int {
        val rgb: List<Int> = rgbChannels(m.state.colors)
        val r8: Int = rgb[0] * 255 / 63
        val g8: Int = rgb[1] * 255 / 63
        val b8: Int = rgb[2] * 255 / 63
        val caption: String = "R %d · G %d · B %d  (#%02X%02X%02X)".format(rgb[0], rgb[1], rgb[2], r8, g8, b8)
        var y: Int = VFDW.groupTop(L, top)
        fb.fill(c, y, 11, 11, fb.rgb(VFDRGB(r8, g8, b8)))
        fb.textFit(c + 11 + 6, y + 2, caption, w - 17, VFDSize.small, VFDInk.dim)
        y += 11 + VFDW.gap
        for (index in 0 until 3) {
            val v: Int = rgb[index]
            val name: String = rgbNames[index]
            y = VFDW.slider(fb, L, c, y, w, name, v.toString(), v / 63.0, name = "slider:$name", canDec = v > 0,
                            canInc = v < 63,
                            onDec = { setChannel(ctx, index, v - 1) },
                            onInc = { setChannel(ctx, index, v + 1) },
                            onSet = { f -> setChannel(ctx, index, (f * 63.0).roundToInt()) })
        }
        return y
    }

    /** Always three channels, each clamped to 0..63. */
    private fun rgbChannels(values: List<Int>): List<Int> = List(3) { minOf(maxOf(values.getOrElse(it) { 0 }, 0), 63) }

    private fun setChannel(ctx: VFDContext, index: Int, value: Int) {
        if (index !in 0..2) return
        userEdit(ctx) { s ->
            val next: MutableList<Int> = rgbChannels(s.colors).toMutableList()
            next[index] = minOf(maxOf(value, 0), 63)
            s.colors = next
        }
    }

    /** FRAMING: channel marker switch, DURATION picker + its note, wake ping switch. */
    private fun framingSection(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                               w: Int): Int {
        val framing: LabPacketBuilder.Framing = m.state.framing
        var y: Int = VFDW.label(fb, L, c, top, w, "FRAMING")
        y = framingToggle(fb, L, c, y, w, channelTitle, framing.channelMarker, channelDetail, action = {
            userEdit(ctx) { s -> s.framing = s.framing.copy(channelMarker = !s.framing.channelMarker) }
        })
        val timing: Int = framing.timing
        y = pickerRow(fb, c, y + 1, w, "DURATION", optionName(PacketBuilder.Timing.options, timing), action = {
            openPicker(ctx, "DURATION", PacketBuilder.Timing.options, timing) { picked ->
                userEdit(ctx) { s -> s.framing = s.framing.copy(timing = picked) }
            }
        })
        y = note(fb, c, y + 1, w, durationNote)
        y = framingToggle(fb, L, c, y + 1, w, wakeTitle, framing.wakePrefix, wakeDetail, action = {
            userEdit(ctx) { s -> s.framing = s.framing.copy(wakePrefix = !s.framing.wakePrefix) }
        })
        return y
    }

    /** PACKET ANATOMY — TAP A BLOCK: the blocks flowing left to right (a colour block with its
     *  true-colour swatch and colour name), then the selected block's explanation. */
    private fun anatomy(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                        w: Int): Int {
        val segments: List<DisneyTlv.Segment> = m.builtInfo.segments
        val built: String = m.built
        var y: Int = VFDW.label(fb, L, c, top, w, "PACKET ANATOMY — TAP A BLOCK")
        var x: Int = c
        var row: Int = y
        for ((i, seg) in segments.withIndex()) {
            val first: String = seg.hex.ifEmpty { "!" }
            var extra = ""
            var swatch: VFDRGB? = null
            if (seg.kind == DisneyTlv.SegmentKind.COLOR) {
                val idx: Int = (seg.hex.toIntOrNull(16) ?: 0) and 0x1F
                extra = VFDW.upper(StarlightColors.nameFor(idx))
                swatch = VFDColors.labSwatch(idx)
            }
            val sw: Int = if (swatch != null) 8 else 0
            val line1: String = if (extra.isEmpty()) first else "$first $extra"
            val title: String = VFDW.upper(seg.title)
            val inner: Int = minOf(maxOf(sw + VFDText.width(line1), VFDText.width(title)), w - 8)
            val bw: Int = inner + 8
            if (x > c && x + bw > c + w) {
                x = c
                row += CHIP_H + 4
            }
            val tone: Int = segmentInk(seg.kind)
            val selected: Boolean = m.selectedSegment == i
            val t1: Int = row + 3
            val t2: Int = row + 13
            val tx: Int = x + 4 + sw
            val tInner: Int = inner - sw
            if (rowVisible(fb, row, CHIP_H)) {
                if (selected) {
                    fb.fill(x, row, bw, CHIP_H, VFDInk.highlight)
                    if (swatch != null) {
                        fb.fill(x + 3, t1, 7, 7, VFDInk.unlit)
                        fb.fill(x + 4, t1 + 1, 5, 5, fb.rgb(swatch))
                    }
                    fb.textFit(tx, t1, line1, tInner, VFDSize.small, VFDInk.unlit)
                    fb.textFit(x + 4, t2, title, inner, VFDSize.small, VFDInk.unlit)
                } else {
                    fb.box(x, row, bw, CHIP_H, VFDInk.dim)
                    if (swatch != null) {
                        fb.fill(x + 4, t1 + 1, 5, 5, fb.rgb(swatch))
                    }
                    if (tone == VFDInk.alarm) {
                        VFDW.alarmText(fb, tx, t1, VFDText.fit(line1, tInner))
                    } else {
                        val end: Int = fb.textFit(tx, t1, first, tInner, VFDSize.small, tone)
                        if (extra.isNotEmpty()) {
                            fb.textFit(end + ADV, t1, extra, tx + tInner - end - ADV, VFDSize.small, VFDInk.text)
                        }
                    }
                    fb.textFit(x + 4, t2, title, inner, VFDSize.small, VFDInk.dim)
                }
                val index: Int = i
                VFDW.tap(fb, x, row, bw, CHIP_H, "anatomy:$i", action = { toggleSegment(ctx, index, built) })
            }
            x += bw + 4
        }
        y = row + CHIP_H + VFDW.gap
        val sel: Int? = m.selectedSegment
        if (sel != null && sel in segments.indices) {
            val seg: DisneyTlv.Segment = segments[sel]
            val tone: Int = segmentInk(seg.kind)
            val lines: List<String> = wrap(seg.detail, w - 8)
            if (lines.isNotEmpty()) {
                val h: Int = 4 + (lines.size - 1) * VFDW.line + 7 + 4
                y += 2
                fb.box(c, y, w, h, VFDInk.dim)
                var r: Int = y + 4
                for (ln in lines) {
                    if (tone == VFDInk.alarm) {
                        VFDW.alarmText(fb, c + 4, r, ln)
                    } else {
                        fb.text(c + 4, r, ln, VFDSize.small, tone)
                    }
                    r += VFDW.line
                }
                y += h + VFDW.gap
            }
        }
        return y
    }

    /** SEND NOW (primary; only a packet that fits a BLE advertisement), USE IN HEX FIELD
     *  (bordered, cyan) and LOAD HEX (bordered, cyanDim), sized to their labels, flowing onto a
     *  second row when they do not fit one. */
    private fun builderActions(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                               w: Int): Int {
        val labels: List<String> = listOf("SEND NOW", "USE IN HEX FIELD", "LOAD HEX")
        var x: Int = c
        var row: Int = top
        for ((i, lab) in labels.withIndex()) {
            val bw: Int = VFDText.width(lab) + 12
            if (x > c && x + bw > c + w) {
                x = c
                row += VFDW.ctrlH + VFDW.gap
            }
            when (i) {
                0 -> VFDW.button(fb, L, x, row, bw, lab, primary = true, enabled = m.builtInfo.sendable,
                                 action = { sendBuilt(ctx) })
                1 -> VFDW.button(fb, L, x, row, bw, lab, enabled = m.built.isNotBlank(), action = { useBuilt(ctx) })
                else -> ghostButton(fb, x, row, lab, action = { loadFromHexField(ctx) })
            }
            x += bw + 4
        }
        return row + VFDW.ctrlH + VFDW.gap
    }

    // MARK: - Edit group

    private fun editGroup(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                          w: Int): Int {
        var y: Int = hairline(fb, c, top, w)
        y = packetFields(ctx, fb, L, m, c, y, w)
        y = inspector(ctx, fb, L, m, c, y, w)
        return actionSection(ctx, fb, L, m, c, y + 2, w)
    }

    /** HEX OUTPUT (value in dim), LABEL and, under them, the hex's BLE advertising reject reason. */
    private fun packetFields(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                             w: Int): Int {
        val hex: String = m.state.hex
        val label: String = m.state.label
        var y: Int = VFDW.field(fb, L, c, top, w, "HEX OUTPUT", hex, placeholder = "HEX (8301…)",
                                name = "field:HEX OUTPUT", valueColor = VFDInk.dim, action = {
                                    ctx.prompt("HEX OUTPUT", text = hex, keyboard = VFDKeyboard.hex) { typed ->
                                        setHexField(ctx, typed)
                                    }
                                })
        y = VFDW.field(fb, L, c, y, w, "LABEL", label, placeholder = "LABEL", name = "field:LABEL", action = {
            ctx.prompt("LABEL", text = label, keyboard = VFDKeyboard.text) { typed -> setLabelField(ctx, typed) }
        })
        val reason: String? = m.hexInfo.reject
        if (reason != null) {
            y += 2
            for (ln in wrapLines(reason, w - 4, maxLines = 2)) {
                VFDW.alarmText(fb, c, y, ln)
                y += VFDW.line
            }
        }
        return y
    }

    /** PacketInspector: the header line, classification and colours; open: the VIBRATION stepper,
     *  RAW BYTES — tap to edit, the byte grid, the hint. */
    private fun inspector(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                          w: Int): Int {
        val info: HexInfo = m.hexInfo
        val data: List<String> = info.bytes
        val isOpen: Boolean = m.inspectorOpen
        val ui: VFDUIState = m.ui
        var y: Int = top + 3
        val r: Int = y + VFDW.ctrlText
        if (isOpen) {
            VFDW.chevronUp(fb, c, r, VFDInk.dim)
        } else {
            VFDW.chevron(fb, c, r, false, VFDInk.dim)
        }
        val cnt: String = "${data.size} B"
        fb.textRight(c + w - 1, r, cnt, VFDSize.small, VFDInk.dim)
        fb.textFit(c + 11, r, "PACKET INSPECTOR", w - 11 - VFDText.width(cnt) - 6, VFDSize.small, VFDInk.highlight)
        VFDW.tap(fb, c, y, w, VFDW.ctrlH, "inspector", action = { ui.toggleBool(Keys.inspector) })
        y += VFDW.ctrlH
        val classified: ClassifiedPacket? = info.classified
        if (classified != null) {
            val text: String = classified.label + " · " + classified.category.name
            y = linesBlock(fb, c, y, wrapLines(text, w, maxLines = 2), VFDInk.highlight) - VFDW.gap
            if (classified.colors.isNotBlank()) {
                val names: String = classified.colors.uppercase()
                if (info.swatches.isEmpty()) {
                    y = linesBlock(fb, c, y, listOf(VFDText.fit("COLORS: $names", w)), VFDInk.dim) - VFDW.gap
                } else {
                    // "COLORS:", the colours' true-colour swatches, then their names.
                    val x0: Int = fb.text(c, y, "COLORS: ", VFDSize.small, VFDInk.dim)
                    swatchNames(fb, x0, y, info.swatches, names, c + w, VFDInk.dim)
                    y += VFDW.line
                }
            }
        } else {
            y = linesBlock(fb, c, y, listOf("Unclassified / raw payload"), VFDInk.dim) - VFDW.gap
        }
        y += VFDW.gap
        if (!isOpen) return y
        val vib: Int? = info.vibration
        if (vib != null) {
            y += 1
            fb.text(c, y + VFDW.ctrlText, "VIBRATION", VFDSize.small, VFDInk.dim)
            var x: Int = c + VFDText.width("VIBRATION") + 8
            VFDW.stepButton(fb, x, y, false, vib > 0, "vibration:-", action = { stepVibration(ctx, -1) })
            x += VFDW.stepW
            val v: String = vib.toString().padStart(2, '0')
            fb.text(x + 4, y + VFDW.ctrlText, v, VFDSize.small, VFDInk.highlight)
            x += VFDText.width(v) + 8
            VFDW.stepButton(fb, x, y, true, vib < 15, "vibration:+", action = { stepVibration(ctx, 1) })
            x += VFDW.stepW + 8
            fb.textFit(x, y + VFDW.ctrlText, "0xB0 | vib", c + w - x, VFDSize.small, VFDInk.dim)
            y += VFDW.ctrlH + VFDW.gap
        }
        y = VFDW.label(fb, L, c, y, w, "RAW BYTES — tap to edit")
        val cells: List<VFDSpan> = L.split(8, gap = 4, c = c, w = w)
        val count: Int = data.size
        for ((i, b) in data.withIndex()) {
            val col: Int = i % 8
            if (col == 0 && i > 0) {
                y += VFDW.ctrlH + VFDW.gap
            }
            val cell: VFDSpan = cells[col]
            fb.box(cell.c, y, cell.w, VFDW.ctrlH, VFDInk.dim)
            fb.text(VFDW.cx(cell.c, cell.w, b), y + VFDW.ctrlText, b, VFDSize.small, VFDInk.dim)
            val index: Int = i
            VFDW.tap(fb, cell.c, y, cell.w, VFDW.ctrlH, "byte:$i", action = { promptByte(ctx, index, b, count) })
        }
        if (count > 0) {
            y += VFDW.ctrlH + VFDW.gap
        }
        y += 1
        return note(fb, c, y, w, byteHint)
    }

    /** SEND (primary, fills the row) + SAVE + TAG, the preset message, the service status line. */
    private fun actionSection(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                              w: Int): Int {
        val saveW: Int = VFDText.width("SAVE") + 12
        val tagW: Int = VFDText.width("TAG") + 12
        val sendW: Int = w - saveW - tagW - 8
        VFDW.button(fb, L, c, top, sendW, "SEND", primary = true, action = { sendPacket(ctx) })
        VFDW.button(fb, L, c + sendW + 4, top, saveW, "SAVE", action = { savePreset(ctx) })
        VFDW.button(fb, L, c + sendW + 4 + saveW + 4, top, tagW, "TAG", action = { tagRaw(ctx) })
        var y: Int = top + VFDW.ctrlH + VFDW.gap + 2
        val msg: String? = m.state.presetMsg
        if (msg != null) {
            val color: Int = if (msg.startsWith("Saved")) VFDInk.highlight else VFDInk.dim
            y = linesBlock(fb, c, y, listOf(VFDText.fit(msg, w)), color) - VFDW.gap
        }
        return VFDW.statusLine(fb, L, c, y, w, ctx.state.status) + VFDW.gap
    }

    // MARK: - Extras group

    private fun extrasGroup(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                            w: Int): Int {
        var y: Int = hairline(fb, c, top, w)
        y = randomShow(ctx, fb, L, m, c, y - (VFDW.sectionGap - VFDW.gap) + 3, w)
        return presetsSection(ctx, fb, L, m, c, y, w)
    }

    /** RANDOM LIGHT SHOW: the text, INTERVAL MS (SettingSlider 500..30000 step 250, committed on
     *  release), START / STOP SHOW and the current packet's label while it runs. */
    private fun randomShow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                           w: Int): Int {
        var y: Int = VFDW.section(fb, L, c, top, w, "RANDOM LIGHT SHOW")
        y = note(fb, c, y, w, showText)
        y = intervalSlider(ctx, fb, L, m, c, y, w)
        val running: Boolean = ctx.state.randomShowEnabled
        val lab: String = if (running) "STOP SHOW" else "START SHOW"
        val bw: Int = VFDText.width(lab) + 12
        VFDW.button(fb, L, c, y + 1, bw, lab, primary = true, action = { toggleShow(ctx) })
        if (running) {
            val shown: String = ctx.state.randomShowLabel.ifBlank { "Rolling the dice…" }
            fb.textFit(c + bw + 8, y + 1 + VFDW.ctrlText, VFDW.upper(shown), w - bw - 8, VFDSize.small,
                       VFDInk.highlight)
        }
        return y + 1 + VFDW.ctrlH + VFDW.gap
    }

    private fun intervalSlider(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                               w: Int): Int {
        val ui: VFDUIState = m.ui
        val low = 500.0
        val high = 30000.0
        val step = 250.0
        val value: Double = m.intervalMs
        val raw: Double = if (m.intervalDragging) m.intervalDraft else value
        val shown: Double = snap(raw, low, high, step)
        val frac: Double = (shown - low) / (high - low)
        val end: Int = VFDW.slider(fb, L, c, top, w, "INTERVAL MS", shown.roundToInt().toString(), frac,
                                   hint = intervalHint, name = "slider:INTERVAL", canDec = value > low,
                                   canInc = value < high,
                                   onDec = {
                                       ui.setBool(Keys.intervalDrag, false)
                                       commitInterval(ctx, snap(value - step, low, high, step))
                                   },
                                   onInc = {
                                       ui.setBool(Keys.intervalDrag, false)
                                       commitInterval(ctx, snap(value + step, low, high, step))
                                   })
        // The bar's drag: the value follows the finger and is committed on release.
        val barRow: Int = VFDW.groupTop(L, top) + VFDW.labelH
        val bx: Int = c + VFDW.stepW + 4
        val bw: Int = w - 2 * (VFDW.stepW + 4)
        VFDW.tap(fb, bx - 2, barRow, bw + 4, VFDW.ctrlH, "slider:INTERVAL:bar", drag = { fraction: Double, ended: Boolean ->
            val span: Double = (bw + 4).toDouble()
            val barW: Double = maxOf(1, bw).toDouble()
            val f: Double = minOf(maxOf((fraction * span - 2.0) / barW, 0.0), 1.0)
            val ms: Double = low + f * (high - low)
            if (ended) {
                ui.setBool(Keys.intervalDrag, false)
                commitInterval(ctx, snap(ms, low, high, step))
            } else {
                ui.setDouble(Keys.intervalDraft, ms)
                ui.setBool(Keys.intervalDrag, true)
            }
        })
        return end
    }

    /** MY PRESETS (n): one row per user preset (tap loads it, the bin deletes it after a confirm,
     *  HOLD offers both). Nothing when there are none. */
    private fun presetsSection(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, m: LabModel, c: Int, top: Int,
                               w: Int): Int {
        val presets: List<MagicPacket> = m.presets
        if (presets.isEmpty()) return top
        var y: Int = hairline(fb, c, top, w)
        y = VFDW.section(fb, L, c, y - (VFDW.sectionGap - VFDW.gap) + 3, w, "MY PRESETS (${presets.size})")
        y -= VFDW.gap + 2
        for (preset in presets) {
            y = presetRow(ctx, fb, preset, c, y, w)
        }
        return y + VFDW.gap
    }

    /** A preset row: label (text, uppercased) and hex (highlight), the bin on the right (its own
     *  tap), a dotted divider. Returns the next row's r. */
    private fun presetRow(ctx: VFDContext, fb: VFDFrameBuffer, preset: MagicPacket, c: Int, r: Int, w: Int): Int {
        val binX: Int = c + w - TRASH_W - 4
        val y: Int = r + 3
        val end: Int = y + VFDW.line + 7 + 3
        if (!rowVisible(fb, r, end + 1 - r)) {
            return end + 1
        }
        val limit: Int = binX - 6 - c - 2
        val upperLabel: String = VFDW.upper(preset.label)
        fb.textFit(c + 2, y, upperLabel, limit, VFDSize.small, VFDInk.text)
        fb.textFit(c + 2, y + VFDW.line, preset.hex, limit, VFDSize.small, VFDInk.highlight)
        trash(fb, binX, y + 5, VFDInk.dim)
        fb.hline(c, end, w, VFDInk.dim, step = 2)
        VFDW.tap(fb, c, r, binX - 4 - c, end - r, "preset:$upperLabel",
                 action = { loadPreset(ctx, preset) },
                 long = { presetMenu(ctx, preset) })
        VFDW.tap(fb, binX - 4, r, c + w - binX + 4, end - r, "preset:delete:$upperLabel",
                 action = { askDelete(ctx, preset) })
        return end + 1
    }
}
