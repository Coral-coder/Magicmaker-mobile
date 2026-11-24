package com.magicmaker.android.relay

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Undoes the system-wide Bluetooth rename that older relay builds did (they called
 * `adapter.setName("MagicMaker-Android")` and never put the old name back). The relay itself no
 * longer touches the adapter name; this only repairs phones left with [RelayProtocol.LEGACY_DEVICE_NAME].
 *
 * If the adapter still carries the legacy name, it is set back to the phone's own device name
 * (Settings.Global.DEVICE_NAME, else Build.MODEL). A phone the user deliberately named
 * "MagicMaker-Android" in Settings is left alone, as is any other name.
 */
object BluetoothNameRepair {
    /** Set once the adapter has accepted the restored name, so the repair (and its notice) runs once. */
    private val restored = AtomicBoolean(false)

    fun statusMessage(name: String): String = "Restored phone Bluetooth name to $name"

    /**
     * The name to restore, or null when nothing should change: the adapter name is not the legacy
     * one, or the phone's own name (settings name, else model) is blank or is the legacy name.
     */
    internal fun restoreTarget(adapterName: String?, settingsName: String?, model: String?): String? {
        // Exactly the name older builds set; anything else (even close to it) is the user's.
        if (adapterName != RelayProtocol.LEGACY_DEVICE_NAME) return null
        val target = (if (settingsName.isNullOrBlank()) model else settingsName)?.trim()
        if (target.isNullOrEmpty() || target == RelayProtocol.LEGACY_DEVICE_NAME) return null
        return target
    }

    /**
     * Restores the phone's Bluetooth name if an older build renamed it. Returns the restored name
     * the first time the adapter accepts it (for a one-off status notice), else null. Safe to call
     * repeatedly: needs BLUETOOTH_CONNECT on API 31+ and Bluetooth on, and never throws.
     */
    @SuppressLint("MissingPermission")
    fun repairIfRenamed(context: Context, adapter: BluetoothAdapter?): String? {
        if (adapter == null || restored.get()) return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        return runCatching {
            if (!adapter.isEnabled) return@runCatching null
            val settingsName = runCatching {
                Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            }.getOrNull()
            val target = restoreTarget(adapter.name, settingsName, Build.MODEL) ?: return@runCatching null
            // setName is asynchronous and returns false while Bluetooth is not fully on; retry later then.
            if (!adapter.setName(target)) return@runCatching null
            if (restored.compareAndSet(false, true)) target else null
        }.getOrNull()
    }
}
