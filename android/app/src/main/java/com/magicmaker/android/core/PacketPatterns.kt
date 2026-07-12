package com.magicmaker.android.core

enum class MatchKind { SIM_KEY, TYPE_INFO, HEX_PREFIX, EXACT_HEX, STARLIGHT_COLOR }

data class PacketPattern(
    val id: String,
    val label: String,
    val matchKind: MatchKind,
    val matchValue: String,
    val defaultHex: String = "",
    val group: String? = null,
)

object PacketPatterns {
    val systemTriggers = listOf(
        PacketPattern("ping_fast", "Interaction ping (fast mode)", MatchKind.EXACT_HEX, PacketBuilder.WAKEUP_PING, PacketBuilder.WAKEUP_PING),
        PacketPattern("ping_prefix", "Any CC03 ping", MatchKind.HEX_PREFIX, "8301CC03"),
        PacketPattern("starlight", "Any starlight wand (any color)", MatchKind.TYPE_INFO, "starlight", group = "Starlight wand"),
        PacketPattern("newwand", "Any New Wand code (CF0B)", MatchKind.HEX_PREFIX, NewWandCatalog.PREFIX, group = "New wand"),
        PacketPattern("e905", "Any single color (E905)", MatchKind.TYPE_INFO, "single"),
        PacketPattern("e90c", "Any animation (E90C)", MatchKind.TYPE_INFO, "e90c"),
        PacketPattern("rainbow", "Taste the Rainbow", MatchKind.SIM_KEY, "A:RAINBOW", "8301CC03000100E100E90C000F0F5D465BF005323748B0"),
        PacketPattern("any_raw", "Any unclassified packet", MatchKind.TYPE_INFO, "raw"),
    )

    val systemResponses = listOf(
        PacketPattern("resp_wakeup", "Wakeup ping", MatchKind.EXACT_HEX, PacketBuilder.WAKEUP_PING, PacketBuilder.WAKEUP_PING),
        PacketPattern("resp_vibrate", "Vibrate band", MatchKind.EXACT_HEX, PacketBuilder.vibrateBand(), PacketBuilder.vibrateBand()),
        PacketPattern("resp_rainbow", "Rainbow finale", MatchKind.EXACT_HEX,
            "8301CC03000100E100E90C000F0F5D465BF005323748B0",
            "8301CC03000100E100E90C000F0F5D465BF005323748B0"),
    )

    fun buildTriggerOptions(userPresets: List<MagicPacket>, learned: List<MagicPacket>) =
        systemTriggers + userPresets.map { presetTrigger(it) } + learned.map { learnedTrigger(it) }

    fun buildResponseOptions(userPresets: List<MagicPacket>, learned: List<MagicPacket>) =
        systemResponses + userPresets.map { presetResponse(it) } + learned.map { learnedResponse(it) }

    fun presetTrigger(packet: MagicPacket) = PacketPattern(
        "preset_t_${packet.id}", packet.label, MatchKind.SIM_KEY, packet.simKey, packet.hex, packet.category.name,
    )

    fun presetResponse(packet: MagicPacket) = PacketPattern(
        "preset_r_${packet.id}", packet.label, MatchKind.SIM_KEY, packet.simKey, packet.hex,
    )

    fun learnedTrigger(packet: MagicPacket) = PacketPattern(
        "learned_t_${packet.id}", packet.label, MatchKind.SIM_KEY, packet.simKey, packet.hex, packet.category.name,
    )

    fun learnedResponse(packet: MagicPacket) = PacketPattern(
        "learned_r_${packet.id}", packet.label, MatchKind.SIM_KEY, packet.simKey, packet.hex,
    )

    fun matches(pattern: PacketPattern, classified: ClassifiedPacket, rawHex: String): Boolean {
        val heardRaw = rawHex.uppercase().filter { it in "0123456789ABCDEF" }
        return when (pattern.matchKind) {
            MatchKind.STARLIGHT_COLOR -> {
                if (classified.typeInfo != "starlight") return false
                MagicClassifier.starlightColorIndex(heardRaw) == (pattern.matchValue.toIntOrNull(16) ?: -1)
            }
            MatchKind.SIM_KEY -> classified.simKey.equals(pattern.matchValue, ignoreCase = true)
            MatchKind.TYPE_INFO -> classified.typeInfo.equals(pattern.matchValue, ignoreCase = true)
            MatchKind.HEX_PREFIX -> heardRaw.startsWith(pattern.matchValue.uppercase())
            MatchKind.EXACT_HEX -> heardRaw == pattern.matchValue.uppercase()
        }
    }

    fun matchesTriggerId(
        triggerId: String,
        classified: ClassifiedPacket,
        rawHex: String,
        userPresets: List<MagicPacket>,
        learned: List<MagicPacket>,
    ): Boolean {
        if (triggerId.startsWith("preset_t_")) {
            val id = triggerId.removePrefix("preset_t_").toLongOrNull()
            userPresets.firstOrNull { it.id == id }?.let {
                return classified.simKey.equals(it.simKey, ignoreCase = true) ||
                    HexUtils.canonicalHex(rawHex) == HexUtils.canonicalHex(it.hex)
            }
        }
        if (triggerId.startsWith("learned_t_")) {
            val id = triggerId.removePrefix("learned_t_").toLongOrNull()
            learned.firstOrNull { it.id == id }?.let {
                return classified.simKey.equals(it.simKey, ignoreCase = true)
            }
        }
        val pattern = buildTriggerOptions(userPresets, learned).firstOrNull { it.id == triggerId } ?: return false
        return matches(pattern, classified, rawHex)
    }

    fun resolveResponseHexes(rule: AutoResponseRule, userPresets: List<MagicPacket>, learned: List<MagicPacket>): List<String> {
        val stacked = rule.responseHexes.map { HexUtils.canonicalHex(it) }.filter { it.isNotEmpty() }
        if (stacked.isNotEmpty()) return stacked
        if (rule.responsePatternId.startsWith("preset_r_")) {
            val id = rule.responsePatternId.removePrefix("preset_r_").toLongOrNull()
            userPresets.firstOrNull { it.id == id }?.let { return listOf(it.hex) }
        }
        if (rule.responsePatternId.startsWith("learned_r_")) {
            val id = rule.responsePatternId.removePrefix("learned_r_").toLongOrNull()
            learned.firstOrNull { it.id == id }?.let { return listOf(it.hex) }
        }
        systemResponses.firstOrNull { it.id == rule.responsePatternId && it.defaultHex.isNotEmpty() }?.let {
            return listOf(it.defaultHex)
        }
        val single = rule.responseHex.trim()
        return if (single.isNotEmpty()) listOf(HexUtils.canonicalHex(single)) else emptyList()
    }

    @Deprecated("Use overload with userPresets", ReplaceWith("matchesTriggerId(triggerId, classified, rawHex, emptyList(), learned)"))
    fun matchesTriggerId(triggerId: String, classified: ClassifiedPacket, rawHex: String, learned: List<MagicPacket>): Boolean =
        matchesTriggerId(triggerId, classified, rawHex, emptyList(), learned)

    fun resolveResponseHex(rule: AutoResponseRule, userPresets: List<MagicPacket>, learned: List<MagicPacket>): String =
        resolveResponseHexes(rule, userPresets, learned).firstOrNull().orEmpty()
}
