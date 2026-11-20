package com.magicmaker.android.ui.vfd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** The menu's colour rows and current item, the prompt / confirm queue and dp-to-cell rounding
 *  (ports of the iOS VFDRootView / VFDContext behaviour). */
class VFDMenuAlertTest {
    private val c: Int = 3
    private val y: Int = 40
    private val w: Int = 120
    private val ty: Int = y + VFDW.ctrlText
    private val sx: Int = c + 3
    private val red: VFDRGB = VFDRGB(0xFF, 0x20, 0x10)

    private fun layout(): VFDLayout = VFDLayout(200, 400, 10, 10)

    private fun draw(item: VFDMenuItem, current: Boolean, alarmInverted: Boolean = false): VFDFrameBuffer {
        val fb = VFDFrameBuffer(200, 400, alarmInverted)
        VFDRenderer.drawMenuRow(fb, layout(), item, current, c, y, w, pick = {})
        return fb
    }

    private fun swatchColour(fb: VFDFrameBuffer, col: Int, row: Int): VFDRGB? {
        val v: Int = fb.get(col, row)
        if (v < VFDInk.firstTrueColor) return null
        return fb.trueColors[v - VFDInk.firstTrueColor]
    }

    private fun assertSameRGB(expected: VFDRGB, actual: VFDRGB?) {
        assertNotNull(actual)
        assertEquals(expected.packed, actual!!.packed)
    }

    @Test
    fun colourRowDrawsSwatchGapAndLeftAlignedLabel() {
        var picked = 0
        val fb = VFDFrameBuffer(200, 400)
        val item = VFDMenuItem("Red", rgb = red) { picked += 1 }
        VFDRenderer.drawMenuRow(fb, layout(), item, false, c, y, w, pick = { item.action() })
        // Box in highlight, the 5 x 5 swatch at c + 3 one row below the caps line.
        assertEquals(VFDInk.highlight, fb.get(c, y))
        assertEquals(VFDInk.highlight, fb.get(c + w - 1, y + VFDW.ctrlH - 1))
        for (dy in 0 until 5) {
            for (dx in 0 until 5) {
                assertSameRGB(red, swatchColour(fb, sx + dx, ty + 1 + dy))
            }
        }
        assertEquals(VFDInk.unlit, fb.get(sx, ty))
        assertEquals(VFDInk.unlit, fb.get(sx + 5, ty + 3))
        // One blank glyph slot, then the label from c + 15 in text ink.
        for (col in sx + 5 until c + 15) {
            for (row in ty until ty + 7) {
                assertEquals(VFDInk.unlit, fb.get(col, row))
            }
        }
        val labelInk: List<Int> = (c + 15 until c + 15 + 5).flatMap { col -> (ty until ty + 7).map { fb.get(col, it) } }
        assertTrue(labelInk.contains(VFDInk.text))
        // The tap covers the row and runs pick.
        val hit: VFDHit? = fb.hit(c + w / 2, y + VFDW.ctrlH / 2)
        assertNotNull(hit)
        assertEquals("menu:RED", hit!!.name)
        hit.action?.invoke()
        assertEquals(1, picked)
    }

    @Test
    fun currentColourRowIsASolidBlockWithAnUnlitRingAndCutOutLabel() {
        val plain: VFDFrameBuffer = draw(VFDMenuItem("Red", rgb = red) {}, current = false)
        val fb: VFDFrameBuffer = draw(VFDMenuItem("Red", rgb = red) {}, current = true)
        assertEquals(VFDInk.highlight, fb.get(c, y))
        assertEquals(VFDInk.highlight, fb.get(c + 1, y + 1))
        // 7 x 7 unlit ring round the swatch.
        for (i in 0 until 7) {
            assertEquals(VFDInk.unlit, fb.get(sx - 1 + i, ty))
            assertEquals(VFDInk.unlit, fb.get(sx - 1 + i, ty + 6))
            assertEquals(VFDInk.unlit, fb.get(sx - 1, ty + i))
            assertEquals(VFDInk.unlit, fb.get(sx + 5, ty + i))
        }
        assertEquals(VFDInk.highlight, fb.get(sx - 2, ty))
        assertSameRGB(red, swatchColour(fb, sx + 2, ty + 3))
        // The label's lit cells are cut out of the block.
        var cut = 0
        for (col in c + 15 until c + w - 2) {
            for (row in ty until ty + 7) {
                if (plain.get(col, row) == VFDInk.text) {
                    assertEquals(VFDInk.unlit, fb.get(col, row))
                    cut += 1
                } else {
                    assertEquals(VFDInk.highlight, fb.get(col, row))
                }
            }
        }
        assertTrue(cut > 0)
    }

    @Test
    fun disabledAndDestructiveColourRows() {
        val off: VFDFrameBuffer = draw(VFDMenuItem("Red", enabled = false, rgb = red) {}, current = true)
        assertEquals(VFDInk.dim, off.get(c, y))
        assertNull(off.hit(c + w / 2, y + 5))
        assertSameRGB(red, swatchColour(off, sx, ty + 1))
        val del: VFDFrameBuffer = draw(VFDMenuItem("Red", destructive = true, rgb = red) {}, current = false)
        assertEquals(VFDInk.alarm, del.get(c, y))
        val inv: VFDFrameBuffer = draw(VFDMenuItem("Red", destructive = true, rgb = red) {}, current = false,
                                       alarmInverted = true)
        assertEquals(VFDInk.highlight, inv.get(c, y))
        assertEquals(VFDInk.unlit, inv.get(sx - 1, ty))
    }

    @Test
    fun plainRowsAreButtonsAndTheCurrentOneIsPrimary() {
        for (current in listOf(false, true)) {
            val fb: VFDFrameBuffer = draw(VFDMenuItem("Load in Lab") {}, current = current)
            val ref = VFDFrameBuffer(200, 400)
            VFDW.button(ref, layout(), c, y, w, "Load in Lab", primary = current, name = "menu:LOAD IN LAB", action = {})
            assertTrue(fb.cells.contentEquals(ref.cells))
            assertEquals("menu:LOAD IN LAB", fb.hit(c + 2, y + 2)?.name)
        }
    }

    @Test
    fun aCutLabelKeepsItsTick() {
        assertEquals("RED ✓", VFDRenderer.fitKeepingTick("RED ✓", 100))
        val long = "A VERY LONG COLOUR NAME INDEED ✓"
        val fit: String = VFDRenderer.fitKeepingTick(long, 60)
        assertTrue(fit.endsWith(" ✓"))
        assertTrue(fit.contains("…"))
        assertTrue(VFDText.width(fit) <= 60)
        assertEquals(VFDText.fit("A VERY LONG COLOUR NAME", 40), VFDRenderer.fitKeepingTick("A VERY LONG COLOUR NAME", 40))
        assertEquals("✓", VFDRenderer.fitKeepingTick(long, 10))
    }

    @Test
    fun revealCentresTheSelectedRowAsFarAsTheListAllows() {
        val rowH = 15
        assertEquals(0, VFDRenderer.revealScroll(0, 20, 7, rowH))
        assertEquals(0, VFDRenderer.revealScroll(3, 20, 7, rowH))
        assertEquals(7 * rowH, VFDRenderer.revealScroll(10, 20, 7, rowH))
        assertEquals(13 * rowH, VFDRenderer.revealScroll(19, 20, 7, rowH))
        assertEquals(7 * rowH, VFDRenderer.revealScroll(9, 20, 6, rowH))
        assertEquals(0, VFDRenderer.revealScroll(2, 3, 5, rowH))
        assertEquals(0, VFDRenderer.revealScroll(-1, 20, 7, rowH))
        assertEquals(0, VFDRenderer.revealScroll(20, 20, 7, rowH))
    }

    @Test
    fun alertsWaitTheirTurnAndNeverReplaceTheOneOnScreen() {
        val q = VFDAlertQueue<String>()
        assertEquals("a", q.offer("a", dialogUp = false))
        // Asked for while "a" is up: waits.
        assertNull(q.offer("b", dialogUp = true))
        // "a" closes; its completion asks for "c": behind "b".
        q.closed()
        assertTrue(q.closing)
        assertNull(q.offer("c", dialogUp = false))
        assertEquals("b", q.settle(dialogUp = false))
        assertFalse(q.closing)
        // Nothing is closing and "b" is up: "d" waits too.
        assertNull(q.offer("d", dialogUp = true))
        q.closed()
        // Another dialog (the colour picker) went up meanwhile: nothing shows yet.
        assertNull(q.settle(dialogUp = true))
        assertEquals(2, q.size)
        q.closed()
        assertEquals("c", q.settle(dialogUp = false))
        q.closed()
        assertEquals("d", q.settle(dialogUp = false))
        q.closed()
        assertNull(q.settle(dialogUp = false))
        assertSame("e", q.offer("e", dialogUp = false))
    }

    @Test
    fun cellsRoundHalfToEvenAtTheRenderersPitch() {
        // 3x (pitch 5): 48 dp = 144 px = 28.8 cells.
        assertEquals(29, VFDContext.cellsAt(48.0, 3.0, 5))
        // 2.625x (pitch 4): 10 dp = 26.25 px = 6.5625 cells.
        assertEquals(7, VFDContext.cellsAt(10.0, 2.625, 4))
        // Ties go to even, as Python round() and iOS cells(points:).
        assertEquals(2, VFDContext.cellsAt(2.5, 1.0, 1))
        assertEquals(4, VFDContext.cellsAt(3.5, 1.0, 1))
        assertEquals(6, VFDContext.cellsAt(10.0, 3.0, 5))
        assertEquals(0, VFDContext.cellsAt(Double.NaN, 3.0, 5))
        assertEquals(30, VFDContext.cellsAt(10.0, 3.0, 0))
    }
}
