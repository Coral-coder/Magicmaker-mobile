package com.magicmaker.android.ble

import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.relay.RelayProtocol

class BleScanner(
    private val onDisneyPacket: (hex: String, rssi: Int) -> Unit,
    private val onRelayCommand: ((hex: String, durationMs: Int) -> Unit)? = null,
    private val onScanFailed: ((Int) -> Unit)? = null,
) {
    private var scanning = false
    private var callback: ScanCallback? = null

    val isScanning: Boolean get() = scanning

    fun buildCallback(): ScanCallback {
        return object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handleResult(result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { handleResult(it) }
            }

            override fun onScanFailed(errorCode: Int) {
                scanning = false
                onScanFailed?.invoke(errorCode)
            }
        }.also { callback = it }
    }

    fun scanSettings(screenOn: Boolean = true): ScanSettings = ScanSettings.Builder()
        .setScanMode(
            if (screenOn) ScanSettings.SCAN_MODE_LOW_LATENCY
            else ScanSettings.SCAN_MODE_BALANCED,
        )
        .setReportDelay(0)
        .setMatchMode(
            if (screenOn) ScanSettings.MATCH_MODE_AGGRESSIVE
            else ScanSettings.MATCH_MODE_STICKY,
        )
        .build()

    fun scanFilters(): List<ScanFilter> = emptyList()

    fun markStarted() { scanning = true }
    fun markStopped() { scanning = false }

    private fun handleResult(result: ScanResult) {
        val record = result.scanRecord ?: return

        record.deviceName?.let { name ->
            HexUtils.hexFromMagicMakerLocalName(name)?.let { hex ->
                onRelayCommand?.invoke(hex, 0)
                return
            }
        }

        var skipRelay = false
        record.serviceUuids?.forEach { parcelUuid ->
            if (parcelUuid.uuid.toString().equals(RelayProtocol.SERVICE_UUID, ignoreCase = true)) {
                skipRelay = true
            }
        }
        if (skipRelay) return

        val hex = HexUtils.pickBestDisneyHex(HexUtils.collectDisneyHexCandidates(record)) ?: return
        onDisneyPacket(hex, result.rssi)
    }
}
