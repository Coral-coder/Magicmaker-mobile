package com.magicmaker.android.update

import android.app.Activity
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.appdistribution.FirebaseAppDistribution

/**
 * Over-the-air updates via Firebase App Distribution.
 *
 * Call [checkForUpdate] from an Activity (e.g. onResume). When a newer build has
 * been published to App Distribution for this tester, the SDK shows a built-in
 * dialog and handles download + install — no Play Store, no USB cable.
 *
 * Everything is guarded so the app runs normally when Firebase is not yet
 * configured (no google-services.json) or the SDK is unavailable.
 */
object AppUpdater {
    private const val TAG = "AppUpdater"

    fun checkForUpdate(activity: Activity) {
        if (FirebaseApp.getApps(activity).isEmpty()) {
            Log.i(TAG, "Firebase not configured; skipping OTA check.")
            return
        }
        try {
            FirebaseAppDistribution.getInstance()
                .updateIfNewReleaseAvailable()
                .addOnFailureListener { e -> Log.w(TAG, "OTA check failed", e) }
        } catch (t: Throwable) {
            Log.w(TAG, "OTA updater unavailable", t)
        }
    }
}
