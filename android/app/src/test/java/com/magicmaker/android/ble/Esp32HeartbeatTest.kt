package com.magicmaker.android.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Esp32HeartbeatTest {
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test fun parsesBatteryAndRuntime() {
        // 68 %, battery present, 580 minutes (0x0244)
        val hb = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 68, 0x04, 0x44, 0x02))!!
        assertEquals(68, hb.percent)
        assertEquals(580, hb.runtimeMinutes)
        assertFalse(hb.low)
        assertEquals("ESP32:68% ~9H 40M", hb.telemetryToken())
    }

    @Test fun lowBattery() {
        // Firmware 1.5: flags 0x0C = battery present + low, 8 %, 25 minutes to the cutoff.
        val low = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 8, 0x0C, 25, 0x00))!!
        assertTrue(low.low)
        assertEquals(8, low.percent)
        assertEquals(25, low.runtimeMinutes)
        assertEquals("ESP32:8% LOW ~25M", low.telemetryToken())
        // Without a runtime estimate.
        val noRun = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 12, 0x0C, 0xFF, 0xFF))!!
        assertEquals("ESP32:12% LOW", noRun.telemetryToken())
        // Charging still wins.
        val chg = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 8, 0x0D, 0xFF, 0xFF))!!
        assertTrue(chg.low)
        assertEquals("ESP32:CHG", chg.telemetryToken())
        // A low flag without a percentage still shows.
        val noPct = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 0xFF, 0x0C, 0xFF, 0xFF))!!
        assertEquals("ESP32:LOW", noPct.telemetryToken())
        // Without the battery-present bit there is nothing to show, low or not.
        val noBattery = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 8, 0x08, 0xFF, 0xFF))!!
        assertNull(noBattery.telemetryToken())
    }

    @Test fun olderFirmwareNeverLow() {
        // Firmware 1.4 sets bits 0..2 only.
        for (flags in 0..7) {
            val hb = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 50, flags, 0x10, 0x00))!!
            assertFalse("flags $flags", hb.low)
        }
    }

    @Test fun chargingAndUsb() {
        val chg = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 90, 0x07, 0xFF, 0xFF))!!
        assertEquals("ESP32:CHG", chg.telemetryToken())
        val usb = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 95, 0x06, 0xFF, 0xFF))!!
        assertEquals("ESP32:95%", usb.telemetryToken())
    }

    @Test fun noBatteryOrJunk() {
        val none = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 0xFF, 0x00, 0xFF, 0xFF))!!
        assertNull(none.telemetryToken())
        assertNull(Esp32Heartbeat.parse(bytes('M'.code, 'X'.code, 1, 50, 4, 0, 0)))
        assertNull(Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1)))
        assertNull(Esp32Heartbeat.parse(null))
    }

    @Test fun runtimeText() {
        assertEquals("~45M", Esp32Heartbeat.runtimeText(45))
        assertEquals("~1H 0M", Esp32Heartbeat.runtimeText(60))
        assertEquals("~99H+", Esp32Heartbeat.runtimeText(99 * 60))
    }
}
