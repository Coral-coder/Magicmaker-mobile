package com.magicmaker.android.ble

/**
 * The ESP32 transmitter's battery heartbeat, read straight from its adverts (no connection),
 * firmware 1.4+. Manufacturer data, company id 0xFFFF (reserved for testing, so it can never be
 * mistaken for a Disney packet). After the company id:
 *   'M' 'B' <version 1> <battery % or 0xFF> <flags> <runtime minutes, u16 LE, or 0xFFFF>
 * flags: bit0 charging, bit1 on USB power, bit2 a battery reading is present, bit3 low battery
 * (firmware 1.5+: below the board's low-battery cutoff + 0.10 V; never set while charging or on
 * USB). The version byte stays 1: older parsers ignore the new bit.
 */
data class Esp32Heartbeat(
    /** 0..100, or -1 when the board has no battery reading (classic ESP32, no battery). */
    val percent: Int,
    val charging: Boolean,
    val onUsb: Boolean,
    val hasBattery: Boolean,
    /**
     * Estimated minutes left on battery, or -1 when unknown (charging, USB or no reading). From
     * firmware 1.5 it counts down to the low-battery cutoff, not to empty.
     */
    val runtimeMinutes: Int,
    /** Firmware 1.5+: the board warns of a low battery (it turns itself off at its cutoff). */
    val low: Boolean = false,
) {
    /**
     * "ESP32:68% ~9H 40M", "ESP32:8% LOW ~25M" while the board warns of a low battery (as the
     * iPhone app shows it), "ESP32:CHG" (charging wins), "ESP32:USB", or null when there is
     * nothing to show.
     */
    fun telemetryToken(): String? {
        if (!hasBattery) return null
        if (charging) return "ESP32:CHG"
        if (onUsb && percent < 0) return "ESP32:USB"
        if (percent < 0) return if (low) "ESP32:LOW" else null
        val lowText = if (low) " LOW" else ""
        val runtime = if (runtimeMinutes >= 0 && !onUsb) " " + runtimeText(runtimeMinutes) else ""
        return "ESP32:$percent%$lowText$runtime"
    }

    companion object {
        const val COMPANY_ID = 0xFFFF
        private const val TAG_M = 'M'.code.toByte()
        private const val TAG_B = 'B'.code.toByte()

        /** Filter prefix for screen-off scans: 'M' 'B' after the company id. */
        val FILTER_DATA = byteArrayOf(TAG_M, TAG_B)
        val FILTER_MASK = byteArrayOf(0xFF.toByte(), 0xFF.toByte())

        /** [data] = the manufacturer data AFTER the 0xFFFF company id (as Android's ScanRecord gives it). */
        fun parse(data: ByteArray?): Esp32Heartbeat? {
            if (data == null || data.size < 7) return null
            if (data[0] != TAG_M || data[1] != TAG_B || data[2].toInt() and 0xFF < 1) return null
            val pctRaw = data[3].toInt() and 0xFF
            val flags = data[4].toInt() and 0xFF
            val run = (data[5].toInt() and 0xFF) or ((data[6].toInt() and 0xFF) shl 8)
            return Esp32Heartbeat(
                percent = if (pctRaw == 0xFF) -1 else pctRaw.coerceIn(0, 100),
                charging = flags and 0x01 != 0,
                onUsb = flags and 0x02 != 0,
                hasBattery = flags and 0x04 != 0,
                runtimeMinutes = if (run == 0xFFFF) -1 else run,
                low = flags and 0x08 != 0,
            )
        }

        /** "~45M", "~9H 40M", "~99H+" (matches the iPhone app). */
        fun runtimeText(minutes: Int): String {
            val total = minutes.coerceAtLeast(0)
            if (total >= 99 * 60) return "~99H+"
            if (total < 60) return "~${total}M"
            return "~${total / 60}H ${total % 60}M"
        }
    }
}
