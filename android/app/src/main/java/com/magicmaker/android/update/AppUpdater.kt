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
 * The repo is public, so the updater reads the latest release and downloads its APK asset
 * WITHOUT a token (unauthenticated GitHub API). A token is still used when one is baked in
 * (BuildConfig.UPDATE_TOKEN, only from -PmmUpdateToken on a local build, e.g. if the repo is
 * private again); if GitHub rejects it (401: revoked or expired) the check retries without it.
 *
 * Requires the release builds to be signed with a STABLE key, or Android will reject
 * the update (signature mismatch). No-ops in debug builds and when no update repo is configured.
 */
object AppUpdater {
    private const val TAG = "AppUpdater"
    private const val API = "https://api.github.com"

    /** [token]: what the release lookup authenticated with ("" = anonymous); the download uses it too. */
    private data class Release(val tag: String, val assetUrl: String, val assetName: String, val token: String)

    fun checkForUpdate(activity: Activity) {
        val token = BuildConfig.UPDATE_TOKEN.trim()
        val repo = BuildConfig.UPDATE_REPO
        if (repo.isBlank()) {
            Log.i(TAG, "OTA not configured (no update repo).")
            return
        }
        // A debug build is signed with a per-machine debug key, so Android would refuse the
        // release-signed APK anyway: stay quiet instead of offering it on every resume. (Before
        // the repo went public, debug builds had no token and were dormant the same way.)
        if (BuildConfig.DEBUG) {
            Log.i(TAG, "OTA off in debug builds.")
            return
        }
        Thread {
            val rel = runCatching { fetchLatest(repo, token) }.getOrElse {
                Log.w(TAG, "OTA check failed", it); null
            } ?: return@Thread
            // Tags are monotonic, so a different tag than the one we were built from = newer.
            if (rel.tag.isBlank() || rel.tag == BuildConfig.VERSION_NAME || rel.assetUrl.isBlank()) return@Thread
            activity.runOnUiThread { if (!activity.isFinishing) promptInstall(activity, rel) }
        }.start()
    }

    private fun fetchLatest(repo: String, token: String): Release? {
        val latestUrl = "$API/repos/$repo/releases/latest"
        var auth = token
        var conn = apiGet(latestUrl, auth)
        // A revoked or expired token gets 401 even on a public repo: ask again without it.
        if (auth.isNotBlank() && runCatching { conn.responseCode }.getOrDefault(-1) == 401) {
            runCatching { conn.errorStream?.close() }
            conn.disconnect()
            Log.w(TAG, "Update token rejected (401); checking without it.")
            auth = ""
            conn = apiGet(latestUrl, auth)
        }
        val body = conn.successStreamOrNull()?.use { it.bufferedReader().readText() } ?: return null
        val json = JSONObject(body)
        val tag = json.optString("tag_name")
        val assets = json.optJSONArray("assets")
        var assetUrl = ""
        var name = ""
        if (assets != null) {
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                if (a.optString("name").endsWith(".apk", ignoreCase = true)) {
                    assetUrl = a.optString("url")
                    name = a.optString("name")
                    break
                }
            }
        }
        return Release(tag, assetUrl, name, auth)
    }

    /** GET on the GitHub API; the Authorization header only when there is a token. */
    private fun apiGet(url: String, token: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            if (token.isNotBlank()) setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            connectTimeout = 15000
            readTimeout = 15000
        }

    private fun promptInstall(activity: Activity, rel: Release) {
        AlertDialog.Builder(activity)
            .setTitle("Update available")
            .setMessage("${rel.tag} is available (installed: ${BuildConfig.VERSION_NAME}). Download and install?")
            .setPositiveButton("Update") { _, _ ->
                Toast.makeText(activity, "Downloading ${rel.tag}…", Toast.LENGTH_SHORT).show()
                Thread {
                    val apk = runCatching { downloadAsset(activity, rel) }.getOrElse {
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

    private fun downloadAsset(activity: Activity, rel: Release): File {
        // The asset API URL with octet-stream returns a 302 to a signed CDN URL; the
        // redirect must be followed WITHOUT the GitHub auth header (the CDN rejects it).
        // Public repo: no token, the same URL works anonymously.
        var conn = (URL(rel.assetUrl).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false
            requestMethod = "GET"
            if (rel.token.isNotBlank()) setRequestProperty("Authorization", "Bearer ${rel.token}")
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
