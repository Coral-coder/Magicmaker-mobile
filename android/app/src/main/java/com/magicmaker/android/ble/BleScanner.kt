package com.magicmaker.android.ble

import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import com.magicmaker.android.core.CrashLog
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.relay.RelayProtocol

class BleScanner(
    private val onDisneyPacket: (hex: String, rssi: Int, address: String) -> Unit,
    private val onRelayCommand: ((hex: String, durationMs: Int) -> Unit)? = null,
    private val onScanFailed: ((Int) -> Unit)? = null,
    /** The ESP32 transmitter's battery heartbeat (firmware 1.4+), read from its adverts, with the
     *  board's address (it sends its Disney packets from the same address). */
    private val onEsp32Heartbeat: ((Esp32Heartbeat, String) -> Unit)? = null,
) {
    private var scanning = false
    private var callback: ScanCallback? = null

    val isScanning: Boolean get() = scanning

    fun buildCallback(): ScanCallback {
        return object : ScanCallback() {
            // A malformed advertisement from ANY nearby device must never crash the toy or
            // kill scanning — swallow per-result parse failures and keep listening.
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                runCatching { handleResult(result) }.onFailure { CrashLog.record(it, "onScanResult") }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { r -> runCatching { handleResult(r) }.onFailure { CrashLog.record(it, "onBatchScanResults") } }
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
            // The ESP32 transmitter's battery heartbeat (0xFFFF 'M' 'B' ...).
            ScanFilter.Builder()
                .setManufacturerData(Esp32Heartbeat.COMPANY_ID, Esp32Heartbeat.FILTER_DATA, Esp32Heartbeat.FILTER_MASK)
                .build(),
        )
    }

    fun markStarted() { scanning = true }
    fun markStopped() { scanning = false }

    private fun handleResult(result: ScanResult) {
        val record = result.scanRecord ?: return

        // Our own ESP32 transmitter's battery heartbeat: report it, never treat it as a packet.
        Esp32Heartbeat.parse(record.getManufacturerSpecificData(Esp32Heartbeat.COMPANY_ID))?.let { hb ->
            val address = try {
                result.device?.address.orEmpty()
            } catch (_: SecurityException) {
                ""
            }
            onEsp32Heartbeat?.invoke(hb, address)
            return
        }

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
