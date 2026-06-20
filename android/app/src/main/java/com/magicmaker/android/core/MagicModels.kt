package com.magicmaker.android.core

enum class MagicCategory { SHOW, ANIMATION, COLOR, UNKNOWN }

data class MagicPacket(
    var id: Long = 0,
    var hex: String,
    var label: String,
    var category: MagicCategory,
    var typeInfo: String,
    var colors: String = "",
    var simKey: String,
    var userRecorded: Boolean = false,
    var rssi: Int? = null,
    var wandVerified: Boolean = false,
)

data class ClassifiedPacket(
    val hex: String,
    val label: String,
    val category: MagicCategory,
    val typeInfo: String,
    val colors: String,
    val simKey: String,
)

data class Recording(
    val id: Long,
    val timestampMs: Long,
    val hex: String,
    val rssi: Int,
    val label: String,
    val category: MagicCategory,
    val typeInfo: String,
    val colors: String,
    val libraryNote: String,
)

data class AutoResponseRule(
    val id: Long,
    var name: String,
    var triggerPatternId: String,
    var responsePatternId: String,
    var responseHex: String,
    var responseHexes: List<String> = emptyList(),
    var enabled: Boolean,
)

data class RecordEvent(
    val packet: MagicPacket,
    val added: Boolean,
    val reason: String,
)

enum class RelayControlMode {
    STANDALONE,
    WIFI_HOTSPOT,
    BLE_GATT,
}

fun MagicPacket.toClassified() = ClassifiedPacket(hex, label, category, typeInfo, colors, simKey)

fun ClassifiedPacket.toPacket(userRecorded: Boolean = false) =
    MagicPacket(0, hex, label, category, typeInfo, colors, simKey, userRecorded)
