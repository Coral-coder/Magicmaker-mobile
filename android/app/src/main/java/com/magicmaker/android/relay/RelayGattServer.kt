package com.magicmaker.android.relay

import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.ParcelUuid
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.util.UUID

class RelayGattServer(
    context: Context,
    private val bluetoothManager: BluetoothManager,
    private val onTransmit: (hex: String, durationMs: Int) -> Unit,
    private val onStatus: (String) -> Unit,
    private val commandHandlers: RelayCommands.Handlers,
) {
    companion object {
        val SERVICE_UUID = UUID.fromString(RelayProtocol.SERVICE_UUID)
        val TRANSMIT_UUID = UUID.fromString(RelayProtocol.TRANSMIT_UUID)
        val COMMAND_UUID = UUID.fromString(RelayProtocol.COMMAND_UUID)
        val STATUS_UUID = UUID.fromString(RelayProtocol.STATUS_UUID)
        val CATALOG_UUID = UUID.fromString(RelayProtocol.CATALOG_UUID)
        /** ATT read-blob chunk size (iOS central auto-reads with offset until short chunk). */
        private const val GATT_READ_CHUNK = 512
    }

    private val appContext = context.applicationContext
    private var gattServer: BluetoothGattServer? = null
    private var connectableAdvertiser: BluetoothLeAdvertiser? = null
    private var connectableCallback: AdvertiseCallback? = null
    private var statusCharacteristic: BluetoothGattCharacteristic? = null
    private var catalogCharacteristic: BluetoothGattCharacteristic? = null
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
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        clientConnected = true
                        refreshCatalogBuffer()
                        refreshStatusCharacteristic()
                        onStatus("iPhone linked via BLE GATT")
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        clientConnected = false
                        onStatus("BLE GATT idle")
                    }
                }
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
        if (gattServer?.addService(service) != true) {
            onStatus("GATT addService failed")
            stop()
            return
        }

        startConnectableAdvertising(adapter)
        running = true
        onStatus("BLE GATT relay listening")
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
    private fun startConnectableAdvertising(adapter: BluetoothAdapter) {
        connectableAdvertiser = adapter.bluetoothLeAdvertiser
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val serviceUuid = ParcelUuid(SERVICE_UUID)
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(serviceUuid)
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(serviceUuid, RelayProtocol.relayTagBytes())
            .build()

        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                onStatus("GATT advertise failed: $errorCode — retrying")
                mainHandler.postDelayed({
                    if (running) startConnectableAdvertising(adapter)
                }, 1500)
            }
        }
        connectableCallback = cb
        connectableAdvertiser?.startAdvertising(settings, data, scanResponse, cb)
    }

    fun pauseConnectableAdvertising() {
        connectableCallback?.let { cb ->
            connectableAdvertiser?.stopAdvertising(cb)
        }
    }

    fun resumeConnectableAdvertising() {
        val adapter = bluetoothManager.adapter ?: return
        if (running && connectableCallback != null) {
            startConnectableAdvertising(adapter)
        }
    }

    fun stop() {
        connectableCallback?.let { cb ->
            connectableAdvertiser?.stopAdvertising(cb)
        }
        connectableCallback = null
        gattServer?.close()
        gattServer = null
        statusCharacteristic = null
        catalogCharacteristic = null
        running = false
        clientConnected = false
    }
}
