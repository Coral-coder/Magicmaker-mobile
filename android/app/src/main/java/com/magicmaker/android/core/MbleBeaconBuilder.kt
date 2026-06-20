package com.magicmaker.android.core

/**
 * MBLE tap-token beacon builder — from MDE `MbleAdvertisingManagerImpl`.
 *
 * Layout: AltBeacon `m:2-3=0F11,i:2-4,i:5-19,p:20-20` on manufacturer 0x0183.
 * VMMS tokens arrive as hex strings; last byte is calibrated TX power.
 */
object MbleBeaconBuilder {
    const val MANUFACTURER_ID = 0x0183
    const val BEACON_LAYOUT = "m:2-3=0F11,i:2-4,i:5-19,p:20-20"
    const val BEACON_ID = "987393"

    fun manufacturerPayload(tokenHex: String): ByteArray {
        val token = tokenHex.uppercase().filter { it in "0123456789ABCDEF" }
        require(token.length >= 4) { "MBLE token too short" }
        val txPower = token.takeLast(2).toInt(16).toByte()
        val idBytes = hexToFixedBytes(BEACON_ID, 2)
        val tokenBody = hexToFixedBytes(token, 14)
        // 0F11 prefix + 2-byte id + 14-byte token body + 1-byte power (layout p:20-20)
        return byteArrayOf(0x0F, 0x11) + idBytes + tokenBody + byteArrayOf(txPower)
    }

    private fun hexToFixedBytes(hex: String, byteCount: Int): ByteArray {
        val padded = hex.padStart(byteCount * 2, '0').takeLast(byteCount * 2)
        return ByteArray(byteCount) { i ->
            padded.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }
}
