package com.magicmaker.android.relay

import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.magicmaker.android.sync.AdvSpec
import com.magicmaker.android.sync.Bytes
import com.magicmaker.android.sync.RelayAdvPolicy
import com.magicmaker.android.sync.SyncNotifier
import com.magicmaker.android.sync.SyncServerEndpoint
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * The phone's relay GATT server: TRANSMIT / COMMAND / STATUS / CATALOG for the iPhone app, plus
 * SYNC (A7830006, docs/SYNC_P3_ANDROID_PLAN.md §5.5), the iPhone's direct sync link. SYNC callbacks
 * only copy the value and hand it to [syncEndpoint] (which posts to mm-sync); notifications go out
 * from mm-sync through [notifySync]. Advertising follows [RelayAdvPolicy]: the group tag in the
 * primary ADV, LOW_LATENCY for 60 s after a start or a disconnect, then BALANCED, off while any
 * central is connected, paused for manufacturer bursts.
 */
class RelayGattServer(
    context: Context,
    private val bluetoothManager: BluetoothManager,
    private val onTransmit: (hex: String, durationMs: Int) -> Unit,
    private val onStatus: (String) -> Unit,
    private val commandHandlers: RelayCommands.Handlers,
    private val syncEndpoint: SyncServerEndpoint? = null,
    /** The sync group id (its first two bytes go in the advert tag), or null while ungrouped. */
    private val groupId: () -> ByteArray? = { null },
    /**
     * True for this phone's own outgoing client link (HubClient to the ESP32): Android reports
     * those to the server callback too, and they are not a central of this relay.
     */
    private val ownClientLink: (address: String) -> Boolean = { false },
) : SyncNotifier {
    companion object {
        val SERVICE_UUID = UUID.fromString(RelayProtocol.SERVICE_UUID)
        val TRANSMIT_UUID = UUID.fromString(RelayProtocol.TRANSMIT_UUID)
        val COMMAND_UUID = UUID.fromString(RelayProtocol.COMMAND_UUID)
        val STATUS_UUID = UUID.fromString(RelayProtocol.STATUS_UUID)
        val CATALOG_UUID = UUID.fromString(RelayProtocol.CATALOG_UUID)
        val SYNC_UUID = UUID.fromString(RelayProtocol.SYNC_UUID)
        val CCCD_UUID = UUID.fromString(RelayProtocol.CCCD_UUID)
        /** ATT read-blob chunk size (iOS central auto-reads with offset until short chunk). */
        private const val GATT_READ_CHUNK = 512
    }

    private val appContext = context.applicationContext
    private var gattServer: BluetoothGattServer? = null
    private var connectableAdvertiser: BluetoothLeAdvertiser? = null
    private var connectableCallback: AdvertiseCallback? = null
    private var statusCharacteristic: BluetoothGattCharacteristic? = null
    private var catalogCharacteristic: BluetoothGattCharacteristic? = null
    @Volatile private var syncCharacteristic: BluetoothGattCharacteristic? = null
    /** Connected centrals by address (any characteristic), and their SYNC CCCD values. */
    private val devices = ConcurrentHashMap<String, BluetoothDevice>()
    private val cccdValues = ConcurrentHashMap<String, ByteArray>()
    private val advPolicy = RelayAdvPolicy()
    /** What is on the air now (main thread only). */
    private var advNow: AdvSpec = AdvSpec.OFF
    private val advApply = Runnable { applyAdvertisingNow() }
    private var statusBuffer: ByteArray = ByteArray(0)
    private var catalogBuffer: ByteArray = ByteArray(0)
    private var commandResponseBuffer: ByteArray = ByteArray(0)
    private var running = false

    /** No connected central means nothing can read STATUS/CATALOG — skip rebuilding them. */
    @Volatile private var clientConnected = false
    private val mainHandler = Handler(Looper.getMainLooper())

    fun start() {
        if (running) return
        val adapter = bluetoothManager.adapter ?: run {
            onStatus("Bluetooth off")
            return
        }
        if (!adapter.isEnabled) {
            onStatus("Bluetooth off")
            return
        }

        val serverCallback = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
                val address = addressOf(device)
                if (address != null && runCatching { ownClientLink(address) }.getOrDefault(false)) return
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        if (address != null && device != null) {
                            devices[address] = device
                            syncEndpoint?.onCentralConnected(address)
                        }
                        clientConnected = true
                        refreshCatalogBuffer()
                        refreshStatusCharacteristic()
                        onStatus("iPhone linked via BLE GATT")
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        if (address != null) {
                            devices.remove(address)
                            cccdValues.remove(address)
                            syncEndpoint?.onCentralDisconnected(address)
                        }
                        clientConnected = devices.isNotEmpty()
                        if (!clientConnected) onStatus("BLE GATT idle")
                    }
                }
                mainHandler.post {
                    advPolicy.setConnected(devices.size, SystemClock.uptimeMillis())
                    applyAdvertisingNow()
                }
            }

            override fun onMtuChanged(device: BluetoothDevice?, mtu: Int) {
                val address = addressOf(device) ?: return
                syncEndpoint?.onMtu(address, mtu)
            }

            override fun onNotificationSent(device: BluetoothDevice?, status: Int) {
                val address = addressOf(device) ?: return
                syncEndpoint?.onNotificationSent(address, status)
            }

            override fun onDescriptorWriteRequest(
                device: BluetoothDevice?,
                requestId: Int,
                descriptor: BluetoothGattDescriptor?,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray?,
            ) {
                val address = addressOf(device)
                val isSyncCccd = descriptor?.uuid == CCCD_UUID && descriptor?.characteristic?.uuid == SYNC_UUID
                if (!isSyncCccd || preparedWrite || address == null) {
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                    }
                    return
                }
                val v = value?.copyOf() ?: ByteArray(0)
                cccdValues[address] = if (v.size >= 2) v.copyOf(2) else byteArrayOf(0, 0)
                if (responseNeeded) gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                syncEndpoint?.onCccd(address, v)
            }

            override fun onDescriptorReadRequest(
                device: BluetoothDevice?,
                requestId: Int,
                offset: Int,
                descriptor: BluetoothGattDescriptor?,
            ) {
                val address = addressOf(device)
                val value = (address?.let { cccdValues[it] } ?: byteArrayOf(0, 0))
                if (offset > value.size) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                    return
                }
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value.copyOfRange(offset, value.size))
            }

            override fun onExecuteWrite(device: BluetoothDevice?, requestId: Int, execute: Boolean) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }

            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice?,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic?,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray?,
            ) {
                when (characteristic?.uuid) {
                    TRANSMIT_UUID -> handleTransmitWrite(device, requestId, responseNeeded, value)
                    COMMAND_UUID -> handleCommandWrite(device, requestId, responseNeeded, value)
                    SYNC_UUID -> handleSyncWrite(device, requestId, preparedWrite, responseNeeded, value)
                    else -> if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                    }
                }
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice?,
                requestId: Int,
                offset: Int,
                characteristic: BluetoothGattCharacteristic?,
            ) {
                val full = when (characteristic?.uuid) {
                    STATUS_UUID -> commandResponseBuffer.takeIf { it.isNotEmpty() } ?: statusBuffer
                    CATALOG_UUID -> catalogBuffer
                    else -> {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                        return
                    }
                }
                if (offset > full.size) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                    return
                }
                val chunk = gattReadChunk(full, offset)
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, chunk)
            }
        }

        gattServer = bluetoothManager.openGattServer(appContext, serverCallback)
        if (gattServer == null) {
            onStatus("GATT server failed — grant Bluetooth permissions")
            return
        }
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        val txChar = BluetoothGattCharacteristic(
            TRANSMIT_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val cmdChar = BluetoothGattCharacteristic(
            COMMAND_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val statChar = BluetoothGattCharacteristic(
            STATUS_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        val catChar = BluetoothGattCharacteristic(
            CATALOG_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        statusCharacteristic = statChar
        catalogCharacteristic = catChar
        refreshCatalogBuffer()
        refreshStatusCharacteristic()

        service.addCharacteristic(txChar)
        service.addCharacteristic(cmdChar)
        service.addCharacteristic(statChar)
        service.addCharacteristic(catChar)
        if (syncEndpoint != null) {
            val syncChar = BluetoothGattCharacteristic(
                SYNC_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            syncChar.addDescriptor(
                BluetoothGattDescriptor(CCCD_UUID, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE),
            )
            service.addCharacteristic(syncChar)
            syncCharacteristic = syncChar
        }
        if (gattServer?.addService(service) != true) {
            onStatus("GATT addService failed")
            stop()
            return
        }

        running = true
        syncEndpoint?.attach(this)
        mainHandler.post {
            advPolicy.start(SystemClock.uptimeMillis())
            applyAdvertisingNow()
        }
        onStatus("BLE GATT relay listening")
    }

    private fun addressOf(device: BluetoothDevice?): String? = try {
        device?.address?.uppercase()
    } catch (_: SecurityException) {
        null
    }

    private fun handleSyncWrite(
        device: BluetoothDevice?,
        requestId: Int,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        value: ByteArray?,
    ) {
        val address = addressOf(device)
        if (preparedWrite || address == null || syncEndpoint == null) {
            if (responseNeeded) gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, 0, null)
            return
        }
        if (value != null && value.isNotEmpty()) syncEndpoint.onSyncWrite(address, value.copyOf())
        if (responseNeeded) gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
    }

    /** One SYNC notification (mm-sync only). False = busy or failed; the channel retries. */
    override fun notifySync(address: String, value: ByteArray): Boolean {
        val server = gattServer ?: return false
        val chr = syncCharacteristic ?: return false
        val device = devices[address.uppercase()] ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                server.notifyCharacteristicChanged(device, chr, false, value) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                chr.value = value
                @Suppress("DEPRECATION")
                server.notifyCharacteristicChanged(device, chr, false)
            }
        } catch (_: SecurityException) {
            false
        } catch (_: RuntimeException) {
            false
        }
    }

    override fun disconnect(address: String) {
        val device = devices[address.uppercase()] ?: return
        try {
            gattServer?.cancelConnection(device)
        } catch (_: SecurityException) {
            // permission revoked: the link times out on its own
        }
    }

    /** The sync group changed: re-advertise with the new tag. */
    fun refreshAdvertising() {
        mainHandler.post {
            advNow = AdvSpec.OFF.copy(tag = Bytes.of(byteArrayOf(-1)))
            stopAdvertisingQuiet()
            applyAdvertisingNow()
        }
    }

    /** Main thread: make the air match [advPolicy]. */
    private fun applyAdvertisingNow() {
        mainHandler.removeCallbacks(advApply)
        val now = SystemClock.uptimeMillis()
        advPolicy.setGroup(groupId()?.let { Bytes.of(it) })
        val want = if (running) advPolicy.spec(now) else AdvSpec.OFF
        if (want != advNow) {
            stopAdvertisingQuiet()
            advNow = want
            if (want.on) {
                bluetoothManager.adapter?.let { startConnectableAdvertising(it, want) }
            }
        }
        advPolicy.nextChangeMs(now)?.let { mainHandler.postAtTime(advApply, it) }
    }

    private fun stopAdvertisingQuiet() {
        connectableCallback?.let { cb ->
            try {
                connectableAdvertiser?.stopAdvertising(cb)
            } catch (_: SecurityException) {
                // nothing on the air to stop
            } catch (_: IllegalStateException) {
                // Bluetooth turned off
            }
        }
        connectableCallback = null
    }

    fun refreshStatusCharacteristic() {
        statusBuffer = currentStatusBytes()
        publishStatusCharacteristicValue()
    }

    /** Drop a pending command/chunk JSON response after iPhone has had time to read it. */
    fun clearCommandResponse() {
        commandResponseBuffer = ByteArray(0)
        publishStatusCharacteristicValue()
    }

    private fun publishStatusCharacteristicValue() {
        val display = commandResponseBuffer.takeIf { it.isNotEmpty() } ?: statusBuffer
        statusCharacteristic?.value = display.copyOf(minOf(display.size, 512))
    }

    fun refreshCatalogBuffer() {
        // Serializing the whole catalog to JSON is not cheap, and publishState() calls this on
        // every status change. With no iPhone attached nothing can read the buffer, so skip it;
        // the connect handler rebuilds it as soon as one does.
        if (!clientConnected) return
        // Don't clobber a chunk response mirrored on CATALOG while iPhone is mid-sync.
        if (commandResponseBuffer.isNotEmpty() && commandResponseBufferContainsChunk()) return
        val json = commandHandlers.catalogJson().put("ok", true)
        catalogBuffer = json.toString().toByteArray(Charsets.UTF_8)
        catalogCharacteristic?.value = catalogBuffer.copyOf(minOf(catalogBuffer.size, 512))
    }

    private fun commandResponseBufferContainsChunk(): Boolean =
        commandResponseBuffer.size >= 8 &&
            commandResponseBuffer.toString(Charsets.UTF_8).contains("\"items\"")

    private fun currentStatusBytes(): ByteArray =
        commandHandlers.statusJson().toString().toByteArray(Charsets.UTF_8)

    private fun gattReadChunk(full: ByteArray, offset: Int): ByteArray {
        if (offset >= full.size) return ByteArray(0)
        val end = minOf(offset + GATT_READ_CHUNK, full.size)
        return full.copyOfRange(offset, end)
    }

    private fun handleTransmitWrite(
        device: BluetoothDevice?,
        requestId: Int,
        responseNeeded: Boolean,
        value: ByteArray?,
    ) {
        if (value == null) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH, 0, null)
            }
            return
        }
        val text = value.toString(Charsets.UTF_8)
        val parsed = RelayProtocol.parseTransmitPayload(text)
        if (parsed == null) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH, 0, null)
            }
            return
        }
        onTransmit(parsed.first, parsed.second)
        refreshStatusCharacteristic()
        if (responseNeeded) {
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }
    }

    private fun handleCommandWrite(
        device: BluetoothDevice?,
        requestId: Int,
        responseNeeded: Boolean,
        value: ByteArray?,
    ) {
        if (value == null) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH, 0, null)
            }
            return
        }
        val json = RelayCommands.parseBody(value.toString(Charsets.UTF_8))
        val result = if (json != null) {
            RelayCommands.execute(json, commandHandlers)
        } else {
            JSONObject().put("ok", false).put("error", "Invalid JSON")
        }
        commandResponseBuffer = result.toString().toByteArray(Charsets.UTF_8)
        publishStatusCharacteristicValue()
        // Chunk payloads may exceed 512 — mirror to CATALOG for iOS long-read fallback only.
        if (result.has("items") && result.has("section")) {
            catalogBuffer = commandResponseBuffer.copyOf()
            catalogCharacteristic?.value = catalogBuffer.copyOf(minOf(catalogBuffer.size, 512))
        }
        // Keep command JSON on STATUS until iPhone reads it. Chunked catalog_sync_* needs multiple round-trips.
        val resetDelayMs = when {
            result.has("transmitPresets") -> 8000L
            result.has("protocol") -> 30000L
            else -> 3000L
        }
        mainHandler.postDelayed({ clearCommandResponse() }, resetDelayMs)
        if (responseNeeded) {
            gattServer?.sendResponse(
                device,
                requestId,
                if (result.optBoolean("ok", false)) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                0,
                null,
            )
        }
    }

    /**
     * Connectable relay advertising. No device name anywhere, and the phone's Bluetooth name is
     * never changed (older builds called adapter.setName, renaming the phone system-wide; see
     * BluetoothNameRepair). Primary ADV: flags + the relay service UUID. Scan response: service
     * data on that UUID = RelayProtocol.RELAY_TAG ("MM_AND"), which the iPhone uses to tell this
     * relay apart from the ESP32 (same service, advertises the name "MM_ESP"). The UUID is
     * Bluetooth-Base derived, so the stack sends it in 32-bit form (service data 2 + 4 + 6 = 12
     * bytes); even as 128-bit it would be 2 + 16 + 6 = 24, within the 31-byte limit.
     */
    private fun startConnectableAdvertising(adapter: BluetoothAdapter, spec: AdvSpec) {
        connectableAdvertiser = adapter.bluetoothLeAdvertiser
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(if (spec.lowLatency) AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY else AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val serviceUuid = ParcelUuid(SERVICE_UUID)
        val tag = spec.tag.toByteArray()
        // Primary: flags + 32-bit UUID + service data (tag) = 3 + 6 + 14 = 23 bytes.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(serviceUuid)
            .addServiceData(serviceUuid, tag)
            .build()
        // The scan response repeats the tag for iPhone builds that read it there.
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(serviceUuid, tag)
            .build()

        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                onStatus("GATT advertise failed: $errorCode — retrying")
                mainHandler.postDelayed({
                    if (running && connectableCallback === this) {
                        advNow = AdvSpec.OFF
                        connectableCallback = null
                        applyAdvertisingNow()
                    }
                }, 1500)
            }
        }
        connectableCallback = cb
        try {
            connectableAdvertiser?.startAdvertising(settings, data, scanResponse, cb)
        } catch (_: SecurityException) {
            onStatus("GATT advertise failed — grant Bluetooth permissions")
        } catch (_: IllegalStateException) {
            onStatus("Bluetooth off")
        }
    }

    /** Before a manufacturer burst / keep-awake: off at once when called on the main thread (as before). */
    fun pauseConnectableAdvertising() = onMain {
        advPolicy.setPaused(true)
        applyAdvertisingNow()
    }

    /** After the burst: back on only when the policy allows (never while a central is connected). */
    fun resumeConnectableAdvertising() = onMain {
        advPolicy.setPaused(false)
        applyAdvertisingNow()
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }

    fun stop() {
        running = false
        mainHandler.removeCallbacks(advApply)
        advPolicy.stop()
        stopAdvertisingQuiet()
        advNow = AdvSpec.OFF
        syncEndpoint?.attach(null)
        syncEndpoint?.onServerStopped()
        gattServer?.close()
        gattServer = null
        statusCharacteristic = null
        catalogCharacteristic = null
        syncCharacteristic = null
        devices.clear()
        cccdValues.clear()
        clientConnected = false
    }
}
