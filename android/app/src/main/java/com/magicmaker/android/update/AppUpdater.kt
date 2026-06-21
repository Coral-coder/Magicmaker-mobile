package com.magicmaker.android.update

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import com.magicmaker.android.BuildConfig
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * Over-the-air updates straight from this repo's GitHub Releases — no Firebase.
 *
 * The APK embeds a fine-grained, read-only Personal Access Token (BuildConfig.UPDATE_TOKEN,
 * injected at build time, never committed) so it can read the private repo's latest
 * release, download the signed APK asset, and launch the installer.
 *
 * Requires the release builds to be signed with a STABLE key, or Android will reject
 * the update (signature mismatch). No-ops when no token is baked in (local/debug builds).
 */
object AppUpdater {
    private const val TAG = "AppUpdater"
    private const val API = "https://api.github.com"

    private data class Release(val tag: String, val assetUrl: String, val assetName: String)

    fun checkForUpdate(activity: Activity) {
        val token = BuildConfig.UPDATE_TOKEN
        val repo = BuildConfig.UPDATE_REPO
        if (token.isBlank() || repo.isBlank()) {
            Log.i(TAG, "OTA not configured (no update token baked in).")
            return
        }
        Thread {
            val rel = runCatching { fetchLatest(repo, token) }.getOrElse {
                Log.w(TAG, "OTA check failed", it); null
            } ?: return@Thread
            // Tags are monotonic, so a different tag than the one we were built from = newer.
            if (rel.tag.isBlank() || rel.tag == BuildConfig.VERSION_NAME || rel.assetUrl.isBlank()) return@Thread
            activity.runOnUiThread { if (!activity.isFinishing) promptInstall(activity, rel, token) }
        }.start()
    }

    private fun fetchLatest(repo: String, token: String): Release? {
        val conn = (URL("$API/repos/$repo/releases/latest").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            connectTimeout = 15000
            readTimeout = 15000
        }
        val body = conn.successStreamOrNull()?.use { it.bufferedReader().readText() } ?: return null
        val json = JSONObject(body)
        val tag = json.optString("tag_name")
        val assets = json.optJSONArray("assets")
        var url = ""
        var name = ""
        if (assets != null) {
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                if (a.optString("name").endsWith(".apk", ignoreCase = true)) {
                    url = a.optString("url")
                    name = a.optString("name")
                    break
                }
            }
        }
        return Release(tag, url, name)
    }

    private fun promptInstall(activity: Activity, rel: Release, token: String) {
        AlertDialog.Builder(activity)
            .setTitle("Update available")
            .setMessage("${rel.tag} is available (installed: ${BuildConfig.VERSION_NAME}). Download and install?")
            .setPositiveButton("Update") { _, _ ->
                Toast.makeText(activity, "Downloading ${rel.tag}…", Toast.LENGTH_SHORT).show()
                Thread {
                    val apk = runCatching { downloadAsset(activity, rel, token) }.getOrElse {
                        Log.w(TAG, "OTA download failed", it); null
                    }
                    activity.runOnUiThread {
                        if (apk != null) launchInstaller(activity, apk)
                        else Toast.makeText(activity, "Update download failed", Toast.LENGTH_LONG).show()
                    }
                }.start()
            }
            .setNegativeButton("Later", null)
            .show()
    }

    private fun downloadAsset(activity: Activity, rel: Release, token: String): File {
        // The asset API URL with octet-stream returns a 302 to a signed CDN URL; the
        // redirect must be followed WITHOUT the GitHub auth header (the CDN rejects it).
        var conn = (URL(rel.assetUrl).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false
            requestMethod = "GET"
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/octet-stream")
            connectTimeout = 15000
            readTimeout = 60000
        }
        if (conn.responseCode in 300..399) {
            val location = conn.getHeaderField("Location")
            conn.disconnect()
            conn = (URL(location).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 15000
                readTimeout = 60000
            }
        }
        val dir = File(activity.cacheDir, "updates").also { it.mkdirs() }
        val out = File(dir, "update.apk")
        conn.inputStream.use { input -> out.outputStream().use { input.copyTo(it) } }
        conn.disconnect()
        return out
    }

    private fun launchInstaller(activity: Activity, apk: File) {
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { activity.startActivity(intent) }.onFailure {
            Toast.makeText(activity, "Can't open installer: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun HttpURLConnection.successStreamOrNull(): InputStream? =
        if (responseCode in 200..299) {
            inputStream
        } else {
            Log.w(TAG, "GitHub API HTTP $responseCode")
            runCatching { errorStream?.close() }
            null
        }
}
