package com.magicmaker.android.core

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Lightweight crash capture for a toy app. Records uncaught exceptions — and the caught
 * hot-path ones we deliberately swallow — to a small rolling file, so a crash leaves a trail
 * instead of vanishing. Never throws.
 */
object CrashLog {
    private const val FILE = "crash.log"
    private const val MAX_BYTES = 64 * 1024
    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)

    @Volatile private var appContext: Context? = null

    /** Chain a file-logging handler ahead of the platform's default so crashes are recorded. */
    fun install(context: Context) {
        appContext = context.applicationContext
        val prior = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            record(throwable, "UNCAUGHT on ${thread.name}")
            prior?.uncaughtException(thread, throwable)
        }
    }

    /** Append one entry. Safe to call from any thread; a null context (pre-install) is a no-op. */
    fun record(throwable: Throwable, tag: String = "") {
        val ctx = appContext ?: return
        runCatching {
            val sw = StringWriter()
            throwable.printStackTrace(PrintWriter(sw))
            val header = "\n===== ${stamp.format(Date())}${if (tag.isNotEmpty()) " · $tag" else ""} =====\n"
            val f = File(ctx.filesDir, FILE)
            if (f.exists() && f.length() > MAX_BYTES) {
                // Keep the newest half so the file stays bounded without losing recent context.
                f.writeText(f.readText().takeLast(MAX_BYTES / 2))
            }
            f.appendText(header + sw)
        }
    }

    fun recent(context: Context): String =
        runCatching { File(context.filesDir, FILE).takeIf { it.exists() }?.readText() }.getOrNull().orEmpty()

    fun clear(context: Context) {
        runCatching { File(context.filesDir, FILE).delete() }
    }
}
