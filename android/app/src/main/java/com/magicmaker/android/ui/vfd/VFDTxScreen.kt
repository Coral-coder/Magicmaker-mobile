package com.magicmaker.android.ui.vfd

import com.magicmaker.android.service.ServiceState

/**
 * TX tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/tx.py is ported:
 * a panel with live readings and a button that opens the standard TX screen in a sheet.
 */
object VFDTxScreen : VFDScreen {
    override val title: String = "TX"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val readings: List<Pair<String, String>> = listOf(
            "STATUS" to VFDStub.value(s.status),
            "LAST TX" to VFDStub.value(s.lastTransmitHex),
            "LOOP" to (if (s.txLoopEnabled) "ON" else "OFF"),
        )
        return VFDStub.draw(ctx, tab = "tx", label = "TX", readings = readings)
    }
}
