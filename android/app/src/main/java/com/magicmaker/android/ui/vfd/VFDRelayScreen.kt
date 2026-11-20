package com.magicmaker.android.ui.vfd

import com.magicmaker.android.core.RelayControlMode
import com.magicmaker.android.service.ServiceState

/**
 * RELAY tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/link.py (the
 * iPhone LINK tab; Android shows RELAY) is ported: a panel with live readings and a button that
 * opens the standard RELAY screen in a sheet.
 */
object VFDRelayScreen : VFDScreen {
    override val title: String = "RELAY"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val mode: String = when (s.relayMode) {
            RelayControlMode.STANDALONE -> "STANDALONE"
            RelayControlMode.WIFI_HOTSPOT -> "WIFI / IPHONE"
            RelayControlMode.BLE_GATT -> "BLE GATT / IPHONE"
        }
        val readings: List<Pair<String, String>> = listOf(
            "MODE" to mode,
            "LINK" to (if (s.relayLinked) "IPHONE" else "DOWN"),
            "STATUS" to VFDStub.value(s.status),
        )
        return VFDStub.draw(ctx, tab = "relay", label = "RELAY", readings = readings)
    }
}
