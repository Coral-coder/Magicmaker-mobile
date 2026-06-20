package com.magicmaker.android.ble

import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean

/** Raw Disney manufacturer ADV bursts — timing/wakeup handled by [com.magicmaker.android.core.MagicTransmitter]. */
class BleAdvertiser(
    private val advertiser: BluetoothLeAdvertiser?,
    private val onStatus: (String) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    private var activeCallback: AdvertiseCallback? = null

    val isBusy: Boolean get() = busy.get()

    fun burst(hex: String, durationMs: Int, onComplete: () -> Unit) {
        val reject = com.magicmaker.android.core.HexUtils.legacyAdvertiseRejectReason(hex)
        if (reject != null) {
            onStatus(reject)
            onComplete()
            return
        }
        burstManufacturer(
            manufacturerId = com.magicmaker.android.core.HexUtils.DISNEY_COMPANY_ID,
            payload = com.magicmaker.android.core.HexUtils.disneyAdvertisePayload(hex),
            durationMs = durationMs,
            onComplete = onComplete,
        )
    }

    fun burstManufacturer(manufacturerId: Int, payload: ByteArray, durationMs: Int, onComplete: () -> Unit) {
        if (advertiser == null) {
            onStatus("BLE advertise unavailable")
            onComplete()
            return
        }
        if (payload.isEmpty()) {
            onStatus("Empty ADV payload")
            onComplete()
            return
        }
        if (!busy.compareAndSet(false, true)) {
            onStatus("Radio busy")
            onComplete()
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(manufacturerId, payload)
            .build()

        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                onStatus("TX ${durationMs}ms")
                handler.postDelayed({ stop(onComplete) }, durationMs.toLong())
            }

            override fun onStartFailure(errorCode: Int) {
                busy.set(false)
                onStatus("Advertise error $errorCode")
                onComplete()
            }
        }
        activeCallback = cb
        advertiser.startAdvertising(settings, data, cb)
    }

    fun stopAll() {
        stop {}
    }

    private fun stop(onComplete: () -> Unit) {
        activeCallback?.let { runCatching { advertiser?.stopAdvertising(it) } }
        activeCallback = null
        handler.postDelayed({
            busy.set(false)
            onComplete()
        }, com.magicmaker.android.core.TransmitTiming.RADIO_SETTLE_MS)
    }
}
