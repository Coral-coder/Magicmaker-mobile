package com.magicmaker.android.sync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

class AtomicFilesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun bytes(s: String) = s.toByteArray(Charsets.UTF_8)

    @Test
    fun writeThenRead() {
        val f = File(tmp.root, "sub/dir/store.json")
        assertTrue(AtomicFiles.write(f, bytes("hello")))
        assertArrayEquals(bytes("hello"), AtomicFiles.read(f))
        assertTrue(AtomicFiles.write(f, bytes("second")))
        assertArrayEquals(bytes("second"), AtomicFiles.read(f))
        assertFalse(AtomicFiles.tmpOf(f).exists())
    }

    @Test
    fun failureBetweenTmpAndRenameLeavesTheOldTarget() {
        val f = File(tmp.root, "store.json")
        assertTrue(AtomicFiles.write(f, bytes("old")))
        // A crash right before the rename: the tmp is written, the target is untouched.
        val ok = AtomicFiles.write(f, bytes("new")) { _, _ -> throw IOException("crash before rename") }
        assertFalse(ok)
        assertArrayEquals(bytes("old"), f.readBytes())
        assertTrue(AtomicFiles.tmpOf(f).exists())
        // Next load: the leftover tmp is deleted, the old target is used.
        assertArrayEquals(bytes("old"), AtomicFiles.read(f))
        assertFalse(AtomicFiles.tmpOf(f).exists())
    }

    @Test
    fun aLeftoverTmpIsIgnoredAndCleaned() {
        val f = File(tmp.root, "store.json")
        f.writeText("good")
        AtomicFiles.tmpOf(f).writeText("{partial")
        assertArrayEquals(bytes("good"), AtomicFiles.read(f))
        assertFalse(AtomicFiles.tmpOf(f).exists())
    }

    @Test
    fun renameFallbackDropsTheTargetThenRenames() {
        val f = File(tmp.root, "store.json")
        assertTrue(AtomicFiles.write(f, bytes("old")))
        var calls = 0
        val ok = AtomicFiles.write(f, bytes("new")) { a, b ->
            calls++
            if (calls == 1) false else a.renameTo(b)
        }
        assertTrue(ok)
        assertEquals(2, calls)
        assertArrayEquals(bytes("new"), f.readBytes())
    }

    @Test
    fun aCompleteTmpWithoutItsTargetIsPromoted() {
        // The fallback dropped the target and then the process died before the second rename.
        val f = File(tmp.root, "store.json")
        var calls = 0
        AtomicFiles.write(f, bytes("old"))
        val ok = AtomicFiles.write(f, bytes("new")) { _, _ ->
            calls++
            false
        }
        assertFalse(ok)
        assertFalse(f.exists())
        assertArrayEquals(bytes("new"), AtomicFiles.read(f))
        assertFalse(AtomicFiles.tmpOf(f).exists())
    }

    @Test
    fun aWriteThatCannotStartReturnsFalseAndKeepsNothingBehind() {
        val parentIsAFile = File(tmp.root, "plain")
        parentIsAFile.writeText("x")
        val f = File(parentIsAFile, "store.json")
        assertFalse(AtomicFiles.write(f, bytes("data")))
        assertNull(AtomicFiles.read(f))
    }

    @Test
    fun readOfAMissingFileIsNull() {
        assertNull(AtomicFiles.read(File(tmp.root, "none.json")))
    }
}
