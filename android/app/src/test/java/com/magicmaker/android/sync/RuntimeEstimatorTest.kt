package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeEstimatorTest {
    private val min = 60_000L

    @Test
    fun oneSamplePerMinute() {
        val r = RuntimeEstimator()
        r.sample(0, 90, false)
        r.sample(30_000, 90, false)
        assertEquals(1, r.sampleCount)
        r.sample(60_000, 89, false)
        assertEquals(2, r.sampleCount)
    }

    @Test
    fun needsThreePointsOverTenMinutes() {
        val r = RuntimeEstimator()
        var last = -1
        for (m in 0..9) last = r.sample(m * min, 80 - m, false)
        assertEquals(-1, last) // 9 points but only 9 minutes
        val v = r.sample(10 * min, 70, false)
        assertEquals(70, v)   // 1 point per minute -> 70 minutes left
        val slow = RuntimeEstimator()
        for (m in 0..20) last = slow.sample(m * min, if (m < 20) 80 else 78, false)
        assertEquals(-1, last) // a 2-point drop is not enough
    }

    @Test
    fun leastSquaresOverNoisySamples() {
        val r = RuntimeEstimator()
        var v = -1
        // 0.5 points per minute with +-1 jitter.
        for (m in 0..30) v = r.sample(m * min, (90 - m / 2.0 + if (m % 2 == 0) 1 else -1).toInt(), false)
        assertTrue("runtime $v", v in 140..170)
    }

    @Test
    fun aChargingChangeResetsAndChargingGivesMinusOne() {
        val r = RuntimeEstimator()
        for (m in 0..15) r.sample(m * min, 80 - m, false)
        assertTrue(r.sample(16 * min, 64, false) > 0)
        assertEquals(-1, r.sample(17 * min, 64, true))
        assertEquals(1, r.sampleCount)
        assertEquals(-1, r.sample(18 * min, 64, false)) // reset again on unplug
        assertEquals(1, r.sampleCount)
        assertEquals(-1, r.sample(19 * min, -1, false))
    }

    @Test
    fun aSixtyMinuteHorizon() {
        val r = RuntimeEstimator()
        for (m in 0..120) r.sample(m * min, 100 - m / 2, false)
        assertEquals(61, r.sampleCount)
    }

    @Test
    fun clampedTo5999() {
        val r = RuntimeEstimator()
        var v = -1
        for (m in 0..60) v = r.sample(m * min, if (m < 60) 100 else 97, false)
        assertEquals(RuntimeEstimator.MAX_RUNTIME_MIN, v)
    }

    @Test
    fun aRisingLevelWhileDischargingGivesMinusOne() {
        val r = RuntimeEstimator()
        var v = 0
        for (m in 0..12) v = r.sample(m * min, if (m == 0) 90 else 60 + 2 * m, false)
        assertEquals(-1, v)
    }
}
