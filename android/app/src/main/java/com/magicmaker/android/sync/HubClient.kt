package com.magicmaker.android.sync

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import android.os.Handler
import com.magicmaker.android.core.CrashLog
import com.magicmaker.android.relay.RelayProtocol
import java.util.UUID

/**
 * Android as a BLE central to the ESP32 hub's SYNC characteristic (A7830006 on A7830001; docs/
 * SYNC_P3_ANDROID_PLAN.md §5.4). Performs the BluetoothGatt calls [HubLinkMachine] decides; all
 * callbacks arrive on the mm-sync [handler] (connectGatt's handler argument) and every GATT call is
 * made there. One outstanding operation; frame writes are write-without-response and the next one
 * waits for onCharacteristicWrite. Connection priority stays at the default (BALANCED).
 */
@SuppressLint("MissingPermission")
class HubClient(
    private val ctx: Context,
    private val bt: BluetoothManager,
    private val handler: Handler,
    private val sched: SyncScheduler,
    val machine: HubLinkMachine,
    private val listener: Listener,
) {
    interface Listener {
        fun onHubUp(link: FrameLink, mtu: Int)

        fun onHubDown(linkId: String)

        fun onHubFrame(linkId: String, value: ByteArray)

        fun onHubFrameSent(linkId: String)

        fun onHubMtu(linkId: String, mtu: Int)
    }

    private var gatt: BluetoothGatt? = null

    /** The ESP32 this client is connecting / connected to (read from binder threads). */
    @Volatile var currentAddress: String? = null
        private set
    private var chr: BluetoothGattCharacteristic? = null
    private var link: Link? = null
    private var tick: SyncCancel? = null
    private var running = false

    private inner class Link(val address: String) : FrameLink {
        override val id: String = "hub:$address"
        override val role: SessionRole get() = SessionRole.CENTRAL

        override fun mtu(): Int = machine.mtu

        override fun writeFrame(frame: ByteArray): Boolean {
            val g = gatt ?: return false
            val c = chr ?: return false
            if (link !== this) return false
            return try {
                if (Build.VERSION.SDK_INT >= 33) {
                    g.writeCharacteristic(c, frame, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    @Suppress("DEPRECATION")
                    c.value = frame
                    @Suppress("DEPRECATION")
                    g.writeCharacteristic(c)
                }
            } catch (e: SecurityException) {
                false
            }
        }

        override fun close(reason: String) = close(reason, null)

        override fun close(reason: String, retryMs: Long?) {
            if (link !== this) return
            exec(machine.onLocalClose(reason, retryMs, sched.now()))
        }
    }

    fun start() {
        if (running) return
        running = true
        exec(machine.start(sched.now()))
        scheduleTick()
    }

    fun stop() {
        running = false
        tick?.cancel()
        tick = null
        exec(machine.stop())
        closeGatt()
    }

    fun hubSeen(address: String, name: String?, rssi: Int) {
        if (!running || !HubLinkMachine.isHubName(name)) return
        exec(machine.hubSeen(address, name, rssi, sched.now()))
    }

    fun onAuthed() = machine.onAuthed()

    fun onForeign() = exec(machine.onForeign(sched.now()))

    fun info(): HubLinkInfo = machine.info(sched.now())

    private fun scheduleTick() {
        tick = sched.at(sched.now() + 1000) {
            if (!running) return@at
            exec(machine.tick(sched.now()))
            scheduleTick()
        }
    }

    private fun exec(cmds: List<HubCmd>) {
        for (c in cmds) {
            try {
                run(c)
            } catch (e: SecurityException) {
                CrashLog.record(e, "HubClient ${c::class.simpleName}")
                if (c !is HubCmd.Close && c !is HubCmd.LinkDown) {
                    exec(machine.onDisconnected(-1, sched.now()))
                    return
                }
            } catch (e: RuntimeException) {
                CrashLog.record(e, "HubClient ${c::class.simpleName}")
                if (c !is HubCmd.Close && c !is HubCmd.LinkDown) {
                    exec(machine.onDisconnected(-2, sched.now()))
                    return
                }
            }
        }
    }

    private fun run(c: HubCmd) {
        when (c) {
            is HubCmd.Connect -> {
                val adapter = bt.adapter
                if (adapter == null || !adapter.isEnabled) {
                    exec(machine.onDisconnected(-3, sched.now()))
                    return
                }
                closeGatt()
                currentAddress = c.address
                val device = adapter.getRemoteDevice(c.address)
                gatt = device.connectGatt(ctx, c.auto, callback, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, handler)
                if (gatt == null) exec(machine.onDisconnected(-4, sched.now()))
            }
            HubCmd.RequestMtu -> if (gatt?.requestMtu(HubLinkMachine.REQUEST_MTU) != true) {
                exec(machine.onMtu(SyncConst.MTU_MIN, false, sched.now()))
            }
            HubCmd.Discover -> if (gatt?.discoverServices() != true) exec(machine.onServices(false, false, sched.now()))
            HubCmd.EnableNotify -> enableNotify()
            is HubCmd.LinkUp -> {
                val l = Link(c.address)
                link = l
                listener.onHubUp(l, c.mtu)
            }
            is HubCmd.LinkDown -> {
                val l = link
                link = null
                if (l != null) listener.onHubDown(l.id)
            }
            is HubCmd.Close -> {
                val l = link
                link = null
                if (l != null) listener.onHubDown(l.id)
                closeGatt()
            }
        }
    }

    private fun enableNotify() {
        val g = gatt ?: return exec(machine.onNotifyEnabled(false, sched.now()))
        val c = chr ?: return exec(machine.onNotifyEnabled(false, sched.now()))
        if (!g.setCharacteristicNotification(c, true)) return exec(machine.onNotifyEnabled(false, sched.now()))
        val d = c.getDescriptor(CCCD_UUID) ?: return exec(machine.onNotifyEnabled(false, sched.now()))
        val value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        val ok = if (Build.VERSION.SDK_INT >= 33) {
            g.writeDescriptor(d, value) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            d.value = value
            @Suppress("DEPRECATION")
            g.writeDescriptor(d)
        }
        if (!ok) exec(machine.onNotifyEnabled(false, sched.now()))
    }

    private fun closeGatt() {
        val g = gatt ?: return
        gatt = null
        currentAddress = null
        chr = null
        try {
            g.disconnect()
        } catch (e: SecurityException) {
            // permission revoked: close below still frees the client slot
        }
        try {
            g.close()
        } catch (e: SecurityException) {
            // nothing more to do
        }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (g !== gatt) {
                try {
                    g.close()
                } catch (e: SecurityException) {
                    // stale client
                }
                return
            }
            when {
                newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS -> exec(machine.onConnected(sched.now()))
                newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS -> {
                    exec(machine.onDisconnected(status, sched.now()))
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (g !== gatt) return
            if (machine.phase == HubPhase.UP) {
                machine.onMtuLater(mtu)
                link?.let { listener.onHubMtu(it.id, machine.mtu) }
            } else {
                exec(machine.onMtu(mtu, status == BluetoothGatt.GATT_SUCCESS, sched.now()))
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (g !== gatt) return
            val c = g.getService(SERVICE_UUID)?.getCharacteristic(SYNC_UUID)
            chr = c
            exec(machine.onServices(c != null, status == BluetoothGatt.GATT_SUCCESS, sched.now()))
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (g !== gatt || descriptor.uuid != CCCD_UUID) return
            exec(machine.onNotifyEnabled(status == BluetoothGatt.GATT_SUCCESS, sched.now()))
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (g !== gatt || characteristic.uuid != SYNC_UUID) return
            link?.let { listener.onHubFrameSent(it.id) }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (g !== gatt || characteristic.uuid != SYNC_UUID) return
            link?.let { listener.onHubFrame(it.id, value.copyOf()) }
        }

        @Deprecated("API < 33")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= 33) return
            if (g !== gatt || characteristic.uuid != SYNC_UUID) return
            val v = characteristic.value?.copyOf() ?: return
            link?.let { listener.onHubFrame(it.id, v) }
        }
    }

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString(RelayProtocol.SERVICE_UUID)
        val SYNC_UUID: UUID = UUID.fromString(RelayProtocol.SYNC_UUID)
        val CCCD_UUID: UUID = UUID.fromString(RelayProtocol.CCCD_UUID)
    }
}
