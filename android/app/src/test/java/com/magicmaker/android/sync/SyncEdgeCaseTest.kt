package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

// Edge cases no vector covers (review of the P1 Kotlin codec): the session core must not crash on
// an AUTH after the node left its group, key strings and hex parse strictly, and encoders refuse
// values a receiver would reject instead of emitting them (or wrapping them silently).

class SyncEdgeCaseTest {
    private val idH = Bytes.fromHex("0100246F28AE52C6")
    private val idI = Bytes.fromHex("A1B2C3D4E5F60718")
    private val group = SyncGroup.fromKey(Bytes.fromHex("000102030405060708090A0B0C0D0E0F"))

    private fun peripheralInHelloX(): SessionCore {
        var n = 0L
        val ctx = SessionCtx(group, Bytes.fromHex("1269208CA2190C2D"), 0, { 0L }, { Bytes.u64BigEndian(0x77L + n++) })
        val core = SessionCore(SessionConfig(SessionRole.PERIPHERAL, idH, SyncConst.KIND_HUB, 0x3003, 512), ctx)
        core.handle(0, SessionInput.LinkUp(185))
        val hello = Hello(
            proto = 1, deviceId = idI, kind = SyncConst.KIND_IOS, dbId = Bytes.fromHex("2222222222222222"), clockMs = 0,
            feedHigh = 0, subs = 7, caps = SyncConst.CAPS_IOS, maxMsg = 1024, bootId = 1, groupId = group.groupId,
            nonce = Bytes.fromHex("0001020304050607"),
        )
        core.handle(10, SessionInput.Rx(hello.encode()))
        assertEquals(SessionState.HELLO_X, core.state)
        return core
    }

    private fun auth() = SessionInput.Rx(Auth(Bytes.zero(16)).encode())

    @Test
    fun authAfterGroupChangedToUngroupedIsDropped() {
        val core = peripheralInHelloX()
        core.ctx.group = null
        val left = core.handle(20, SessionInput.GroupChanged)
        assertEquals(listOf(SessionAction.Disconnect(DisconnectReason.LEFT_GROUP, null)), left)
        assertEquals(emptyList<SessionAction>(), core.handle(30, auth())) // used to throw NullPointerException
        assertEquals(SessionState.HELLO_X, core.state)
    }

    @Test
    fun authAfterSilentGroupLossIsDroppedAndTheAuthTimerStillEndsTheLink() {
        val core = peripheralInHelloX()
        val due = core.timerDue(SessionTimer.AUTH)!!
        core.ctx.group = null // the node has not delivered group_changed yet
        assertEquals(emptyList<SessionAction>(), core.handle(20, auth()))
        assertEquals(
            listOf(SessionAction.Disconnect(DisconnectReason.AUTH_TIMEOUT, null)),
            core.handle(due, SessionInput.Timer(SessionTimer.AUTH)),
        )
    }

    @Test
    fun keyStringsParseOnlyInCanonicalForm() {
        val k = RecordKey(0, Bytes.fromHex("8301E100E90600220F5C57B0"))
        assertEquals(k, RecordKey.parseKeyString(k.keyString))
        assertEquals(RecordKey(1, k.packet), RecordKey.parseKeyString("1:8301E100E90600220F5C57B0"))
        for (bad in listOf(
            "256:8301E100E90600220F5C57B0", // would wrap to ns 0
            "-256:8301E100E90600220F5C57B0",
            "00:8301E100E90600220F5C57B0",
            "+0:8301E100E90600220F5C57B0",
            "0:8301e100e90600220f5c57b0",
            "2:8301E100E90600220F5C57B0",
            "0:8301",
            "0:",
            ":8301E100",
            "0:8301E100E90600220F5C57B０", // fullwidth zero
        )) {
            assertNull(bad, RecordKey.parseKeyString(bad))
        }
    }

    @Test
    fun hexIsAsciiOnly() {
        assertEquals(Bytes.of(0xAB, 0x01), Bytes.fromHex("ab01"))
        for (bad in listOf("١٢", "ＡＢ", "0g", "1")) {
            try {
                Bytes.fromHex(bad)
                fail("fromHex(\"$bad\") accepted")
            } catch (e: IllegalArgumentException) {
                // expected
            }
        }
    }

    private fun rejected(what: String, block: () -> Unit) {
        try {
            block()
            fail("$what encoded")
        } catch (e: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun encodersRefuseWhatReceiversReject() {
        val origin = Bytes.fromHex("4A1D0B5E77C2903F")
        val db = Bytes.fromHex("1269208CA2190C2D")
        val packet = Bytes.fromHex("8301E100E90600220F5C57B0")
        fun hb(links: List<HbLink> = emptyList(), battPct: Int? = null) = Hb(
            deviceId = origin, kind = 2, bootId = 1, hbSeq = 1, ts = 0, uptimeS = 1, battPct = battPct, link = links,
            hops = 0, feedHigh = 0, dbId = db, records = 0,
        )
        hb(listOf(HbLink(idH, 1, 3))).encode()
        rejected("HB link flags 256 (wrapped to 0 before)") { hb(listOf(HbLink(idH, 1, 256))).encode() }
        rejected("HB link peerKind 0") { hb(listOf(HbLink(idH, 0, 1))).encode() }
        rejected("HB link 6-byte peerId") { hb(listOf(HbLink(idH.slice(0, 6), 1, 1))).encode() }
        rejected("HB battPct 101") { hb(battPct = 101).encode() }
        rejected("ERR key ns 256 (wrapped to 0 before)") { Err(ErrCode.CLOCK, 3, RecordKey(256, packet)).encode() }
        rejected("ERR key ns 2") { Err(ErrCode.CLOCK, 3, RecordKey(2, packet)).encode() }
        rejected("PULL reqId 0") { Pull(0, 0, dbId = db).encode() }
        rejected("PULL maxBytes 100") { Pull(1, 0, maxBytes = 100, dbId = db).encode() }
        rejected("EVT lat without lon/acc") { Evt(origin, 1, 1, 0, packet, lat = 5).encode() }
        rejected("EVT packet without 83 01") { Evt(origin, 1, 1, 0, Bytes.fromHex("830201")).encode() }
        rejected("JOIN zero groupId") { Join(Bytes.ZERO8, group.groupKey).encode() }
        val body = RecordBody(RecordKey(0, packet), 1).encode()
        rejected("page REC with seenBy") { Rec(1, 5, listOf(origin), body).encode() }
        rejected("REC body with an envelope tag") { Rec(1, 0, emptyList(), body + Bytes.of(0x20, 0)).encode() }
        rejected("REC body truncated") { Rec(1, 0, emptyList(), body.slice(0, body.size - 1)).encode() }
        // a REC whose body is well-framed but invalid still encodes (the envelope is what counts, §11.4)
        val bad = Rec(1, 0, emptyList(), Bytes.of(0x11, 0x00)).encode()
        assertTrue((SyncMsgs.decode(bad) as Rec).bodyError != null)
    }

    @Test
    fun aNodeValueOutOfRangeIsCountedNotThrown() {
        val ctx = SessionCtx(group, Bytes.fromHex("1269208CA2190C2D"), 1L shl 32, { 0L }, { Bytes.fromHex("0001020304050607") })
        val core = SessionCore(SessionConfig(SessionRole.CENTRAL, idI, SyncConst.KIND_IOS, 1, 1024, peerKind = 1), ctx)
        val acts = core.handle(0, SessionInput.LinkUp(185)) // feedHigh above u32: the HELLO cannot be encoded
        assertEquals(listOf(SessionAction.State(SessionState.LINKED)), acts)
        assertEquals(1, core.encodeFailures)
        ctx.feedHigh = 3
        val retry = core.handle(SyncConst.T_HELLO_MS, SessionInput.Timer(SessionTimer.HELLO))
        assertTrue(retry.single() is SessionAction.Send)
        assertEquals(1, core.encodeFailures)
    }

    @Test
    fun sessionConfigIsValidatedWhenBuilt() {
        val ok = SessionConfig(SessionRole.CENTRAL, idI, SyncConst.KIND_IOS, 1, 1024, name = "iPhone 15 Pro Max!!", peerKind = 1)
        assertEquals("iPhone 15 Pro Max!!", ok.name)
        for ((what, block) in listOf<Pair<String, () -> Unit>>(
            "21-byte name" to { SessionConfig(SessionRole.CENTRAL, idI, 3, 1, 1024, name = "Samsung Galaxy S23 Ux") },
            "17-byte version" to { SessionConfig(SessionRole.CENTRAL, idI, 3, 1, 1024, version = "1.4.0-beta.12345x") },
            "zero deviceId" to { SessionConfig(SessionRole.CENTRAL, Bytes.ZERO8, 3, 1, 1024) },
            "maxMsg 511" to { SessionConfig(SessionRole.CENTRAL, idI, 3, 1, 511) },
            "bootId 65536" to { SessionConfig(SessionRole.CENTRAL, idI, 3, 65536, 1024) },
            "peerKind 4" to { SessionConfig(SessionRole.CENTRAL, idI, 3, 1, 1024, peerKind = 4) },
        )) {
            rejected(what, block)
        }
    }
}
