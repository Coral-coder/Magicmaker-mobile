package com.magicmaker.android.sync

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

// SYNC v1 conformance (docs/SYNC_PROTOCOL.md §20): every group of tools/sync/vectors.json, consumed
// exactly as tools/sync/check_vectors.py does (the model harness), plus typed-message round trips.
//
//   cd android && ./gradlew :app:testDebugUnitTest --tests 'com.magicmaker.android.sync.*'

class SyncVectorsTest {
    private val v: JsonObject get() = SyncTestData.vectors
    private val checked = Checked()

    private fun errName(block: () -> Unit): String? = try {
        block()
        null
    } catch (e: SyncException) {
        ErrCode.name(e.code)
    }

    private fun done(vararg groups: String) {
        for (g in groups) assertTrue("vector group $g is empty", checked.count(g) > 0)
        println("sync vectors: $checked")
    }

    @Test
    fun header() {
        assertEquals(1, v.int("schema"))
        assertEquals(SyncConst.PROTO, v.int("proto"))
        val c = v.obj("constants")
        val expect = mapOf(
            "proto" to SyncConst.PROTO.toLong(), "frameVersion" to SyncConst.FRAME_VERSION.toLong(),
            "frameHeaderLen" to SyncConst.FRAME_HEADER_LEN.toLong(), "attOverhead" to SyncConst.ATT_OVERHEAD.toLong(),
            "mtuMin" to SyncConst.MTU_MIN.toLong(), "smallMtuBelow" to SyncConst.SMALL_MTU_BELOW.toLong(),
            "maxMsgMin" to SyncConst.MAXMSG_MIN.toLong(), "hubMaxMsg" to SyncConst.HUB_MAXMSG.toLong(),
            "phoneMaxMsg" to SyncConst.PHONE_MAXMSG.toLong(), "packetMin" to SyncConst.PACKET_MIN.toLong(),
            "packetMax" to SyncConst.PACKET_MAX.toLong(), "labelMax" to SyncConst.LABEL_MAX.toLong(),
            "noteMax" to SyncConst.NOTE_MAX.toLong(), "kindMax" to SyncConst.KIND_MAX.toLong(),
            "bodyMax" to SyncConst.BODY_MAX.toLong(), "seenByMax" to SyncConst.SEENBY_MAX.toLong(),
            "hbLinksMax" to SyncConst.HB_LINKS_MAX.toLong(), "hbEvtWmMax" to SyncConst.HB_EVTWM_MAX.toLong(),
            "uPresence" to SyncConst.U_PRESENCE, "uLegacyAndroid" to SyncConst.U_LEGACY_ANDROID,
            "uLegacyIos" to SyncConst.U_LEGACY_IOS, "uMinMs" to SyncConst.U_MIN_MS,
            "futureBoundMs" to SyncConst.FUTURE_BOUND_MS, "pullLimitDefault" to SyncConst.PULL_LIMIT_DEFAULT.toLong(),
            "pullMaxBytesDefault" to SyncConst.PULL_MAXBYTES_DEFAULT.toLong(),
            "pullLimitSmall" to SyncConst.PULL_LIMIT_SMALL.toLong(),
            "pullMaxBytesSmall" to SyncConst.PULL_MAXBYTES_SMALL.toLong(),
            "pullMaxBytesMin" to SyncConst.PULL_MAXBYTES_MIN.toLong(), "helloTimeoutMs" to SyncConst.T_HELLO_MS,
            "helloTries" to SyncConst.HELLO_TRIES.toLong(), "incompatibleRetryMs" to SyncConst.T_RETRY_INCOMPATIBLE_MS,
            "authTimeoutMs" to SyncConst.T_AUTH_MS, "memberDeadlineMs" to SyncConst.T_DEADLINE_MS,
            "pageTimeoutMs" to SyncConst.T_PAGE_MS, "pageTries" to SyncConst.PAGE_TRIES.toLong(),
            "pageFailRetryMs" to SyncConst.T_PAGE_FAIL_RETRY_MS, "livePullMs" to SyncConst.T_LIVE_PULL_MS,
            "hbIntervalMs" to SyncConst.T_HB_MS, "hbSpacingMs" to SyncConst.T_HB_SPACING_MS,
            "pathFreshMs" to SyncConst.T_PATH_FRESH_MS, "notReadyRetryMs" to SyncConst.NOT_READY_RETRY_MS.toLong(),
            "busyRetryMs" to SyncConst.BUSY_RETRY_MS.toLong(), "defaultRetryMs" to SyncConst.DEFAULT_RETRY_MS.toLong(),
            "evtWindowBits" to SyncConst.EVT_WINDOW_BITS.toLong(), "evtEpochsKept" to SyncConst.EVT_EPOCHS_KEPT.toLong(),
            "evtReplayDedupeMs" to SyncConst.EVT_REPLAY_DEDUPE_MS,
            "tombstoneCapPhone" to SyncConst.TOMBSTONE_CAP_PHONE.toLong(),
        )
        for ((k, want) in expect) assertEq("constants.$k", c.long(k), want)
        assertEq("fnv64Offset", "%016X".format(SyncConst.FNV64_OFFSET), c.str("fnv64Offset"))
        assertEq("fnv64Prime", "%016X".format(SyncConst.FNV64_PRIME), c.str("fnv64Prime"))
        assertEq("groupIdPrefix", SyncCrypto.GROUP_ID_PREFIX.hex(), c.str("groupIdPrefix"))
        assertEq("proofPPrefix", SyncCrypto.PROOF_P_PREFIX.hex(), c.str("proofPPrefix"))
        assertEq("proofCPrefix", SyncCrypto.PROOF_C_PREFIX.hex(), c.str("proofCPrefix"))
        for ((name, code) in c.obj("messageTypes").entrySet()) {
            assertEq("messageTypes.$name", MsgType.code(name), code.asInt)
            assertEq("messageTypes name", MsgType.name(code.asInt), name)
        }
        for ((name, code) in c.obj("errorCodes").entrySet()) {
            assertEq("errorCodes.$name", ErrCode.code(name), code.asInt)
        }
        val fx = c.obj("fixtures")
        assertEq("fixture groupId1", SyncCrypto.groupId(fx.hex("groupKey1")), fx.hex("groupId1"))
        assertEq("fixture groupId2", SyncCrypto.groupId(fx.hex("groupKey2")), fx.hex("groupId2"))
    }

    @Test
    fun primitives() {
        for (c in v.arr("crc32").objects()) {
            assertEq("crc32 ${c.str("name")}", SyncCrypto.crc32(c.hex("hex")), c.long("crc")); checked.ok("crc32")
        }
        for (c in v.arr("fnv1a64").objects()) {
            assertEq("fnv ${c.str("name")}", "%016X".format(SyncCrypto.fnv1a64(c.hex("hex"))), c.str("hash"))
            checked.ok("fnv1a64")
        }
        for (c in v.arr("sha256").objects()) {
            assertEq("sha ${c.str("name")}", SyncCrypto.sha256(c.hex("hex")).hex(), c.str("digest")); checked.ok("sha256")
        }
        for (c in v.arr("hmacSha256").objects()) {
            val mac = SyncCrypto.hmacSha256(c.hex("keyHex"), c.hex("dataHex"))
            assertEq(c.str("name"), mac.hex(), c.str("macHex"))
            c.strOrNull("trunc16Hex")?.let { assertEq(c.str("name") + " trunc", mac.slice(0, 16).hex(), it) }
            checked.ok("hmacSha256")
        }
        for (c in v.arr("groupIds").objects()) {
            val g = SyncGroup.fromKey(c.hex("keyHex"))
            assertEq(c.str("name"), g.groupId.hex(), c.str("groupId"))
            assertEq(c.str("name"), g.advertTag.hex(), c.str("advertTag"))
            assertTrue(g.isConsistent())
            checked.ok("groupIds")
        }
        for (c in v.arr("proofs").objects()) {
            val k = c.hex("keyHex")
            val (nc, np, ic, ip) = listOf("nonceC", "nonceP", "idC", "idP").map { c.hex(it) }
            val name = c.str("name")
            assertEq(name, SyncCrypto.groupId(k).hex(), c.str("groupId"))
            val tr = SyncCrypto.authTranscript(nc, np, ic, ip)
            assertEq(name, tr.hex(), c.str("transcriptHex"))
            assertEq(name, (SyncCrypto.PROOF_P_PREFIX + tr).hex(), c.str("macInputPHex"))
            assertEq(name, (SyncCrypto.PROOF_C_PREFIX + tr).hex(), c.str("macInputCHex"))
            assertEq(name, SyncCrypto.proofP(k, nc, np, ic, ip).hex(), c.str("proofP"))
            assertEq(name, SyncCrypto.proofC(k, nc, np, ic, ip).hex(), c.str("proofC"))
            checked.ok("proofs")
        }
        for (c in v.arr("textNormalize").objects()) {
            val name = c.str("name")
            val s = Utf8.decode(c.hex("inputHex"))
            assertEq("$name input", s, c.str("input"))
            val out = if (c.str("fn") == "text") SyncText.normalize(s, c.int("maxBytes")) else SyncText.normalizeKind(s)
            assertEq(name, out, c.strOrNull("output"))
            assertEq("$name bytes", out?.let { Utf8.encode(it).hex() }, c.strOrNull("outputHex"))
            checked.ok("textNormalize")
        }
        for (c in v.arr("keys").objects()) {
            val k = RecordKey(c.int("ns"), c.hex("packet"))
            assertEq("key", k.encode().hex(), c.str("keyHex"))
            assertEq("keyString", k.keyString, c.str("keyString"))
            assertEq("key fnv", "%016X".format(k.hubHash()), c.str("fnv1a64"))
            assertEq("key decode", RecordKey.decode(c.hex("keyHex")), k)
            assertEq("key parse", RecordKey.parseKeyString(k.keyString), k)
            checked.ok("keys")
        }
        done("crc32", "fnv1a64", "sha256", "hmacSha256", "groupIds", "proofs", "textNormalize", "keys")
    }

    @Test
    fun bodies() {
        for (c in v.arr("bodies").objects()) {
            val name = c.str("name")
            val body = SyncJson.bodyFromJson(c.obj("body"))
            val b = body.encode()
            assertEq("encode $name", b.hex(), c.str("hex"))
            assertEq("len $name", b.size, c.int("len"))
            val back = RecordBody.decode(c.hex("hex"))
            assertJson("decode $name", SyncJson.bodyToJson(back), c.obj("body"))
            assertEq("decode eq $name", back, body)
            assertEq("crc $name", SyncCrypto.crc32(b), c.long("crc"))
            assertEq("class $name", back.recordClass().name, c.str("class"))
            val ver = Version.of(back, b)
            val vj = c.obj("version")
            assertEq("version $name", ver, Version(vj.long("updatedAt"), java.lang.Long.parseUnsignedLong(vj.str("origin"), 16), vj.long("crc")))
            checked.ok("bodies")
        }
        for (c in v.arr("bodyRejects").objects()) {
            assertEq("reject ${c.str("name")}", errName { RecordBody.decode(c.hex("hex")) }, c.str("error"))
            checked.ok("bodyRejects")
        }
        for (c in v.arr("clock").objects()) {
            val name = c.str("name")
            if (c.has("bodyHex")) {
                val r = Ledger().applyRemote(c.hex("bodyHex"), Bytes.ZERO8, c.longOrNull("now"))
                assertEq(name, r.status.name, c.str("result"))
            } else {
                assertEq(name, errName { SyncClock.checkFuture(c.long("updatedAt"), c.longOrNull("now")) } ?: "OK", c.str("result"))
            }
            checked.ok("clock")
        }
        for (c in v.arr("comparator").objects()) {
            fun ver(j: JsonObject) = Version(j.long("updatedAt"), java.lang.Long.parseUnsignedLong(j.str("origin"), 16), j.long("crc"))
            val a = ver(c.obj("a"))
            val b = ver(c.obj("b"))
            assertEq(c.str("name"), SyncClock.compareVersions(a, b), c.int("expect"))
            assertEq(c.str("name") + " reversed", SyncClock.compareVersions(b, a), -c.int("expect"))
            checked.ok("comparator")
        }
        for (c in v.arr("localStamp").objects()) {
            assertEq(c.str("name"), SyncClock.localStamp(c.long("now"), c.long("ledgerUpdatedAt"), c.long("lastLocalStamp")), c.long("expect"))
            checked.ok("localStamp")
        }
        done("bodies", "bodyRejects", "clock", "comparator", "localStamp")
    }

    @Test
    fun apply() {
        for (sc in v.arr("apply").objects()) {
            val led = Ledger(sc.int("tombstoneCap"), sc.long("nextSyncSeq"))
            for ((i, st) in sc.arr("steps").objects().withIndex()) {
                val what = "${sc.str("name")} step $i"
                val exp = st.obj("expect")
                when (st.str("op")) {
                    "remote" -> {
                        val r = led.applyRemote(st.hex("bodyHex"), st.hexOrNull("from"), st.longOrNull("now"))
                        assertEq(what, r.status.name, exp.str("status"))
                        assertEq("$what evicted", r.evicted, exp.arr("evicted").map { it.asString })
                        val e = if (r.status == ApplyStatus.ACCEPT) r.entry?.let { SyncJson.entryToJson(it) } else null
                        assertJson("$what entry", e, exp.get("entry"))
                    }
                    "edit" -> {
                        val cls = RecordClass.valueOf(st.str("class"))
                        val isUser = cls == RecordClass.USER
                        val r = led.localEdit(
                            cls, SyncJson.keyFromJson(st.obj("key")), st.long("now"), st.hex("self"),
                            label = st.strOrNull("label"), category = st.longOrNull("category")?.toInt(),
                            kind = st.strOrNull("kind"), place = st.longOrNull("place")?.toInt(), note = st.strOrNull("note"),
                            preset = isUser && st.bool("preset"), userEdited = !isUser || st.bool("userEdited"),
                        )
                        assertEq("$what body", r.bodyBytes.hex(), exp.str("bodyHex"))
                        assertEq("$what updatedAt", r.body.updatedAt, exp.long("updatedAt"))
                        assertEq("$what evicted", r.evicted, exp.arr("evicted").map { it.asString })
                        assertJson("$what entry", r.entry?.let { SyncJson.entryToJson(it) }, exp.get("entry"))
                    }
                    "learn" -> {
                        val e = led.localLearn(st.hex("packet"))
                        assertEq(what, e != null, exp.bool("created"))
                        assertJson("$what entry", e?.let { SyncJson.entryToJson(it) }, exp.get("entry"))
                    }
                    else -> fail("unknown op ${st.str("op")}")
                }
            }
            val fin = sc.obj("final")
            val name = sc.str("name")
            assertEq("$name nextSyncSeq", led.nextSyncSeq, fin.long("nextSyncSeq"))
            assertEq("$name lastLocalStamp", led.lastLocalStamp, fin.long("lastLocalStamp"))
            assertEq("$name tombstones", led.tombstoneCount(), fin.int("tombstones"))
            assertJson("$name entries", SyncJson.ledgerToJson(led), fin.arr("entries"))
            checked.ok("apply")
        }
        done("apply")
    }

    /** decode -> typed -> fields must lose nothing; typed encode must equal the generic encode. */
    private fun checkTyped(what: String, mtype: Int, fields: Map<String, Any>, hex: String) {
        val typed = SyncMsgs.fromFields(mtype, fields)
        assertEq("$what typed type", typed.type, mtype)
        assertEq("$what typed fields", SyncJson.typedFields(typed), fields)
        assertEq("$what typed encode", typed.encode().hex(), hex)
        assertEq("$what typed decode", SyncMsgs.decode(MsgCodec.encode(mtype, fields)), typed)
    }

    @Test
    fun messages() {
        for (c in v.arr("messages").objects()) {
            val name = c.str("name")
            val mt = MsgType.code(c.str("type"))!!
            assertEq(name, mt, c.int("typeCode"))
            val fields = SyncJson.fieldsFromJson(mt, c.obj("fields"))
            val enc = MsgCodec.encode(mt, fields)
            assertEq("encode $name", enc.hex(), c.str("hex"))
            assertEq("len $name", enc.size, c.int("len"))
            assertTrue("$name fits maxMsgMin", enc.size <= SyncConst.MAXMSG_MIN)
            val (t2, f) = MsgCodec.decode(c.hex("hex"))
            assertEq(name, t2, mt)
            assertJson("decode $name", SyncJson.fieldsToJson(mt, f!!), c.obj("fields"))
            checkTyped(name, mt, f, c.str("hex"))
            checked.ok("messages")
        }
        for (c in v.arr("messageNonCanonical").objects()) {
            val name = c.str("name")
            val (mt, f) = MsgCodec.decode(c.hex("hex"))
            assertEq(name, MsgType.name(mt), c.str("type"))
            assertJson(name, SyncJson.fieldsToJson(mt, f!!), c.obj("fields"))
            assertEq("$name canonical", MsgCodec.encode(mt, f).hex(), c.str("canonicalHex"))
            assertEq("$name typed canonical", SyncMsgs.decode(c.hex("hex")).encode().hex(), c.str("canonicalHex"))
            checked.ok("messageNonCanonical")
        }
        for (c in v.arr("messageRejects").objects()) {
            assertEq(c.str("name"), errName { MsgCodec.decode(c.hex("hex")) }, "BAD_MSG")
            assertEq(c.str("name") + " typed", errName { SyncMsgs.decode(c.hex("hex")) }, c.str("error"))
            checked.ok("messageRejects")
        }
        for (c in v.arr("messageBadBody").objects()) {
            val name = c.str("name")
            val (mt, f) = MsgCodec.decode(c.hex("hex"))
            assertJson(name, SyncJson.fieldsToJson(mt, f!!), c.obj("fields"))
            val rec = SyncMsgs.decode(c.hex("hex")) as Rec
            assertEq("$name bodyFields", rec.bodyFields, null)
            assertEq("$name bodyError", rec.bodyError?.let { ErrCode.name(it.code) }, c.str("bodyError"))
            assertJson("$name errKey", rec.errKey?.let { SyncJson.keyToJson(it) }, c.get("errKey"))
            checked.ok("messageBadBody")
        }
        for (c in v.arr("messageIgnored").objects()) {
            val (_, f) = MsgCodec.decode(c.hex("hex"))
            assertEq(c.str("name"), f, null)
            assertTrue(c.str("name"), SyncMsgs.decode(c.hex("hex")) is SyncMsg.Unknown)
            checked.ok("messageIgnored")
        }
        for (c in v.arr("hbHops").objects()) {
            val out = SyncMsgs.hbSetHops(c.hex("inHex"), 1)
            assertEq(c.str("name"), out.hex(), c.str("outHex"))
            assertEq(c.str("name") + " decodes", (SyncMsgs.decode(out) as Hb).hops, 1)
            checked.ok("hbHops")
        }
        done("messages", "messageNonCanonical", "messageRejects", "messageBadBody", "messageIgnored", "hbHops")
    }

    @Test
    fun frames() {
        for (c in v.arr("frames").objects()) {
            val name = c.str("name")
            val fr = Fragmenter(c.int("startCounter"), c.int("startSeq"))
            val frames = ArrayList<String>()
            val per = ArrayList<Int>()
            for (m in c.arr("messages")) {
                val fs = fr.fragment(Bytes.fromHex(m.asString), c.int("mtu"))
                per.add(fs.size)
                frames += fs.map { it.hex() }
            }
            assertEq(name, frames, c.arr("frames").map { it.asString })
            assertEq("$name per message", per, c.arr("framesPerMessage").map { it.asInt })
            assertEq("$name chunk", SyncFrames.chunkSize(c.int("mtu")), c.int("chunk"))
            checked.ok("frames")
        }
        for (c in v.arr("reassembly").objects()) {
            val ra = Reassembler(c.int("maxMsg"))
            ra.expected = c.longOrNull("startExpectedSeq")?.toInt() ?: 0
            val got = JsonArray()
            for (f in c.arr("frames")) {
                for (a in ra.feed(Bytes.fromHex(f.asString))) {
                    got.add(
                        when (a) {
                            is FrameEvent.Deliver -> jsonOf("deliver" to a.msg)
                            is FrameEvent.BadFrame -> jsonOf("badFrame" to a.reason)
                            is FrameEvent.ErrTooBig -> jsonOf("errTooBig" to a.refType)
                            is FrameEvent.ErrProto -> jsonOf("errProto" to a.frameVersion)
                        },
                    )
                }
            }
            assertJson(c.str("name"), got, c.arr("expect"))
            checked.ok("reassembly")
        }
        done("frames", "reassembly")
    }

    private class E(override val seq: Long, override val bodyBytes: Bytes, override val syncFrom: Bytes?) : FeedEntry {
        override val origin: Bytes? = RecordBody.decode(bodyBytes).origin
    }

    @Test
    fun pages() {
        for (c in v.arr("pages").objects()) {
            val name = c.str("name")
            val pull = SyncMsgs.fromFields(MsgType.PULL, SyncJson.fieldsFromJson(MsgType.PULL, c.obj("pull"))) as Pull
            assertEq("$name pull", pull.encode().hex(), c.str("pullHex"))
            val entries = c.arr("entries").objects().map { E(it.long("seq"), it.hex("bodyHex"), it.hexOrNull("syncFrom")) }
            val r = SyncRouting.servePage(entries, c.long("durableHigh"), pull, c.bool("excludeOk"), c.hex("puller"))
            val exp = c.obj("expect")
            assertEq("$name recSeqs", r.recSeqs, exp.arr("recSeqs").map { it.asLong })
            assertEq("$name recs", r.recs.map { it.hex() }, exp.arr("recs").map { it.asString })
            assertJson("$name pageEnd", SyncJson.fieldsToJson(MsgType.PAGE_END, SyncJson.typedFields(r.pageEnd)), exp.obj("pageEnd"))
            assertEq("$name pageEndHex", r.pageEnd.encode().hex(), exp.str("pageEndHex"))
            checked.ok("pages")
        }
        done("pages")
    }

    @Test
    fun routing() {
        val r = v.obj("routing")
        fun sessions(a: JsonArray, sub: String, up: String) =
            a.objects().map { RouteSession(it.hex("peer"), it.bool(sub), it.bool(up)) }

        fun route(x: Route) = jsonOf("targets" to x.targets, "seenBy" to x.seenBy)
        for (c in r.arr("localRec").objects()) {
            assertJson(c.str("name"), route(SyncRouting.routeLocalRec(c.hex("self"), sessions(c.arr("sessions"), "subRecords", "authed"))), c.obj("expect"))
            checked.ok("routing.localRec")
        }
        for (c in r.arr("liveRec").objects()) {
            val x = SyncRouting.routeLiveRec(c.hex("self"), c.hex("sender"), c.hexOrNull("origin"), c.arr("seenBy").hexList(),
                sessions(c.arr("sessions"), "subRecords", "authed"))
            assertJson(c.str("name"), route(x), c.obj("expect"))
            checked.ok("routing.liveRec")
        }
        for (c in r.arr("evtRelay").objects()) {
            val x = SyncRouting.routeEvtRelay(c.hex("self"), c.hex("sender"), c.hex("origin"), c.arr("seenBy").hexList(),
                sessions(c.arr("sessions"), "subEvents", "member"))
            assertJson(c.str("name"), route(x), c.obj("expect"))
            checked.ok("routing.evtRelay")
        }
        for (c in r.arr("androidRoute").objects()) {
            val ios = c.objOrNull("ios")?.let { RouteSession(it.hex("peer"), it.bool("subEvents"), it.bool("up")) }
            val hub = c.objOrNull("hub")?.let { RouteSession(it.hex("peer"), true, it.bool("up")) }
            val links = c.arr("hubHbLinks").objects().map { HbLink(it.hex("peerId"), it.int("peerKind"), it.int("flags")) }
            val x = SyncRouting.androidEventRoute(c.hex("self"), ios, hub, c.longOrNull("hubHbAgeMs"), links)
            assertJson(c.str("name"), jsonOf("route" to x.route, "target" to x.target, "seenBy" to x.seenBy), c.obj("expect"))
            checked.ok("routing.androidRoute")
        }
        for (c in r.arr("hbForward").objects()) {
            val t = SyncRouting.routeHb(c.hex("self"), c.hex("sender"), c.hex("deviceId"), c.int("hops"),
                sessions(c.arr("sessions"), "subHeartbeats", "member"))
            assertJson(c.str("name"), jsonOf("targets" to t), c.obj("expect"))
            checked.ok("routing.hbForward")
        }
        for (c in r.arr("hbReplace").objects()) {
            fun hv(j: JsonObject?) = j?.let { HbVersion(it.int("bootId"), it.long("hbSeq")) }
            assertEq(c.str("name"), SyncRouting.hbReplaces(hv(c.objOrNull("stored")), hv(c.obj("incoming"))!!), c.bool("expect"))
            checked.ok("routing.hbReplace")
        }
        for (c in r.arr("subs").objects()) {
            assertEq("subs $c", SyncRouting.subsFor(c.int("selfKind"), c.int("peerKind")), c.int("subs"))
            checked.ok("routing.subs")
        }
        for (c in r.arr("caps").objects()) {
            assertEq("caps $c", SyncConst.capsByKind(c.int("kind")), c.int("caps"))
            checked.ok("routing.caps")
        }
        done("routing.localRec", "routing.liveRec", "routing.evtRelay", "routing.androidRoute", "routing.hbForward",
            "routing.hbReplace", "routing.subs", "routing.caps")
    }

    @Test
    fun events() {
        fun windows(d: EvtDedupe, o: Bytes) = JsonArray().also { a ->
            d.windows(o).forEach { a.add(jsonOf("epoch" to it.epoch, "hc" to it.hc, "bits" to it.bitsHex())) }
        }
        for (sc in v.arr("eventDedupe").objects()) {
            val d = EvtDedupe()
            for ((i, st) in sc.arr("steps").objects().withIndex()) {
                val o = st.hex("origin")
                val got = if (st.str("op") == "evt") {
                    val res = d.receive(o, st.long("epoch"), st.long("seq"))
                    jsonOf("result" to res.result.name, "lost" to res.lost, "holes" to d.hasHoles(o, st.long("epoch")),
                        "windows" to windows(d, o))
                } else {
                    val g = d.onGap(o, st.long("epoch"), st.long("firstAvail"), st.long("lastAvail"), st.long("curEpoch"))
                    val reqs = JsonArray().also { a -> g.requests.forEach { a.add(jsonOf("epoch" to it.first, "afterSeq" to it.second)) } }
                    jsonOf("lost" to g.lost, "requests" to reqs, "windows" to windows(d, o))
                }
                assertJson("${sc.str("name")} step $i", got, st.obj("expect"))
            }
            checked.ok("eventDedupe")
        }
        for (c in v.arr("replayPlan").objects()) {
            val ring = c.arr("ring").map { it.asJsonArray.let { p -> RingId(p[0].asLong, p[1].asLong) } }
            val plan = SyncEvents.replayPlan(ring, c.long("curEpoch"), c.long("curSeq"), c.long("epoch"), c.long("afterSeq"))
            val got = JsonArray()
            for (p in plan) {
                got.add(
                    when (p) {
                        is ReplayItem.Replay -> jsonOf("replay" to jsonOf("epoch" to p.epoch, "seq" to p.seq))
                        is ReplayItem.Gap -> jsonOf("gap" to jsonOf("epoch" to p.epoch, "firstAvail" to p.firstAvail,
                            "lastAvail" to p.lastAvail, "curEpoch" to p.curEpoch))
                    },
                )
            }
            assertJson(c.str("name"), got, c.arr("expect"))
            checked.ok("replayPlan")
        }
        done("eventDedupe", "replayPlan")
    }

    @Test
    fun sessions() {
        for (sc in v.arr("sessions").objects()) {
            val core = SyncSessionHarness.coreFromJson(sc.obj("config"), sc.obj("ctx"))
            for ((i, st) in sc.arr("steps").objects().withIndex()) {
                st.objOrNull("ctx")?.let { SyncSessionHarness.applyCtx(core.ctx, it) }
                val inp = st.obj("in")
                val acts = core.handle(st.long("t"), SyncSessionHarness.inputFromJson(inp))
                val what = "${sc.str("name")} step $i (${inp.str("in")})"
                assertJson(what, SyncSessionHarness.actionsToJson(acts), st.arr("out"))
                assertJson("$what snapshot", SyncSessionHarness.snapshotToJson(core.snapshot()), st.obj("after"))
                for (a in acts) {
                    if (a is SessionAction.Send) assertEq("$what sent bytes decode to the declared type", SyncMsgs.decode(a.bytes).type, a.type)
                }
            }
            checked.ok("sessions")
        }
        done("sessions")
    }
}

/** Builds session cores from the `sessions` vectors' JSON and serialises their actions (README). */
internal object SyncSessionHarness {
    fun coreFromJson(cfg: JsonObject, ctx: JsonObject): SessionCore {
        val config = SessionConfig(
            role = if (cfg.str("role") == "central") SessionRole.CENTRAL else SessionRole.PERIPHERAL,
            deviceId = cfg.hex("deviceId"),
            kind = cfg.int("kind"),
            bootId = cfg.int("bootId"),
            maxMsg = cfg.int("maxMsg"),
            caps = cfg.int("caps"),
            version = cfg.strOrNull("version"),
            name = cfg.strOrNull("name"),
            peerKind = cfg.longOrNull("peerKind")?.toInt(),
            tracksEvents = cfg.bool("tracksEvents"),
            isHub = cfg.bool("isHub"),
        )
        val base = ctx.longOrNull("clockBaseMs")
        val nonces = ArrayDeque(ctx.arr("nonces").hexList())
        val peers = HashMap<Bytes, PeerState>()
        for ((k, p) in ctx.obj("peers").entrySet()) {
            val o = p.asJsonObject
            peers[Bytes.fromHex(k)] = PeerState(o.hex("dbId"), o.long("wm"), o.bool("excludeOk"))
        }
        val x = SessionCtx(
            group = groupOf(ctx),
            dbId = ctx.hex("dbId"),
            feedHigh = ctx.long("feedHigh"),
            clock = { t -> if (base != null) base + t else 0L },
            nextNonce = { nonces.removeFirst() },
            ready = ctx.bool("ready"),
            peers = peers,
        )
        return SessionCore(config, x)
    }

    private fun groupOf(j: JsonObject): SyncGroup? =
        j.hexOrNull("groupId")?.let { SyncGroup(it, j.hex("groupKey")) }

    fun applyCtx(ctx: SessionCtx, j: JsonObject) {
        ctx.group = groupOf(j)
        ctx.dbId = j.hex("dbId")
        ctx.feedHigh = j.long("feedHigh")
        ctx.ready = j.bool("ready")
    }

    fun inputFromJson(j: JsonObject): SessionInput = when (val k = j.str("in")) {
        "link_up" -> SessionInput.LinkUp(j.longOrNull("mtu")?.toInt() ?: 185)
        "link_down" -> SessionInput.LinkDown
        "rx" -> SessionInput.Rx(j.hex("hex"))
        "timer" -> SessionInput.Timer(SessionTimer.valueOf(j.str("name")))
        "group_changed" -> SessionInput.GroupChanged
        "rekey" -> SessionInput.Rekey
        "pull_now" -> SessionInput.PullNow
        else -> throw IllegalArgumentException("input $k")
    }

    fun actionsToJson(acts: List<SessionAction>): JsonArray = JsonArray().also { a ->
        for (x in acts) {
            a.add(
                when (x) {
                    is SessionAction.Send -> jsonOf("a" to "send", "type" to MsgType.name(x.type), "hex" to x.bytes)
                    is SessionAction.State -> jsonOf("a" to "state", "to" to x.to.name)
                    is SessionAction.Deliver -> jsonOf("a" to "deliver", "type" to MsgType.name(x.type))
                    is SessionAction.Commit -> jsonOf("a" to "commit", "wm" to x.wm)
                    is SessionAction.Group -> jsonOf("a" to "group", "groupId" to x.group.groupId, "groupKey" to x.group.groupKey,
                        "rekey" to x.rekey)
                    is SessionAction.Node -> jsonOf("a" to "node", "what" to x.what.wire)
                    is SessionAction.Disconnect -> jsonOf("a" to "disconnect", "reason" to x.reason.wire, "retryMs" to x.retryMs)
                },
            )
        }
    }

    fun snapshotToJson(s: SessionSnapshot): JsonObject {
        val timers = JsonObject()
        for ((k, due) in s.timers) timers.addProperty(k.name, due)
        val j = jsonOf("state" to s.state.name, "timers" to timers)
        s.peer?.let { j.add("peer", jsonOf("dbId" to it.dbId, "wm" to it.wm, "excludeOk" to it.excludeOk)) }
        return j
    }
}
