package com.magicmaker.android.sync

import java.io.File
import java.io.FileOutputStream

/**
 * Atomic file replacement (docs/SYNC_P3_ANDROID_PLAN.md §3.5): write `target.tmp`, flush and
 * fsync it, then rename it over the target. A crash at any point leaves either the old target or
 * the complete new one. Pure JVM (no Android APIs) so it is unit tested directly.
 */
object AtomicFiles {
    fun tmpOf(target: File): File = File(target.parentFile, target.name + ".tmp")

    /** Write [bytes] to [target] atomically. Returns false (old target intact) on any failure. */
    fun write(target: File, bytes: ByteArray): Boolean = write(target, bytes) { from, to -> from.renameTo(to) }

    /** [write] with an injectable rename (tests simulate a failing rename / a crash before it). */
    internal fun write(target: File, bytes: ByteArray, rename: (File, File) -> Boolean): Boolean {
        val tmp = tmpOf(target)
        try {
            target.parentFile?.let { if (!it.isDirectory) it.mkdirs() }
            FileOutputStream(tmp).use { out ->
                out.write(bytes)
                out.flush()
                out.fd.sync()
            }
        } catch (e: Exception) {
            runCatching { tmp.delete() }
            return false
        }
        return try {
            if (rename(tmp, target)) {
                true
            } else {
                // Some filesystems refuse to rename over an existing file. The tmp is complete and
                // synced, so dropping the target first is safe: recover() promotes a tmp whose
                // target is missing.
                target.delete()
                rename(tmp, target)
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Load-time cleanup of a leftover `.tmp`. The target, when present, is the truth and the tmp is
     * deleted (a crash before the rename). A tmp without its target can only exist after the target
     * was dropped in the rename fallback, when the tmp was already complete: it is promoted.
     */
    fun recover(target: File) {
        val tmp = tmpOf(target)
        try {
            if (!tmp.exists()) return
            if (target.exists()) {
                tmp.delete()
            } else if (!tmp.renameTo(target)) {
                tmp.delete()
            }
        } catch (e: Exception) {
            // Best effort: the target (if any) is still used.
        }
    }

    /** The target's bytes after [recover], or null when it is missing or unreadable. */
    fun read(target: File): ByteArray? {
        recover(target)
        return runCatching { if (target.isFile) target.readBytes() else null }.getOrNull()
    }
}
