package com.magicmaker.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences("magicmaker", Context.MODE_PRIVATE)
        val wasRunning = prefs.getBoolean("service_was_started", false)
        val startOnBoot = prefs.getBoolean(MagicMakerForegroundService.PREF_START_ON_BOOT, true)
        if (wasRunning && startOnBoot) {
            MagicMakerForegroundService.start(context)
        }
    }
}
