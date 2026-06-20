package com.magicmaker.android.relay

object RelayProtocol {
    const val SERVICE_UUID = "A7830001-0000-1000-8000-00805F9B34FB"
    const val TRANSMIT_UUID = "A7830002-0000-1000-8000-00805F9B34FB"
    const val COMMAND_UUID = "A7830003-0000-1000-8000-00805F9B34FB"
    const val STATUS_UUID = "A7830004-0000-1000-8000-00805F9B34FB"
    const val CATALOG_UUID = "A7830005-0000-1000-8000-00805F9B34FB"
    const val DEVICE_NAME = "MagicMaker-Android"
    const val HTTP_PORT = 8765

    /** Same wire format as ESP32: `{hex}|{durationMs}` */
    fun parseTransmitPayload(text: String): Pair<String, Int>? {
        val trimmed = text.trim()
        val pipe = trimmed.lastIndexOf('|')
        if (pipe <= 0) return null
        val hex = trimmed.substring(0, pipe).trim()
        val duration = trimmed.substring(pipe + 1).trim().toIntOrNull() ?: return null
        return hex to duration
    }
}
