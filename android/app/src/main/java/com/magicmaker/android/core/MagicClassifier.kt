package com.magicmaker.android.core

object MagicClassifier {
    private val colorPalette = PresetCatalog.starlightColorNames
    private val showHexes = PresetCatalog.showBlocks.values.map { it.uppercase() }.toSet()

    fun classify(hexRaw: String): ClassifiedPacket? {
        val hex = hexRaw.uppercase().filter { it in "0123456789ABCDEF" }
        if (!hex.startsWith("8301") && !hex.contains("CF9B") && !hex.contains("CF0B")) return null
        val normalized = if (hex.startsWith("8301")) hex else "8301$hex"
        if (normalized.length < 8 || normalized.length % 2 != 0) return null

        classifyStarlight(normalized)?.let { return it }

        PresetCatalog.showBlocks.entries.firstOrNull { it.value.uppercase() == normalized }?.let { entry ->
            return ClassifiedPacket(normalized, entry.key, MagicCategory.SHOW, "show_block", "", "SHOW:$normalized")
        }

        // Anchored to the 8301CC03 prefix (not a loose substring) so band telemetry that
        // merely contains "CC03" in its rolling payload isn't mislabeled as a ping. The two
        // bytes after CC03 distinguish the ping types seen in the parks.
        if (normalized.startsWith("8301CC03") && !normalized.contains("E9")) {
            val param = if (normalized.length >= 14) normalized.substring(8, 14) else normalized.substring(8)
            val pingLabel = when (param) {
                "000000" -> "Signal Beacon"
                "000100" -> "Wake Ping"
                "234100" -> "Show Ping (2341)"
                "203000" -> "Show Ping (2030)"
                else -> "Interaction Ping"
            }
            return ClassifiedPacket(normalized, pingLabel, MagicCategory.SHOW, "ping", "", "PING:$normalized")
        }

        // Real effect/show commands carry an E?00E9xx prelude (channel byte, 00, then the E9
        // function). Requiring that structure stops band telemetry that merely contains a stray
        // "E9" from being misread as a color/effect. Non-E9 Ex families fall through as before.
        val prelude = Regex("E[0-9A-F]00E9").find(normalized)
            ?: return classifyEffectFamily(normalized)
        val pos = prelude.range.last - 1
        val funcCode = normalized.substring(pos, minOf(pos + 4, normalized.length))

        val label: String
        val typeInfo: String
        val colors: String
        val simKey: String

        when (funcCode) {
            "E905" -> {
                val colorIdx = extractE905Color(normalized, pos)
                val name = colorPalette[colorIdx] ?: "Unknown"
                label = if (name == "Off") "Single Color: Off" else "Single Color: $name"
                typeInfo = "single"
                colors = name
                simKey = "C1:${"%02X".format(colorIdx)}"
            }
            "E906" -> {
                val c1 = if (normalized.length >= pos + 12) normalized.substring(pos + 10, pos + 12).toInt(16) and 0x1F else 0
                val c2 = if (normalized.length >= pos + 14) normalized.substring(pos + 12, pos + 14).toInt(16) and 0x1F else 0
                val n1 = colorPalette[c1] ?: "?"
                val n2 = colorPalette[c2] ?: "?"
                label = "Dual Color: $n2/$n1"
                typeInfo = "dual"
                colors = "$n2 / $n1"
                simKey = "C2:${"%02X".format(c2)}:${"%02X".format(c1)}"
            }
            "E90C" -> {
                label = when {
                    normalized.contains("5D465BF00532374895", ignoreCase = true) -> "Animation: Lightning Pulse"
                    normalized.contains("B1B9B5B1A2307B7DB0", ignoreCase = true) -> "Animation: 5-Color Cycle"
                    normalized.contains("5D465BF005323748B0", ignoreCase = true) -> "Animation: Taste the Rainbow"
                    else -> "Animation: Complex (E90C)"
                }
                typeInfo = "e90c"
                colors = ""
                simKey = when {
                    normalized.contains("5D465BF00532374895", ignoreCase = true) -> "A:LIGHTNING"
                    normalized.contains("5D465BF005323748B0", ignoreCase = true) -> "A:RAINBOW"
                    else -> "A:E90C:${normalized.substring(pos, minOf(pos + 20, normalized.length))}"
                }
            }
            "E90F" -> {
                label = "Animation: Alternating Strobe"
                typeInfo = "e90f"
                colors = ""
                simKey = "A:E90F:${normalized.substring(pos, minOf(pos + 16, normalized.length))}"
            }
            "E90B" -> {
                label = "Effect: Circle"
                typeInfo = "e90b"
                colors = ""
                simKey = "A:CIRCLE"
            }
            "E909" -> {
                label = "Effect: 5-LED Rainbow"
                typeInfo = "e909"
                colors = ""
                simKey = "A:E909"
            }
            "E911" -> {
                label = if (normalized.contains("55515BF00F10374894D13D0508B0", ignoreCase = true)) {
                    "Show: Pirate Cannon"
                } else {
                    "Animation: Palette Cross-Fade"
                }
                typeInfo = "e911"
                colors = extractFadeColor(normalized)
                simKey = if (normalized.contains("55515BF00F10374894D13D0508B0", ignoreCase = true)) {
                    "A:PIRATE_CANNON"
                } else {
                    "A:E911:${normalized.takeLast(4)}"
                }
            }
            "E90E", "E909", "E908" -> {
                label = "Show Control: $funcCode"
                typeInfo = funcCode.lowercase()
                colors = ""
                simKey = "S:$funcCode"
            }
            else -> {
                // Real E?00E9 structure but an E9 subtype we don't name yet (e.g. E914) — keep it
                // as show control instead of dropping/genericizing; this is what we want to catch.
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
     * Disney device command families use an 0xEx type byte (E1/E4/E5/EA/EF…) — real
     * effects/interactions even when we don't decode the exact action yet. Classify them by
     * type signature so they're named + saved as Animation instead of dropped as raw. Rolling
     * band telemetry (type C0 / 0F) is NOT 0xEx, so it stays out of here.
     */
    private fun classifyEffectFamily(normalized: String): ClassifiedPacket? {
        if (normalized.length < 8 || normalized[4] != 'E') return null
        val type = normalized.substring(4, 8)

        // EMCOT color cue: the palette-index byte after an "EF0501A6 <flag>" sub-command.
        fun cueColor(): String? {
            val m = normalized.indexOf("EF0501A6")
            if (m < 0 || m + 12 > normalized.length) return null
            val v = normalized.substring(m + 10, m + 12).toIntOrNull(16) ?: return null
            return StarlightColors.nameFor(v)
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
            type.startsWith("EA") -> ClassifiedPacket(
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

    private fun extractE905Color(hex: String, pos: Int): Int {
        if (hex.endsWith("B0") && hex.length >= 4) {
            return hex.substring(hex.length - 4, hex.length - 2).toInt(16) and 0x1F
        }
        if (hex.length >= pos + 12) {
            return hex.substring(pos + 10, pos + 12).toInt(16) and 0x1F
        }
        return 0
    }

    private fun extractFadeColor(hex: String): String {
        if (!hex.endsWith("B0") || hex.length < 4) return ""
        val byte = hex.substring(hex.length - 4, hex.length - 2).toInt(16) and 0x1F
        return colorPalette[byte] ?: ""
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
        return classify(h)?.typeInfo == "ping"
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
