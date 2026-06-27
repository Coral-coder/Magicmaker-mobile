package com.magicmaker.android.core

/**
 * Low-level helpers for the Lab packet inspector — byte-level editing plus the
 * well-defined fields (vibration tail nibble) that every esp32_magicband command
 * shares. Kept deliberately structural so it works on any captured packet, not just
 * the ones the builder knows how to synthesize.
 */
object LabPacketTools {

    /** Split a hex string into 2-char byte tokens (drops a trailing odd nibble). */
    fun toBytes(hex: String): List<String> {
        val clean = hex.uppercase().filter { it in "0123456789ABCDEF" }
        return clean.chunked(2).filter { it.length == 2 }
    }

    fun fromBytes(bytes: List<String>): String = bytes.joinToString("").uppercase()

    /** Vibration value (0–15) encoded in the tail byte `0xB0 | vib`, or null if no tail. */
    fun tailVibration(hex: String): Int? {
        val bytes = toBytes(hex)
        val last = bytes.lastOrNull()?.toIntOrNull(16) ?: return null
        return if (last and 0xF0 == 0xB0) last and 0x0F else null
    }

    /** Rewrite the tail byte to `0xB0 | vib`. No-op if the packet has no B0–BF tail. */
    fun withVibration(hex: String, vib: Int): String {
        val bytes = toBytes(hex).toMutableList()
        if (bytes.isEmpty()) return hex
        val last = bytes.last().toIntOrNull(16) ?: return hex
        if (last and 0xF0 != 0xB0) return hex
        bytes[bytes.size - 1] = "%02X".format(0xB0 or (vib and 0x0F))
        return fromBytes(bytes)
    }
}
