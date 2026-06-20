package com.magicmaker.android.ui

import android.content.Context
import com.magicmaker.android.core.LivePacketSection

/** Persists UI state across tab navigation. */
object UiPrefs {
    private const val PREFS = "magicmaker_ui"
    private const val KEY_SCAN_COLLAPSED = "scan_collapsed_sections"
    private const val KEY_TX_COLLAPSED = "tx_collapsed_sections"
    private const val KEY_LAB_TX_SETTINGS_COLLAPSED = "lab_tx_settings_collapsed"
    private const val KEY_TX_LOOP_SETTINGS_COLLAPSED = "tx_loop_settings_collapsed"

    fun isLabTransmissionSettingsCollapsed(context: Context): Boolean =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_LAB_TX_SETTINGS_COLLAPSED, false)

    fun saveLabTransmissionSettingsCollapsed(context: Context, collapsed: Boolean) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_LAB_TX_SETTINGS_COLLAPSED, collapsed)
            .apply()
    }

    fun isTxLoopSettingsCollapsed(context: Context): Boolean =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_TX_LOOP_SETTINGS_COLLAPSED, true)

    fun saveTxLoopSettingsCollapsed(context: Context, collapsed: Boolean) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_TX_LOOP_SETTINGS_COLLAPSED, collapsed)
            .apply()
    }

    fun loadCollapsedScan(context: Context): Set<LivePacketSection> =
        loadSectionSet(context, KEY_SCAN_COLLAPSED)

    fun saveCollapsedScan(context: Context, collapsed: Set<LivePacketSection>) {
        saveSectionSet(context, KEY_SCAN_COLLAPSED, collapsed)
    }

    fun loadCollapsedTx(context: Context): Set<LivePacketSection> =
        loadSectionSet(context, KEY_TX_COLLAPSED)

    fun saveCollapsedTx(context: Context, collapsed: Set<LivePacketSection>) {
        saveSectionSet(context, KEY_TX_COLLAPSED, collapsed)
    }

    private fun loadSectionSet(context: Context, key: String): Set<LivePacketSection> {
        val raw = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(key, emptySet()) ?: emptySet()
        return raw.mapNotNull { name ->
            runCatching { LivePacketSection.valueOf(name) }.getOrNull()
        }.toSet()
    }

    private fun saveSectionSet(context: Context, key: String, sections: Set<LivePacketSection>) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putStringSet(key, sections.map { it.name }.toSet())
            .apply()
    }
}
