package com.magicmaker.android.ble

import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.relay.RelayProtocol

class BleScanner(
    private val onDisneyPacket: (hex: String, rssi: Int, address: String) -> Unit,
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
        // Low latency in both modes: auto-reply must hear triggers promptly even with
        // the screen off (the CPU is kept awake by the service's wake lock).
        .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
        .setReportDelay(0)
        .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
        .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
        .build()

    /**
     * Screen-off scanning REQUIRES a filter — Android drops results from unfiltered
     * scans while the screen is off, which previously killed background auto-reply.
     * We match any advertisement carrying Disney (0x0183) manufacturer data. Screen-on
     * stays unfiltered so we still catch service-data / UUID / raw-AD encodings too.
     */
    fun scanFilters(screenOn: Boolean = true): List<ScanFilter> {
        if (screenOn) return emptyList()
        return listOf(
            ScanFilter.Builder()
                .setManufacturerData(HexUtils.DISNEY_COMPANY_ID, byteArrayOf())
                .build(),
        )
    }

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
        // Advertiser (source) address. On Android 12+ this is usually a rotating
        // Resolvable Private Address, not the band's identity MAC. Reading it needs
        // BLUETOOTH_CONNECT (granted); guard against SecurityException just in case.
        val address = try {
            result.device?.address.orEmpty()
        } catch (_: SecurityException) {
            ""
        }
        onDisneyPacket(hex, result.rssi, address)
    }
}
