package com.magicmaker.android.core

import com.magicmaker.android.service.ServiceState

/** Display order for grouped scan feed. */
enum class LivePacketSection(val title: String, val order: Int) {
    WAND("Wand", 0),
    COLORS("Colors", 1),
    ANIMATIONS("Animations", 2),
    CONTROL("Control", 3),
    PING("Ping", 4),
    INTERROGATE("Interrogate", 5),
    SHOWS("Shows", 6),
    UNKNOWN("Unknown", 7),
}

object LivePacketSort {
    fun sectionOf(packet: ServiceState.LivePacket): LivePacketSection {
        val hex = HexUtils.canonicalHex(packet.hex)
        return when {
            packet.typeInfo == "starlight" -> LivePacketSection.WAND
            packet.typeInfo in listOf("single", "dual") -> LivePacketSection.COLORS
            packet.label.contains("Show Control", ignoreCase = true) ||
                packet.typeInfo in listOf("e90e", "e908") -> LivePacketSection.CONTROL
            packet.typeInfo == "ping" && hex == PacketBuilder.WAKEUP_PING -> LivePacketSection.INTERROGATE
            packet.typeInfo == "ping" -> LivePacketSection.PING
            packet.category == MagicCategory.ANIMATION -> LivePacketSection.ANIMATIONS
            packet.category == MagicCategory.SHOW || packet.typeInfo == "show_block" -> LivePacketSection.SHOWS
            else -> LivePacketSection.UNKNOWN
        }
    }

    fun liveDedupeKey(hex: String, classified: ClassifiedPacket?): String {
        val canonical = HexUtils.canonicalHex(hex)
        if (classified != null) {
            if (classified.typeInfo == "starlight") {
                return PresetCatalog.starlightSimKey(MagicClassifier.starlightColorIndex(canonical))
            }
            return MagicClassifier.libraryDedupeKey(classified)
        }
        return "RAW:$canonical"
    }

    /** Grouped sections (in display order), newest first within each group. */
    fun grouped(packets: List<ServiceState.LivePacket>): List<Pair<LivePacketSection, List<ServiceState.LivePacket>>> {
        if (packets.isEmpty()) return emptyList()
        return packets
            .groupBy { sectionOf(it) }
            .entries
            .sortedBy { it.key.order }
            .map { (section, list) -> section to list.sortedByDescending { it.timestampMs } }
    }

    fun sectionOf(packet: MagicPacket): LivePacketSection = sectionOf(
        ServiceState.LivePacket(
            hex = packet.hex,
            label = packet.label,
            rssi = packet.rssi ?: 0,
            note = "",
            category = packet.category,
            typeInfo = packet.typeInfo,
            dedupeKey = packet.simKey,
        ),
    )

    fun groupedMagicPackets(packets: List<MagicPacket>): List<Pair<LivePacketSection, List<MagicPacket>>> =
        packets
            .groupBy { sectionOf(it) }
            .entries
            .sortedBy { it.key.order }
            .map { (section, list) -> section to list.sortedBy { it.label } }
}
