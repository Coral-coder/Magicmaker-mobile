package com.magicmaker.android.ui.vfd

import com.magicmaker.android.service.ServiceState

/**
 * DIAG tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/diag.py is
 * ported: a panel with live readings and a button that opens the standard DIAG screen in a sheet.
 */
object VFDDiagScreen : VFDScreen {
    override val title: String = "DIAG"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val ble: String = when {
            !s.running -> "OFF"
            s.scanActive -> "SCAN"
            else -> "LINK"
        }
        val readings: List<Pair<String, String>> = listOf(
            "BLE" to ble,
            "RX" to s.packetsHeard.toString(),
            "SOURCES" to s.sources.size.toString(),
        )
        return VFDStub.draw(ctx, tab = "diag", label = "DIAG", readings = readings)
    }
}
