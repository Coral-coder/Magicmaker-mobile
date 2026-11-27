package com.magicmaker.android.sync

// Per-central state of the relay GATT server's SYNC characteristic (docs/SYNC_P3_ANDROID_PLAN.md
// §5.5), pure and tested; RelayGattServer only copies callback values and posts them here (on
// mm-sync). A session link exists while the central's CCCD on SYNC is enabled: 01 00 -> link up
// (MTU = that device's last onMtuChanged, else 23), 00 00 or a disconnect -> link down.

sealed class ServerLinkEvent {
    data class Up(val address: String, val linkId: String, val mtu: Int) : ServerLinkEvent()
    data class Down(val address: String, val linkId: String) : ServerLinkEvent()
    data class Mtu(val linkId: String, val mtu: Int) : ServerLinkEvent()
    data class Frame(val linkId: String, val bytes: ByteArray) : ServerLinkEvent()
    data class Sent(val linkId: String) : ServerLinkEvent()
}

class GattServerLinks {
    private class Dev(var mtu: Int? = null, var cccd: Boolean = false, var linkId: String? = null)

    private val devs = LinkedHashMap<String, Dev>()

    /** Centrals connected to the GATT server (any characteristic). */
    fun connectedCount(): Int = devs.size

    fun isConnected(address: String): Boolean = norm(address) in devs

    fun linkIds(): List<String> = devs.values.mapNotNull { it.linkId }

    fun linkFor(address: String): String? = devs[norm(address)]?.linkId

    fun addressFor(linkId: String): String? = devs.entries.firstOrNull { it.value.linkId == linkId }?.key

    fun mtuOf(address: String): Int = devs[norm(address)]?.mtu ?: SyncConst.MTU_MIN

    /** The stored CCCD value for a descriptor read. */
    fun cccdValue(address: String): ByteArray = if (devs[norm(address)]?.cccd == true) byteArrayOf(1, 0) else byteArrayOf(0, 0)

    fun onConnected(address: String): List<ServerLinkEvent> {
        devs.getOrPut(norm(address)) { Dev() }
        return emptyList()
    }

    fun onDisconnected(address: String): List<ServerLinkEvent> {
        val a = norm(address)
        val d = devs.remove(a) ?: return emptyList()
        return d.linkId?.let { listOf(ServerLinkEvent.Down(a, it)) } ?: emptyList()
    }

    fun onMtu(address: String, mtu: Int): List<ServerLinkEvent> {
        val d = devs.getOrPut(norm(address)) { Dev() }
        d.mtu = mtu.coerceIn(SyncConst.MTU_MIN, SyncConst.MTU_MAX)
        return d.linkId?.let { listOf(ServerLinkEvent.Mtu(it, d.mtu!!)) } ?: emptyList()
    }

    /** A CCCD write on SYNC: notifications (or indications) on -> link up; off -> link down. */
    fun onCccd(address: String, value: ByteArray?): List<ServerLinkEvent> {
        val a = norm(address)
        val on = value != null && value.isNotEmpty() && (value[0].toInt() and 0x03) != 0
        // Off for a device that is gone (a late close after its disconnect) must not re-add it.
        val d = if (on) devs.getOrPut(a) { Dev() } else (devs[a] ?: return emptyList())
        if (on && !d.cccd) {
            d.cccd = true
            val id = "ios:$a"
            d.linkId = id
            return listOf(ServerLinkEvent.Up(a, id, d.mtu ?: SyncConst.MTU_MIN))
        }
        if (!on && d.cccd) {
            d.cccd = false
            val id = d.linkId
            d.linkId = null
            return id?.let { listOf(ServerLinkEvent.Down(a, it)) } ?: emptyList()
        }
        return emptyList()
    }

    /** A write to SYNC: one ATT value for that device's link (dropped while its CCCD is off). */
    fun onWrite(address: String, value: ByteArray?): List<ServerLinkEvent> {
        val id = devs[norm(address)]?.linkId ?: return emptyList()
        if (value == null || value.isEmpty()) return emptyList()
        return listOf(ServerLinkEvent.Frame(id, value.copyOf()))
    }

    fun onNotificationSent(address: String): List<ServerLinkEvent> {
        val id = devs[norm(address)]?.linkId ?: return emptyList()
        return listOf(ServerLinkEvent.Sent(id))
    }

    /** Bluetooth off / server stop: every link goes down. */
    fun clear(): List<ServerLinkEvent> {
        val out = devs.entries.mapNotNull { (a, d) -> d.linkId?.let { ServerLinkEvent.Down(a, it) } }
        devs.clear()
        return out
    }

    companion object {
        fun norm(a: String): String = a.trim().uppercase()
    }
}

/**
 * Which LE links the relay GATT server hears about are centrals of this relay (plan §5.5). Android
 * reports every LE connection of the phone to every registered GATT server: this phone's own
 * client links (HubClient to the ESP32, another app's smartwatch or fitness band) arrive as
 * "connected" too. A connection alone is therefore not an iPhone: a device becomes a central once
 * it makes its first ATT request on the relay service (a read, a write, a CCCD write). Only those
 * stop the relay advertising, count as "iPhone linked", start the UPDATE APP clock and reach the
 * SYNC endpoint; an MTU heard before that is held and passed on with the connect. Thread-safe
 * (GATT binder threads); pure and tested.
 */
class RelayCentrals {
    sealed class Out {
        data class Connected(val address: String) : Out()
        data class Mtu(val address: String, val mtu: Int) : Out()
        data class Disconnected(val address: String) : Out()
    }

    private class Dev(var engaged: Boolean = false, var mtu: Int? = null)

    private val devs = LinkedHashMap<String, Dev>()

    @Synchronized
    fun onConnected(address: String) {
        dev(address)
    }

    @Synchronized
    fun onMtu(address: String, mtu: Int): List<Out> {
        val a = GattServerLinks.norm(address)
        val d = dev(a)
        d.mtu = mtu
        return if (d.engaged) listOf(Out.Mtu(a, mtu)) else emptyList()
    }

    /** An ATT request on the relay service: the first one makes [address] a central. */
    @Synchronized
    fun onRequest(address: String): List<Out> {
        val a = GattServerLinks.norm(address)
        val d = dev(a)
        if (d.engaged) return emptyList()
        d.engaged = true
        return listOfNotNull(Out.Connected(a), d.mtu?.let { Out.Mtu(a, it) })
    }

    @Synchronized
    fun onDisconnected(address: String): List<Out> {
        val a = GattServerLinks.norm(address)
        val d = devs.remove(a) ?: return emptyList()
        return if (d.engaged) listOf(Out.Disconnected(a)) else emptyList()
    }

    @Synchronized
    fun engagedCount(): Int = devs.values.count { it.engaged }

    @Synchronized
    fun isEngaged(address: String): Boolean = devs[GattServerLinks.norm(address)]?.engaged == true

    @Synchronized
    fun clear() {
        devs.clear()
    }

    private fun dev(address: String): Dev {
        val a = GattServerLinks.norm(address)
        devs[a]?.let { return it }
        // Links that never report a disconnect here (filtered own links) must not pile up.
        if (devs.size >= MAX_DEVICES) devs.entries.firstOrNull { !it.value.engaged }?.let { devs.remove(it.key) }
        return Dev().also { devs[a] = it }
    }

    companion object {
        const val MAX_DEVICES: Int = 32
    }
}
