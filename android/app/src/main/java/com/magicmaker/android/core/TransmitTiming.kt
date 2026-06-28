package com.magicmaker.android.core

/**
 * Transmit timing from [esp32_magicband](https://github.com/xxfunprojectsxx/esp32_magicband).
 *
 * sendWithWakeup: wakeup ping on air, then command burst.
 * Prelude bumped +100ms over esp32 default — band needs a touch longer to wake.
 */
object TransmitTiming {
    // Band commands interleave wake/command 1:1: COMMAND_BURST_MS is the TOTAL interleave
    // window; the wake prelude is the per-slice duration of each wake and each command burst.
    const val COMMAND_BURST_MS = 4000
    const val MIN_COMMAND_BURST_MS = 500
    const val MAX_COMMAND_BURST_MS = 12000
    const val PING_BURST_MS = 2000
    const val DEFAULT_WAKEUP_PRELUDE_MS = 520
    const val MIN_WAKEUP_PRELUDE_MS = 200
    const val MAX_WAKEUP_PRELUDE_MS = 3000
    /** @deprecated use [DEFAULT_WAKEUP_PRELUDE_MS] or runtime store value */
    const val WAKEUP_PRELUDE_MS = DEFAULT_WAKEUP_PRELUDE_MS
    const val WAKEUP_GAP_MS = 520L
    const val STARLIGHT_BURST_MS = 500
    const val MIN_STARLIGHT_BURST_MS = 250
    const val MAX_STARLIGHT_BURST_MS = 5000
    /** Gap after stopAdvertising before scan/advertise again. */
    const val RADIO_SETTLE_MS = 150L
    /** Extra delay before restarting scan after TX. */
    const val SCAN_RESUME_DELAY_MS = 200L
}
