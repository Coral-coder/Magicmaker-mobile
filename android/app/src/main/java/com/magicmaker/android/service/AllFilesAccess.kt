package com.magicmaker.android.service

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings

/**
 * "All files access" so the library can live at a fixed, user-editable path on
 * shared storage (/sdcard/MagicMaker) that survives uninstall and is reachable
 * over USB. On API 30+ this is MANAGE_EXTERNAL_STORAGE (granted via a Settings
 * screen); on older devices it falls back to the legacy WRITE permission.
 */
object AllFilesAccess {
    fun granted(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            context.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    /** Settings intent to grant all-files access (API 30+). Null on older devices (use runtime perm). */
    fun requestIntent(context: Context): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:${context.packageName}"),
            )
        } else {
            null
        }
}
