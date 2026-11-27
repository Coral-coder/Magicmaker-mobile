package com.magicmaker.android.sync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.PowerManager
import com.magicmaker.android.core.CrashLog

/**
 * This phone's battery for its heartbeat (spec §9.1, plan §5.6): CAPACITY %, EXTRA_VOLTAGE mV,
 * charging from EXTRA_STATUS / EXTRA_PLUGGED, power save (state bit5) and the §9.4 runtime
 * estimate. The sticky ACTION_BATTERY_CHANGED receiver runs on the mm-sync [handler]; a change that
 * matters for the HB (charging, a 1 % step, power save) calls [onChange]. No permission needed.
 */
class BatteryInfo(
    private val ctx: Context,
    private val handler: Handler,
    private val estimator: RuntimeEstimatorPort,
    private val now: () -> Long,
    private val onChange: () -> Unit,
) {
    @Volatile var pct: Int = -1
        private set
    @Volatile var mv: Int = -1
        private set
    @Volatile var charging: Boolean? = null
        private set
    @Volatile var powerSave: Boolean = false
        private set
    @Volatile var runtimeMin: Int = -1
        private set

    private var registered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            // Runs on the mm-sync looper: an exception here would end the process, not one sync step.
            try {
                when (intent?.action) {
                    Intent.ACTION_BATTERY_CHANGED -> update(intent)
                    PowerManager.ACTION_POWER_SAVE_MODE_CHANGED -> {
                        val ps = readPowerSave()
                        if (ps != powerSave) {
                            powerSave = ps
                            onChange()
                        }
                    }
                }
            } catch (t: Throwable) {
                CrashLog.record(t, "BatteryInfo ${intent?.action}")
            }
        }
    }

    fun start() {
        if (registered) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        }
        val sticky = runCatching {
            if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(receiver, filter, null, handler, Context.RECEIVER_NOT_EXPORTED)
            else ctx.registerReceiver(receiver, filter, null, handler)
        }.getOrNull()
        registered = true
        powerSave = readPowerSave()
        update(sticky)
    }

    fun stop() {
        if (!registered) return
        registered = false
        runCatching { ctx.unregisterReceiver(receiver) }
    }

    /** Feed the estimator once a minute even when the level did not change. */
    fun sample() {
        if (pct >= 0) runtimeMin = estimator.sample(now(), pct, charging == true)
    }

    fun snapshot(): SelfBattery = SelfBattery(pct, mv, charging, runtimeMin, powerSave)

    private fun readPowerSave(): Boolean =
        runCatching { (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).isPowerSaveMode }.getOrDefault(false)

    private fun update(i: Intent?) {
        val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        var p = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)?.takeIf { it in 0..100 } ?: -1
        if (p < 0 && i != null) {
            val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            if (level >= 0 && scale > 0) p = (level * 100 / scale).coerceIn(0, 100)
        }
        val volt = i?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)?.takeIf { it in 1..0x7FFF } ?: mv
        val status = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val plugged = i?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val chg: Boolean? = when {
            i == null -> charging
            status == BatteryManager.BATTERY_STATUS_CHARGING -> true
            status == BatteryManager.BATTERY_STATUS_FULL && plugged != 0 -> true
            status == -1 -> plugged != 0
            else -> false
        }
        val changed = chg != charging || p != pct
        pct = p
        mv = volt
        charging = chg
        if (p >= 0) runtimeMin = estimator.sample(now(), p, chg == true)
        if (changed) onChange()
    }
}
