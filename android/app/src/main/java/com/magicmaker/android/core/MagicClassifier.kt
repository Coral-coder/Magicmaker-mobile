package com.magicmaker.android.core

object MagicClassifier {
    private val colorPalette = PresetCatalog.starlightColorNames
    private val showHexes = PresetCatalog.showBlocks.values.map { it.uppercase() }.toSet()

    private const val CLASSIFY_CACHE_MAX = 1024
    private val classifyCache = object : LinkedHashMap<String, Optional>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Optional>): Boolean =
            size > CLASSIFY_CACHE_MAX
    }

    /** Null is a meaningful classify() result, so the cache stores it rather than re-deriving it. */
    private class Optional(val value: ClassifiedPacket?)

    /**
     * classify() is pure: the same hex always yields the same result. It is also the single
     * hottest function in the app — the scan path, the library writer, the automation matcher
     * and every list row all call it, and a packet repeats hundreds of times a second while a
     * wand is broadcasting. Memoize it so the regex and the show-block scan run once per
     * distinct packet instead of once per sighting.
     */
    fun classify(hexRaw: String): ClassifiedPacket? {
        synchronized(classifyCache) { classifyCache[hexRaw] }?.let { return it.value }
        val result = classifyUncached(hexRaw)
        synchronized(classifyCache) { classifyCache[hexRaw] = Optional(result) }
        return result
    }

    private fun classifyUncached(hexRaw: String): ClassifiedPacket? {
        val hex = hexRaw.uppercase().filter { it in "0123456789ABCDEF" }
        if (!hex.startsWith("8301") && !hex.contains("CF9B") && !hex.contains("CF0B")) return null
        val normalized = if (hex.startsWith("8301")) hex else "8301$hex"
        if (normalized.length < 8 || normalized.length % 2 != 0) return null

        classifyStarlight(normalized)?.let { return it }

        PresetCatalog.showBlocks.entries.firstOrNull { it.value.uppercase() == normalized }?.let { entry ->
            return ClassifiedPacket(normalized, entry.key, MagicCategory.SHOW, "show_block", "", "SHOW:$normalized")
        }

        // Walk the TLV chain instead of pattern-matching the hex. A ping is a CC record with no
        // effect record after it; an effect is an E9 record wherever it sits in the chain (with
        // or without a channel marker, with or without a wake-ping prefix); everything else is
        // judged by its leading record type.
        val parsed = DisneyTlv.parse(normalized) ?: return null
        val first = parsed.records.firstOrNull() ?: return null
        val effect = parsed.effect

        if (effect == null && first.type == DisneyTlv.TYPE_PING) {
            return ClassifiedPacket(
                normalized, DisneyTlv.pingName(first.valueHex().take(6)), MagicCategory.SHOW, "ping", "", "PING:$normalized",
            )
        }
        if (effect == null) return classifyEffectFamily(normalized, parsed, first)

        return classifyEffect(normalized, effect)
    }

    /** E9 record → the colour / animation / show-control classification. */
    private fun classifyEffect(normalized: String, e: DisneyTlv.Record): ClassifiedPacket? {
        // "E9" + length byte — the four hex chars the rest of the app has always keyed on.
        val funcCode = e.headHex()
        val body = e.valueHex()
        // The old substring code took its signature windows from the "E9" onward; keep the
        // same windows so existing simKeys (and the automation rules built on them) still match.
        val fromHead = funcCode + body
        fun palette(i: Int): Int = (e.byte(i) ?: 0) and 0x1F

        val label: String
        val typeInfo: String
        val colors: String
        val simKey: String

        when (funcCode) {
            "E905" -> {
                val colorIdx = palette(3)
                val name = colorPalette[colorIdx] ?: "Unknown"
                label = if (name == "Off") "Single Color: Off" else "Single Color: $name"
                typeInfo = "single"
                colors = name
                simKey = "C1:${"%02X".format(colorIdx)}"
            }
            "E906" -> {
                val c1 = palette(3)
                val c2 = palette(4)
                val n1 = colorPalette[c1] ?: "?"
                val n2 = colorPalette[c2] ?: "?"
                // First colour byte lights the centre LED, second the four corners.
                label = "Dual Color: $n1 centre / $n2 corners"
                typeInfo = "dual"
                colors = "$n1 / $n2"
                simKey = "C2:${"%02X".format(c2)}:${"%02X".format(c1)}"
            }
            "E90C" -> {
                label = when {
                    body.contains("5D465BF00532374895") -> "Animation: Lightning Pulse"
                    body.contains("B1B9B5B1A2307B7DB0") -> "Animation: 5-Color Cycle"
                    body.contains("5D465BF005323748B0") -> "Animation: Taste the Rainbow"
                    else -> "Animation (E90C)"
                }
                typeInfo = "e90c"
                // body[3], body[4] are colour bytes (flag 010) in every E90C seen, park or public.
                colors = if (e.length >= 5 && (e.byte(3) ?: 0) shr 5 == 2)
                    "${StarlightColors.nameFor(palette(3))} / ${StarlightColors.nameFor(palette(4))}" else ""
                simKey = when {
                    body.contains("5D465BF00532374895") -> "A:LIGHTNING"
                    body.contains("5D465BF005323748B0") -> "A:RAINBOW"
                    else -> "A:E90C:${fromHead.take(20)}"
                }
            }
            "E90F" -> {
                // Same template throughout; body[11] picks the mode (public listener: 2A candles,
                // 02 centre pulse). body[3] = centre colour, body[4] = corners.
                label = when (e.byte(11)) {
                    0x2A -> "Candle Flicker (E90F)"
                    0x02 -> "Centre Pulse (E90F)"
                    else -> "Animation (E90F)"
                }
                typeInfo = "e90f"
                colors = if (e.length >= 5) "${StarlightColors.nameFor(palette(3))} centre / ${StarlightColors.nameFor(palette(4))} corners" else ""
                simKey = "A:E90F:${fromHead.take(16)}"
            }
            "E90B" -> {
                label = "Effect: Circle"
                typeInfo = "e90b"
                colors = ""
                simKey = "A:CIRCLE"
            }
            "E909" -> {
                label = "5-Zone Colors"
                typeInfo = "e909"
                colors = if (e.length >= 8) (3..7).joinToString(" / ") { StarlightColors.nameFor(palette(it)) } else ""
                simKey = "A:E909"
            }
            "E911" -> {
                // The captured Pirate Cannon packet is exactly 17 body bytes and ends ...0508.
                // The old signature had a trailing B0 that no real packet carries.
                val pirate = body.contains("55515BF00F10374894D13D0508")
                label = if (pirate) "Show: Pirate Cannon"
                    else "Cross-Fade: ${StarlightColors.nameFor(palette(3))} / ${StarlightColors.nameFor(palette(4))}"
                typeInfo = "e911"
                // Fade from/to live at value[3]/value[4] — not "the byte before a trailing B0",
                // which two of the nine real E911 packets do not even have.
                colors = if (pirate) "" else "${StarlightColors.nameFor(palette(3))} / ${StarlightColors.nameFor(palette(4))}"
                simKey = if (pirate) "A:PIRATE_CANNON" else "A:E911:${normalized.takeLast(4)}"
            }
            // Lengths other decoders have named (docs/PROTOCOL.md §6a). typeInfo/simKey stay the
            // same as before so stored library entries and automation rules keep matching.
            "E908" -> {
                label = "Custom RGB Color"
                typeInfo = "e908"; colors = ""; simKey = "S:$funcCode"
            }
            "E90E" -> {
                label = "Twinkle / Flash (E90E)"
                typeInfo = "e90e"
                colors = if (e.length >= 8) (3..7).joinToString(" / ") { StarlightColors.nameFor(palette(it)) } else ""
                simKey = "S:$funcCode"
            }
            // Public listener renders this template as a comet chase; body[6] is its colour.
            "E910" -> {
                label = "Comet (E910)"; typeInfo = "e910"
                colors = if (e.length >= 7) StarlightColors.nameFor(palette(6)) else ""
                simKey = "S:$funcCode"
            }
            "E912" -> {
                label = if (e.byte(2) == 0x0F) "Rotating Colors (E912)" else "Two-Color Toggle (E912)"
                typeInfo = "e912"
                colors = if (e.length >= 8) (3..7).joinToString(" / ") { StarlightColors.nameFor(palette(it)) } else ""
                simKey = "S:$funcCode"
            }
            "E913" -> {
                label = "Corner Alternate (E913)"
                typeInfo = "e913"
                colors = if (e.length >= 6) "${StarlightColors.nameFor(palette(3))} centre, ${StarlightColors.nameFor(palette(5))} / ${StarlightColors.nameFor(palette(4))}" else ""
                simKey = "S:$funcCode"
            }
            "E914" -> {
                label = "Repeating Fade (E914)"
                typeInfo = "e914"
                colors = if (e.length >= 9) StarlightColors.nameFor(palette(8)) else ""
                simKey = "S:$funcCode"
            }
            else -> {
                // A real E9 record whose body length we have no name for yet (E914 is one). It is
                // show control by construction — keep it, never drop it to "unknown".
                label = "Show Control: $funcCode"
                typeInfo = funcCode.lowercase()
                colors = ""
                simKey = "S:$funcCode"
            }
        }

        val category = categorize(normalized, label, typeInfo)
        return ClassifiedPacket(normalized, label, category, typeInfo, colors, simKey)
    }

    /**
     * No effect record: judge the packet by its leading record. Disney infrastructure uses
     * 0xEx record types (E4/E5/EA/EF…) for beacons and cues — real transmissions even though we
     * do not decode the action. Band telemetry (C0 / 0F) is not 0xEx and stays out of here.
     */
    private fun classifyEffectFamily(normalized: String, parsed: DisneyTlv.Parsed, first: DisneyTlv.Record): ClassifiedPacket? {
        if (first.type !in 0xE0..0xEF) return null
        val type = first.headHex()

        // EMCOT colour cue: an EF record with body 01 A6 <flag> <palette index>.
        fun cueColor(): String? {
            val cue = parsed.records.firstOrNull {
                it.type == 0xEF && it.declaredLength == 5 && it.byte(0) == 0x01 && it.byte(1) == 0xA6
            } ?: return null
            return StarlightColors.nameFor(cue.byte(3) ?: return null)
        }

        return when {
            type == "EF05" -> {
                val c = cueColor()
                ClassifiedPacket(
                    normalized, c?.let { "Color Cue: $it" } ?: "Color Cue (EF05)",
                    MagicCategory.COLOR, "fx_ef05", c.orEmpty(), "FX:$normalized",
                )
            }
            type == "EF08" -> ClassifiedPacket(
                normalized, "Scene Cue (EF08)", MagicCategory.ANIMATION, "fx_ef08", "", "FX:$normalized",
            )
            type == "E409" -> {
                val c = cueColor()
                ClassifiedPacket(
                    normalized, c?.let { "Show Burst: $it" } ?: "Show Burst (E409)",
                    MagicCategory.ANIMATION, "fx_e409", c.orEmpty(), "FX:$normalized",
                )
            }
            type == "E501" -> ClassifiedPacket(
                normalized, "Sync Cue (E501)", MagicCategory.ANIMATION, "fx_e501", "", "FX:$normalized",
            )
            first.type == 0xEA -> ClassifiedPacket(
                normalized, "Animation (style ${type.substring(2)})", MagicCategory.ANIMATION, "fx_ea", "", "FX:$normalized",
            )
            else -> ClassifiedPacket(
                normalized, "Effect $type", MagicCategory.ANIMATION, "effect", "", "FX:$normalized",
            )
        }
    }

    fun starlightColorIndex(hex: String): Int {
        val h = hex.uppercase().filter { it in "0123456789ABCDEF" }
        if (h.contains("CC03000100CF9B") || h.contains("000000000000")) {
            if (h.endsWith("B0") && h.length >= 4) {
                return h.substring(h.length - 4, h.length - 2).toInt(16) and 0x1F
            }
            return h.takeLast(2).toInt(16) and 0x1F
        }
        val markerPos = h.indexOf("CF9B").let { if (it >= 0) it else h.indexOf("CF0B") }
        if (markerPos >= 0) {
            var pos = markerPos + 4
            if (pos + 2 <= h.length && h.substring(pos, pos + 2) == "00") pos += 2
            val colorPos = pos + StarlightSerial.SERIAL_HEX_LEN
            if (colorPos + 2 <= h.length) {
                return h.substring(colorPos, colorPos + 2).toInt(16) and 0x1F
            }
            // Truncated ADV: color byte is still the last payload byte.
            if (h.length >= pos + 4) {
                return h.takeLast(2).toInt(16) and 0x1F
            }
        }
        if (h.endsWith("B0") && h.length >= 4) {
            return h.substring(h.length - 4, h.length - 2).toInt(16) and 0x1F
        }
        return h.takeLast(2).toInt(16) and 0x1F
    }

    /** Best-effort color index for learning — accepts short ADV when marker + color byte are present. */
    fun starlightLearnColorIndex(hex: String): Int? {
        val h = HexUtils.canonicalHex(hex)
        if (!HexUtils.isStarlightPacket(h)) return null
        val markerPos = h.indexOf("CF9B").takeIf { it >= 0 } ?: h.indexOf("CF0B").takeIf { it >= 0 } ?: return null
        var pos = markerPos + 4
        if (pos + 2 <= h.length && h.substring(pos, pos + 2) == "00") pos += 2
        if (h.length >= pos + StarlightSerial.SERIAL_HEX_LEN + 2) {
            return starlightColorIndex(h)
        }
        if (h.contains("CC03000100CF9B") || h.contains("000000000000")) {
            return starlightColorIndex(h)
        }
        if (h.length >= pos + 4) {
            return h.takeLast(2).toInt(16) and 0x1F
        }
        return null
    }

    /** Pick a hex that fits in BLE ADV — use heard payload when valid, else built-in template. */
    fun starlightTxHex(rawHex: String): String {
        val canonical = HexUtils.canonicalHex(rawHex)
        val colorIdx = starlightLearnColorIndex(canonical) ?: starlightColorIndex(canonical)
        if (HexUtils.legacyAdvertiseRejectReason(canonical) == null) return canonical
        return PresetCatalog.legacyStarlightHex(colorIdx)
    }

    private fun classifyStarlight(hex: String): ClassifiedPacket? {
        if (!hex.contains("CF9B") && !hex.contains("CF0B")) return null
        val canonical = HexUtils.canonicalHex(hex)
        val colorIdx = starlightColorIndex(canonical)
        val name = StarlightColors.nameFor(colorIdx)
        val txHex = starlightTxHex(canonical)
        return ClassifiedPacket(
            txHex,
            "Starlight: $name (#${"%02X".format(colorIdx)})",
            MagicCategory.COLOR,
            "starlight",
            name,
            PresetCatalog.starlightSimKey(colorIdx),
        )
    }



    private fun categorize(hex: String, label: String, typeInfo: String): MagicCategory {
        if (typeInfo in listOf("starlight", "single", "dual")) return MagicCategory.COLOR
        if (showHexes.contains(hex) || label.startsWith("Show:") || typeInfo.startsWith("e90")) {
            if (typeInfo.startsWith("e90") && typeInfo !in listOf("e90e", "e908", "e909")) {
                return MagicCategory.ANIMATION
            }
            if (label.contains("Show Control", ignoreCase = true) || showHexes.contains(hex)) {
                return MagicCategory.SHOW
            }
            return MagicCategory.ANIMATION
        }
        return when (typeInfo) {
            "e90c", "e90f", "e911", "e90b", "e909" -> MagicCategory.ANIMATION
            "e90e", "e908", "e909", "ping" -> MagicCategory.SHOW
            else -> MagicCategory.ANIMATION
        }
    }

    /** Human label for an unclassified packet — its full hex (distinct packets stay distinct). */
    fun rawLabel(hexRaw: String): String {
        val h = HexUtils.canonicalHex(hexRaw)
        return if (h.length <= 24) "Raw: $h" else "Raw: ${h.take(18)}…${h.takeLast(4)}"
    }

    /** Identity used to group packets in the library / analyzed view: the full canonical hex,
     * so every distinct packet is kept separate (classified packets use their normalized hex). */
    fun groupKey(hexRaw: String): String {
        val c = classify(hexRaw)
        return if (c != null) HexUtils.canonicalHex(c.hex) else HexUtils.canonicalHex(hexRaw)
    }

    /** Display label for [groupKey] — the classification when known, else the raw hex. */
    fun groupLabel(hexRaw: String): String = classify(hexRaw)?.label ?: rawLabel(hexRaw)

    /**
     * Packets we never auto-save to the library: guest MagicBand telemetry (8301C0…, every
     * nearby band broadcasts these with rolling payloads) and interaction/wakeup pings. Both
     * are high-volume background noise, not controllable effects.
     */
    fun isLibraryNoise(hexRaw: String): Boolean {
        val h = HexUtils.canonicalHex(hexRaw)
        if (h.startsWith("8301C0")) return true       // guest MagicBand telemetry
        if (h.startsWith("83010F11")) return true      // rolling per-band ID broadcasts
        // Ping is TLV type 0xCC at the head — no need to run a full classify() for it.
        return h.startsWith("8301CC03")
    }

    /**
     * Strict "is this a real, band/wand-controllable show-control packet" test: interaction pings,
     * E9 effect records, Starlight/New Wand, and known show blocks. Deliberately EXCLUDES the
     * classifyEffectFamily beacon families (EA/EF/E4/E5…) — those are stationary park infrastructure
     * beacons that never animate a band, so treating them as show control just clutters the library.
     */
    fun isShowControl(hexRaw: String): Boolean {
        val h = HexUtils.canonicalHex(hexRaw)
        if (h.startsWith("8301CC03")) return true
        if (h.contains("CF9B") || h.contains("CF0B")) return true
        // An E9 record anywhere in the chain — with or without a channel marker in front of it.
        if (DisneyTlv.parse(h)?.has(DisneyTlv.TYPE_EFFECT) == true) return true
        return showHexes.contains(h)
    }

    fun libraryDedupeKey(classified: ClassifiedPacket): String = when (classified.typeInfo) {
        "starlight", "single", "dual", "show_block" -> classified.simKey
        "ping" -> "FUNC:ping"
        "e90f" -> "FUNC:e90f"
        "e908", "e909", "e90e" -> "FUNC:${classified.typeInfo}"
        "e90c" -> if (classified.simKey.startsWith("A:")) classified.simKey else "FUNC:e90c"
        "e911" -> if (classified.simKey.startsWith("A:")) classified.simKey else "FUNC:e911"
        else -> classified.simKey.ifEmpty { "FUNC:${classified.typeInfo}" }
    }
}
