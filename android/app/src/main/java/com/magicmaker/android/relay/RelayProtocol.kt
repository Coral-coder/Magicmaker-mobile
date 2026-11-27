package com.magicmaker.android.relay

object RelayProtocol {
    const val SERVICE_UUID = "A7830001-0000-1000-8000-00805F9B34FB"
    const val TRANSMIT_UUID = "A7830002-0000-1000-8000-00805F9B34FB"
    const val COMMAND_UUID = "A7830003-0000-1000-8000-00805F9B34FB"
    const val STATUS_UUID = "A7830004-0000-1000-8000-00805F9B34FB"
    const val CATALOG_UUID = "A7830005-0000-1000-8000-00805F9B34FB"

    /** SYNC (docs/SYNC_PROTOCOL.md §9): WRITE | WRITE_NO_RESPONSE | NOTIFY, framed SYNC v1 messages. */
    const val SYNC_UUID = "A7830006-0000-1000-8000-00805F9B34FB"

    /** Client Characteristic Configuration descriptor. */
    const val CCCD_UUID = "00002902-0000-1000-8000-00805F9B34FB"
    const val HTTP_PORT = 8765

    /**
     * Relay identity tag. The relay advertises no name at all (the phone's Bluetooth name is never
     * touched); instead the scan response carries this ASCII tag as service data on [SERVICE_UUID]
     * (Base-UUID derived, so Android sends it as 32-bit service data, AD 0x20: 2 + 4 + 6 = 12 bytes;
     * at most 2 + 16 + 6 = 24 as 128-bit, within the 31-byte limit). The iPhone matches on it
     * (ios AndroidRelayGattClient.androidRelayTag) and must stay byte-identical.
     */
    const val RELAY_TAG = "MM_AND"

    /**
     * Bluetooth name that builds before RELAY_TAG forced onto the phone's adapter (system-wide,
     * never undone). Only used now to recognise and undo that rename; never advertised or set.
     */
    const val LEGACY_DEVICE_NAME = "MagicMaker-Android"

    /** [RELAY_TAG] as the service-data bytes put in the scan response. */
    fun relayTagBytes(): ByteArray = RELAY_TAG.toByteArray(Charsets.US_ASCII)

    /**
     * The sync-era tag (SYNC_HUB_SPEC §3.1): [RELAY_TAG] + the first two bytes of the sync group id
     * (`00 00` while ungrouped), 8 bytes. iOS matches the tag by prefix, so older builds still find it.
     */
    fun relayTagBytes(groupId: ByteArray?): ByteArray {
        val g = if (groupId != null && groupId.size >= 2 && groupId.any { it.toInt() != 0 }) groupId.copyOf(2) else ByteArray(2)
        return relayTagBytes() + g
    }

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
