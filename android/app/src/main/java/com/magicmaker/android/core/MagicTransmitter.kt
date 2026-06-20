package com.magicmaker.android.core

import com.magicmaker.android.ble.BleAdvertiser

/**
 * Single transmit API — esp32_magicband timing for all MagicBand commands.
 *
 * - Band commands: always 520ms wakeup ping → 2000ms command
 * - Standalone ping only: 2000ms (no double-ping)
 * - Starlight wand: configurable burst (default 500ms), no band wakeup
 */
class MagicTransmitter(
    private val ble: BleAdvertiser,
    private val wakeupPreludeMs: () -> Int = { TransmitTiming.DEFAULT_WAKEUP_PRELUDE_MS },
    private val commandBurstMs: () -> Int = { TransmitTiming.COMMAND_BURST_MS },
    private val starlightBurstMs: () -> Int = { TransmitTiming.STARLIGHT_BURST_MS },
) {
    fun ping(onComplete: () -> Unit = {}) {
        ble.burst(PacketBuilder.WAKEUP_PING, TransmitTiming.PING_BURST_MS, onComplete)
    }

    fun vibrateBand(onComplete: () -> Unit = {}) {
        sendBandCommand(PacketBuilder.vibrateBand(), onComplete)
    }

    fun rainbowVibrate(onComplete: () -> Unit = {}) {
        sendBandCommand(PacketBuilder.rainbowFinale(), onComplete)
    }

    /** Any MagicBand packet (presets, lab hex, auto-response). */
    fun send(hex: String, onComplete: () -> Unit = {}) {
        val canonical = HexUtils.canonicalHex(hex)
        when {
            isStarlight(canonical) -> {
                val burst = starlightBurstMs().coerceIn(
                    TransmitTiming.MIN_STARLIGHT_BURST_MS,
                    TransmitTiming.MAX_STARLIGHT_BURST_MS,
                )
                ble.burst(canonical, burst, onComplete)
            }
            isStandalonePing(canonical) -> ble.burst(canonical, TransmitTiming.PING_BURST_MS, onComplete)
            else -> sendBandCommand(canonical, onComplete)
        }
    }

    fun sendSequence(hexes: List<String>, onComplete: () -> Unit = {}) {
        val list = hexes.map { HexUtils.canonicalHex(it) }.filter { it.isNotEmpty() }
        if (list.isEmpty()) {
            onComplete()
            return
        }
        fun sendAt(index: Int) {
            if (index >= list.size) {
                onComplete()
                return
            }
            send(list[index]) { sendAt(index + 1) }
        }
        sendAt(0)
    }

    private fun sendBandCommand(hex: String, onComplete: () -> Unit) {
        val prelude = wakeupPreludeMs().coerceIn(200, 1500)
        val burst = commandBurstMs().coerceIn(TransmitTiming.MIN_COMMAND_BURST_MS, TransmitTiming.MAX_COMMAND_BURST_MS)
        ble.burst(PacketBuilder.WAKEUP_PING, prelude) {
            ble.burst(hex, burst, onComplete)
        }
    }

    private fun isStandalonePing(hex: String): Boolean =
        hex.equals(PacketBuilder.WAKEUP_PING, ignoreCase = true) ||
            MagicClassifier.classify(hex)?.typeInfo == "ping"

    private fun isStarlight(hex: String): Boolean = HexUtils.isStarlightPacket(hex)
}
