package com.magicmaker.android.core

object StarlightSerial {
    const val SERIAL_HEX_LEN = 22
    const val DEFAULT_SERIAL = "C42922EFD819F22A62"

    fun normalizeSerial(raw: String): String? {
        val s = raw.uppercase().filter { it in "0123456789ABCDEF" }
        if (s.length < SERIAL_HEX_LEN) return null
        return s.take(SERIAL_HEX_LEN)
    }

    fun extractSerial(hex: String): String? {
        val h = hex.uppercase().filter { it in "0123456789ABCDEF" }
        val markerPos = h.indexOf("CF9B").takeIf { it >= 0 } ?: h.indexOf("CF0B").takeIf { it >= 0 } ?: return null
        var pos = markerPos + 4
        if (pos + 2 <= h.length && h.substring(pos, pos + 2) == "00") pos += 2
        if (pos + SERIAL_HEX_LEN + 2 > h.length) return null
        return h.substring(pos, pos + SERIAL_HEX_LEN)
    }

    fun markerFrom(hex: String): String {
        val h = hex.uppercase().filter { it in "0123456789ABCDEF" }
        val cf9b = h.indexOf("CF9B")
        val cf0b = h.indexOf("CF0B")
        return when {
            cf9b >= 0 && (cf0b < 0 || cf9b <= cf0b) -> "CF9B"
            cf0b >= 0 -> "CF0B"
            else -> "CF9B"
        }
    }

    fun buildHex(serial: String, colorIndex: Int, marker: String = "CF9B"): String {
        val ser = normalizeSerial(serial) ?: DEFAULT_SERIAL
        val color = "%02X".format(colorIndex and 0x1F)
        val tag = if (marker == "CF0B") "CF0B" else "CF9B"
        return "8301${tag}00$ser$color"
    }

    /** Canonical 8301 + marker + 00 + 22-char serial + color byte. */
    fun isStoredFormat(hex: String): Boolean {
        val h = hex.uppercase().filter { it in "0123456789ABCDEF" }
        return h.matches(Regex("8301(CF9B|CF0B)00[0-9A-F]{22}[0-9A-F]{2}"))
    }

    fun validatedSerial(raw: String?): String = normalizeSerial(raw.orEmpty()) ?: DEFAULT_SERIAL
}
