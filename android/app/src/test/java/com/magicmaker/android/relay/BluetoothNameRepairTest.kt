package com.magicmaker.android.relay

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BluetoothNameRepairTest {
    private val legacy = RelayProtocol.LEGACY_DEVICE_NAME

    @Test
    fun restoresSettingsNameWhenAdapterHasLegacyName() {
        assertEquals("Pixel of Sam", BluetoothNameRepair.restoreTarget(legacy, "Pixel of Sam", "Pixel 8"))
    }

    @Test
    fun fallsBackToModelWhenSettingsNameBlank() {
        assertEquals("Pixel 8", BluetoothNameRepair.restoreTarget(legacy, null, "Pixel 8"))
        assertEquals("Pixel 8", BluetoothNameRepair.restoreTarget(legacy, "  ", "Pixel 8"))
    }

    @Test
    fun leavesOtherNamesAlone() {
        assertNull(BluetoothNameRepair.restoreTarget("Sam's phone", "Pixel of Sam", "Pixel 8"))
        assertNull(BluetoothNameRepair.restoreTarget(null, "Pixel of Sam", "Pixel 8"))
        assertNull(BluetoothNameRepair.restoreTarget("MagicMaker-Android-2", "Pixel of Sam", "Pixel 8"))
        assertNull(BluetoothNameRepair.restoreTarget(" MagicMaker-Android", "Pixel of Sam", "Pixel 8"))
        assertNull(BluetoothNameRepair.restoreTarget("magicmaker-android", "Pixel of Sam", "Pixel 8"))
        assertNull(BluetoothNameRepair.restoreTarget("MM_AND", "Pixel of Sam", "Pixel 8"))
    }

    @Test
    fun keepsADeliberateLegacyNameOrNothingToRestore() {
        // The user named the phone this in Settings: not ours to change.
        assertNull(BluetoothNameRepair.restoreTarget(legacy, legacy, "Pixel 8"))
        assertNull(BluetoothNameRepair.restoreTarget(legacy, null, null))
        assertNull(BluetoothNameRepair.restoreTarget(legacy, "", " "))
    }

    @Test
    fun relayIdentityMatchesTheIphone() {
        // Must stay identical to ios/MagicMaker/BLE/AndroidRelayGattClient.swift
        // (serviceUUID, androidRelayTag) or the iPhone stops recognising the relay.
        assertEquals("A7830001-0000-1000-8000-00805F9B34FB", RelayProtocol.SERVICE_UUID)
        assertEquals("MM_AND", RelayProtocol.RELAY_TAG)
    }

    @Test
    fun relayTagFitsTheScanResponse() {
        val tag = RelayProtocol.relayTagBytes()
        assertArrayEquals("MM_AND".toByteArray(Charsets.US_ASCII), tag)
        // Service data AD structure: length + type (2) + 128-bit UUID (16) + tag.
        assertTrue(2 + 16 + tag.size <= 31)
    }
}
