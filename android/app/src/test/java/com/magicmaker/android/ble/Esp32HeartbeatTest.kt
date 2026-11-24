package com.magicmaker.android.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class Esp32HeartbeatTest {
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test fun parsesBatteryAndRuntime() {
        // 68 %, battery present, 580 minutes (0x0244)
        val hb = Esp32Heartbeat.parse(bytes('M'.code, 'B'.code, 1, 68, 0x04, 0x44, 0x02))!!
        assertEquals(68, hb.percent)
        assertEquals(580, hb.runtimeMinutes)
        assertEquals("ESP32:68% ~9H 40M", hb.telemetryToken())
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
