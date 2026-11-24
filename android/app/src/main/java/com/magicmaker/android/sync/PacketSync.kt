package com.magicmaker.android.sync

import android.content.Context
import android.util.Base64
import android.util.Log
import com.magicmaker.android.BuildConfig
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Keeps a shared, de-duplicated packet dictionary (hex + function) in sync with a
 * dedicated GitHub repo, so any MagicMaker device — or other apps — can read the
 * canonical CSV. Bidirectional: pulls remote-only packets in, pushes locally-known
 * packets the remote lacks.
 *
 * Offline-safe: the on-device library is the durable queue. Every sync reconciles
 * the full set, so failed (offline) syncs simply retry later with nothing lost.
 *
 * Dormant until a write-scoped token is available: the one entered on this device in
 * Settings -> CLOUD DICTIONARY (kept in its own app-private prefs file, never exported), or,
 * for a local private build only, one baked in with -PmmBackupToken (BuildConfig.BACKUP_TOKEN).
 * Public release builds bake in no token.
 */
object PacketSync {
    private const val TAG = "PacketSync"
    private const val API = "https://api.github.com"
    private const val PATH = "packets.csv"
    private const val HEADER = "hex,function,category,colors"
    private const val MIN_SYNC_INTERVAL_MS = 60_000L

    data class Entry(val hex: String, val function: String, val category: String, val colors: String)

    private val running = AtomicBoolean(false)
    @Volatile private var lastSyncMs = 0L

    /** App-private prefs file for the cloud token. Deliberately NOT "magicmaker" / "magicmaker_ui",
     *  the two files MagicStore snapshots into the library file and EXPORT. */
    const val TOKEN_PREFS: String = "magicmaker_secrets"
    const val TOKEN_KEY: String = "cloud_dictionary_token"

    /** Bumped whenever the entered token changes, so cached "is sync set up" checks refresh. */
    @Volatile var tokenRevision: Int = 0
        private set

    private fun tokenPrefs(context: Context) =
        context.applicationContext.getSharedPreferences(TOKEN_PREFS, Context.MODE_PRIVATE)

    /** GitHub tokens are printable ASCII. Drop anything else a paste can bring (spaces, line
     *  breaks, zero-width marks): such a character in the Authorization header makes the HTTP
     *  stack throw an error that quotes the header, token included. */
    private fun clean(token: String): String = token.filter { it in '!'..'~' }

    /** The token entered on this device ("" when none). */
    fun enteredToken(context: Context): String =
        runCatching { clean(tokenPrefs(context).getString(TOKEN_KEY, "").orEmpty()) }.getOrDefault("")

    /** Store (or, with a blank [token], remove) the token entered in Settings. */
    fun saveToken(context: Context, token: String) {
        val t = clean(token)
        val e = tokenPrefs(context).edit()
        if (t.isEmpty()) e.remove(TOKEN_KEY) else e.putString(TOKEN_KEY, t)
        e.apply()
        tokenRevision++
        lastSyncMs = 0L
    }

    /** The entered token, else a build-time one (only non-blank in local private builds). */
    private fun token(context: Context): String =
        enteredToken(context).ifBlank { BuildConfig.BACKUP_TOKEN.trim() }

    fun configured(context: Context): Boolean =
        token(context).isNotBlank() && BuildConfig.BACKUP_REPO.isNotBlank()

    /**
     * Reconcile [local] with the remote CSV on a background thread.
     * [onRemoteAdded] receives packets present remotely but not locally; [onStatus]
     * reports progress. Throttled unless [force]; concurrent calls are ignored.
     */
    fun sync(
        context: Context,
        local: List<Entry>,
        force: Boolean,
        onRemoteAdded: (List<Entry>) -> Unit,
        onStatus: (String) -> Unit,
    ) {
        val token = token(context)
        if (token.isBlank() || BuildConfig.BACKUP_REPO.isBlank()) return
        if (!force && System.currentTimeMillis() - lastSyncMs < MIN_SYNC_INTERVAL_MS) return
        if (!running.compareAndSet(false, true)) return
        Thread {
            try {
                lastSyncMs = System.currentTimeMillis()
                runSync(token, local, onRemoteAdded, onStatus)
            } catch (t: Throwable) {
                // The status line and logcat never show the token, even if an error quotes it.
                val msg = (t.message ?: "error").replace(token, "***")
                Log.w(TAG, "sync failed: ${t.javaClass.simpleName}: $msg")
                onStatus("Sync failed: $msg")
            } finally {
                running.set(false)
            }
        }.start()
    }

    private fun runSync(token: String, local: List<Entry>, onRemoteAdded: (List<Entry>) -> Unit,
                        onStatus: (String) -> Unit) {
        val repo = BuildConfig.BACKUP_REPO

        var (remote, sha) = pull(repo, token)
        val newlyRemote = remote.filter { r -> local.none { it.hex == r.hex } }
        if (newlyRemote.isNotEmpty()) onRemoteAdded(newlyRemote)

        // Up to a few attempts in case another device updates the file concurrently
        // (sha conflict -> re-pull and merge again).
        repeat(3) {
            val merged = LinkedHashMap<String, Entry>()
            remote.forEach { merged[it.hex] = it }
            var added = 0
            for (e in local) if (!merged.containsKey(e.hex)) { merged[e.hex] = e; added++ }

            if (added == 0) {
                onStatus("Synced · ${newlyRemote.size} new in, ${merged.size} total")
                return
            }
            val code = push(repo, token, buildCsv(merged.values), sha)
            if (code in 200..299) {
                onStatus("Synced · +$added out, ${newlyRemote.size} in, ${merged.size} total")
                return
            }
            if (code != 409 && code != 422) {
                onStatus("Sync push failed ($code)")
                return
            }
            val refreshed = pull(repo, token)
            remote = refreshed.first
            sha = refreshed.second
        }
        onStatus("Sync conflict — will retry later")
    }

    private fun pull(repo: String, token: String): Pair<List<Entry>, String?> {
        val conn = open("$API/repos/$repo/contents/$PATH", token)
        return when (conn.responseCode) {
            in 200..299 -> {
                val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
                val sha = json.optString("sha").ifBlank { null }
                val text = String(Base64.decode(json.optString("content").replace("\n", ""), Base64.DEFAULT))
                parseCsv(text) to sha
            }
            404 -> { conn.errorStream?.close(); emptyList<Entry>() to null }
            401 -> { conn.errorStream?.close(); throw RuntimeException("token rejected (401) - re-enter it in Settings") }
            else -> { conn.errorStream?.close(); throw RuntimeException("GET ${conn.responseCode}") }
        }
    }

    private fun push(repo: String, token: String, csv: String, sha: String?): Int {
        val body = JSONObject().apply {
            put("message", "Update packet dictionary")
            put("content", Base64.encodeToString(csv.toByteArray(), Base64.NO_WRAP))
            if (sha != null) put("sha", sha)
        }
        val conn = open("$API/repos/$repo/contents/$PATH", token, "PUT")
        conn.doOutput = true
        conn.outputStream.use { it.write(body.toString().toByteArray()) }
        val code = conn.responseCode
        if (code !in 200..299) conn.errorStream?.close()
        return code
    }

    private fun open(url: String, token: String, method: String = "GET"): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            if (method == "PUT") setRequestProperty("Content-Type", "application/json")
            connectTimeout = 15000
            readTimeout = 20000
        }

    private fun buildCsv(entries: Collection<Entry>): String {
        val sb = StringBuilder(HEADER).append('\n')
        entries.sortedBy { it.hex }.forEach {
            sb.append(field(it.hex)).append(',')
                .append(field(it.function)).append(',')
                .append(field(it.category)).append(',')
                .append(field(it.colors)).append('\n')
        }
        return sb.toString()
    }

    private fun parseCsv(text: String): List<Entry> {
        val lines = text.split('\n').map { it.trimEnd('\r') }.filter { it.isNotBlank() }
        if (lines.isEmpty()) return emptyList()
        val start = if (lines[0].startsWith("hex,")) 1 else 0
        val out = ArrayList<Entry>()
        for (i in start until lines.size) {
            val c = splitCsv(lines[i])
            val hex = c.getOrNull(0)?.trim()?.uppercase().orEmpty()
            if (hex.isEmpty()) continue
            out.add(Entry(hex, c.getOrNull(1).orEmpty(), c.getOrNull(2).orEmpty(), c.getOrNull(3).orEmpty()))
        }
        return out
    }

    private fun field(s: String): String =
        if (s.contains(',') || s.contains('"') || s.contains('\n')) "\"" + s.replace("\"", "\"\"") + "\"" else s

    private fun splitCsv(line: String): List<String> {
        val out = ArrayList<String>()
        val sb = StringBuilder()
        var quoted = false
        var i = 0
        while (i < line.length) {
            val ch = line[i]
            when {
                quoted && ch == '"' && i + 1 < line.length && line[i + 1] == '"' -> { sb.append('"'); i++ }
                ch == '"' -> quoted = !quoted
                ch == ',' && !quoted -> { out.add(sb.toString()); sb.setLength(0) }
                else -> sb.append(ch)
            }
            i++
        }
        out.add(sb.toString())
        return out
    }
}
