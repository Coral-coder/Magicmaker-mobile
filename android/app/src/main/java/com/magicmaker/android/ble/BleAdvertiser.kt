package com.magicmaker.android.ble

import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Raw Disney manufacturer ADV bursts — timing/wakeup handled by
 * [com.magicmaker.android.core.MagicTransmitter].
 *
 * Hardened so a burst doesn't silently vanish: if the radio is mid-settle it waits and
 * retries instead of dropping, and a failed startAdvertising is retried (incl. the common
 * ALREADY_STARTED race) before giving up. The goal is "a tap always goes on air."
 */
class BleAdvertiser(
    private val advertiser: BluetoothLeAdvertiser?,
    private val onStatus: (String) -> Unit,
    private val txPowerLevel: () -> Int = { AdvertiseSettings.ADVERTISE_TX_POWER_HIGH },
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
        attemptStart(manufacturerId, payload, durationMs, onComplete, tries = 0, busyWaits = 0)
    }

    private fun attemptStart(
        manufacturerId: Int,
        payload: ByteArray,
        durationMs: Int,
        onComplete: () -> Unit,
        tries: Int,
        busyWaits: Int,
    ) {
        // Wait (don't drop) if a previous burst is still settling.
        if (!busy.compareAndSet(false, true)) {
            if (busyWaits >= MAX_BUSY_WAITS) {
                onStatus("Radio busy — dropped")
                onComplete()
                return
            }
            handler.postDelayed(
                { attemptStart(manufacturerId, payload, durationMs, onComplete, tries, busyWaits + 1) },
                BUSY_WAIT_MS,
            )
            return
        }

        // Clean slate — clear any lingering advertise so we don't hit ALREADY_STARTED.
        activeCallback?.let { runCatching { advertiser?.stopAdvertising(it) } }
        activeCallback = null

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(
                txPowerLevel().coerceIn(
                    AdvertiseSettings.ADVERTISE_TX_POWER_ULTRA_LOW,
                    AdvertiseSettings.ADVERTISE_TX_POWER_HIGH,
                ),
            )
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
                activeCallback = null
                if (tries < MAX_START_RETRIES) {
                    onStatus("Advertise retry ($errorCode)")
                    handler.postDelayed(
                        { attemptStart(manufacturerId, payload, durationMs, onComplete, tries + 1, 0) },
                        START_RETRY_MS,
                    )
                } else {
                    onStatus("Advertise error $errorCode")
                    onComplete()
                }
            }
        }
        activeCallback = cb
        runCatching { advertiser?.startAdvertising(settings, data, cb) }.onFailure {
            busy.set(false)
            activeCallback = null
            if (tries < MAX_START_RETRIES) {
                handler.postDelayed(
                    { attemptStart(manufacturerId, payload, durationMs, onComplete, tries + 1, 0) },
                    START_RETRY_MS,
                )
            } else {
                onStatus("Advertise failed: ${it.message ?: "exception"}")
                onComplete()
            }
        }
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

    private companion object {
        const val MAX_BUSY_WAITS = 12      // ~1.2s of waiting for the radio to free up
        const val BUSY_WAIT_MS = 100L
        const val MAX_START_RETRIES = 3
        const val START_RETRY_MS = 180L
    }
}
