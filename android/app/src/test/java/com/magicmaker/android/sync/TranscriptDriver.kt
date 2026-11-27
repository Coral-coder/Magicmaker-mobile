package com.magicmaker.android.sync

import com.google.gson.JsonArray
import com.google.gson.JsonObject

// Node-level transcript replay (docs/SYNC_P3_ANDROID_PLAN.md §10.2 SyncNodeReplayTest): a Kotlin
// port of gen_vectors.Sim that runs every transcript node as a real SyncNode (Android with
// AndroidRole, the iPhone and the hub with the stand-in roles, scripted strangers as raw senders),
// re-creates the scenario's stimuli from the transcript (link_up / link_down / local ops / scripted
// messages, pushed first so they win ties as the scenario's own sim.at calls do), and logs steps in
// the transcript's format so the whole run can be compared step by step.

internal class TranscriptDriver(
    private val j: JsonObject,
    /** Non-null: every link is a LoopbackGatt with LinkChannels (random latency), not the sim's 15 ms pipe. */
    private val loopback: java.util.Random? = null,
    /** Loopback: drop one ATT value in this many (0 = never). */
    private val dropOneIn: Int = 0,
    /** Loopback: re-link this long after a link the nodes closed themselves (not a scenario link_down). */
    private val autoRelinkMs: Long? = null,
) {
    private val lat: Long = j.long("latencyMs")
    private val base: Long = j.long("clockBaseMs")
    val sched = VirtualScheduler(base)
    val steps = ArrayList<JsonObject>()

    private inner class SimLink(val id: String, val c: SimNode, val p: SimNode, val mtu: Int, val gen: Int) {
        var scenarioDown = false
        var up = true

        fun other(n: SimNode): SimNode = if (n === c) p else c
    }

    abstract inner class SimNode(val name: String, val kind: Int, val id: Bytes)

    inner class RealNode(
        name: String,
        kind: Int,
        id: Bytes,
        val identity: FakeIdentity,
        val lib: FakeLibraryPort,
        val role: NodeRole,
        val ringCap: Int,
    ) : SimNode(name, kind, id) {
        lateinit var node: SyncNode
    }

    inner class ScriptedNode(name: String, kind: Int, id: Bytes) : SimNode(name, kind, id) {
        val received = ArrayList<Bytes>()
    }

    val nodes = LinkedHashMap<String, SimNode>()
    private val links = HashMap<String, SimLink>()
    private val gens = HashMap<String, Int>()
    private val gatts = HashMap<String, LoopbackGatt>()
    private val allGatts = ArrayList<LoopbackGatt>()

    /** ATT values the loopback dropped (all links, all generations). */
    val droppedFrames: Int get() = allGatts.sumOf { it.drops }
    val channels = HashMap<Pair<String, String>, LinkChannel>()

    /** Loopback invariants (plan §10.2), checked on every message a node queues. */
    val violations = ArrayList<String>()

    private inner class CheckedPort(private val inner: LinkPort, private val me: RealNode, private val peerName: String) : LinkPort {
        override val id: String get() = inner.id

        override fun send(type: Int, bytes: Bytes, lane: Int) {
            val peer = nodes[peerName]
            when (type) {
                MsgType.REC -> {
                    val m = SyncMsgs.decode(bytes) as Rec
                    if (m.isLive && peer != null && m.bodyFields?.origin == peer.id) violations.add("${me.name}->$peerName live REC to its origin")
                }
                MsgType.PAGE_END -> {
                    val m = SyncMsgs.decode(bytes) as PageEnd
                    if (m.scannedTo > me.lib.durableHigh()) violations.add("${me.name} PAGE_END scannedTo ${m.scannedTo} > durable ${me.lib.durableHigh()}")
                }
            }
            inner.send(type, bytes, lane)
        }

        override fun disconnect(reason: String, retryMs: Long?) = inner.disconnect(reason, retryMs)

        override fun pendingLive(): Int = inner.pendingLive()

        override fun mtu(): Int = inner.mtu()
    }

    private inner class Port(private val linkId: String, private val me: SimNode) : LinkPort {
        override val id: String get() = linkId

        override fun send(type: Int, bytes: Bytes, lane: Int) = simSend(linkId, me, bytes)

        override fun disconnect(reason: String, retryMs: Long?) = scheduleDisconnect(linkId, reason)
    }

    // ---- logging -----------------------------------------------------------------------------

    private fun log(ev: String, vararg kv: Pair<String, Any?>) {
        val o = jsonOf("t" to sched.now(), "ev" to ev)
        for ((k, v) in kv) o.add(k, toJson(v))
        steps.add(o)
    }

    private inner class NodeTrace(private val name: String) : SyncTrace {
        override fun state(linkId: String, to: SessionState) = log("state", "node" to name, "link" to linkId, "state" to to.name)

        override fun apply(linkId: String, key: String?, status: ApplyStatus, live: Boolean) =
            log("apply", "node" to name, "link" to linkId, "key" to key, "status" to status.name, "live" to live)

        override fun group(linkId: String, groupId: Bytes, rekey: Boolean) =
            log("group", "node" to name, "link" to linkId, "groupId" to groupId, "rekey" to rekey)

        override fun foreign(linkId: String) = log("foreign", "node" to name, "link" to linkId)

        override fun disconnect(linkId: String, reason: String, retryMs: Long?) {
            log("disconnect", "node" to name, "link" to linkId, "reason" to reason, "retryMs" to retryMs)
        }

        override fun timer(linkId: String, name: SessionTimer) = log("timer", "node" to this.name, "link" to linkId, "name" to name.name)

        override fun heard(evt: Evt, route: Int) =
            log("local", "node" to name, "op" to "heard", "epoch" to evt.epoch, "seq" to evt.seq, "packet" to evt.packet, "route" to route)
    }

    // ---- setup -------------------------------------------------------------------------------

    private val internalReasons = DisconnectReason.values().map { it.wire }.toSet() + "db_reset"
    private lateinit var evtFields: Map<Pair<Long, Long>, Evt>

    init {
        val firstHb = HashMap<String, Hb>()
        val firstEvt = HashMap<Pair<Long, Long>, Evt>()
        for (st in j.arr("steps").objects()) {
            if (st.str("ev") != "msg") continue
            val from = st.str("from")
            when (st.str("type")) {
                "HB" -> if (from !in firstHb) (SyncMsgs.decode(st.hex("hex")) as Hb).let { if (it.hops == 0) firstHb[from] = it }
                "EVT" -> (SyncMsgs.decode(st.hex("hex")) as Evt).let { firstEvt.putIfAbsent(it.epoch to it.seq, it) }
            }
        }
        evtFields = firstEvt
        for ((name, nj) in j.obj("nodes").entrySet()) {
            val o = nj.asJsonObject
            val id = o.hex("deviceId")
            val kind = o.int("kind")
            if (o.has("scripted") && o.bool("scripted")) {
                nodes[name] = ScriptedNode(name, kind, id)
                continue
            }
            nodes[name] = makeNode(name, o, firstHb[name])
        }
        pushStimuli()
    }

    private fun makeNode(name: String, o: JsonObject, hb: Hb?): RealNode {
        val id = o.hex("deviceId")
        val kind = o.int("kind")
        val group = o.hexOrNull("groupKey")?.let { SyncGroup(o.hex("groupId"), it) }
        val identity = FakeIdentity(id, o.hex("dbId"), group)
        val ledger = Ledger(nextSyncSeq = o.long("nextSyncSeq"))
        for (e in o.arr("ledger").objects()) ledger.restore(LedgerEntry.restore(e.hex("b"), e.long("s"), e.hexOrNull("f")))
        val peers = LinkedHashMap<Bytes, PeerState>()
        for ((k, v) in o.obj("peers").entrySet()) {
            val p = v.asJsonObject
            peers[Bytes.fromHex(k)] = PeerState(p.hex("dbId"), p.long("wm"), p.bool("excludeOk"))
        }
        val lib = FakeLibraryPort(kind, sched, ledger, o.long("durableHigh"), peers) { high ->
            log("durable", "node" to name, "durableHigh" to high)
        }
        val ringCap = o.longOrNull("ringCap")?.toInt() ?: SyncConst.ANDROID_EVT_RING
        val role: NodeRole = when (kind) {
            SyncConst.KIND_ANDROID -> AndroidRole(FakeEventOrigin(id, o.long("epoch"), ringCap))
            SyncConst.KIND_IOS -> IosStandInRole { linkId, m, r ->
                log("ingest", "node" to name, "link" to linkId, "origin" to m.origin, "epoch" to m.epoch, "seq" to m.seq,
                    "result" to r.result.name, "replay" to m.isReplay, "lost" to r.lost)
            }.also { ios ->
                ios.onGap = { linkId, m, r ->
                    val reqs = JsonArray().also { a -> r.requests.forEach { (e, q) -> a.add(jsonOf("epoch" to e, "afterSeq" to q)) } }
                    log("gap", "node" to name, "link" to linkId, "origin" to m.origin, "epoch" to m.epoch, "lost" to r.lost, "requests" to reqs)
                }
            }
            else -> HubStandInRole(o.bool("clockKnown"))
        }
        val rn = RealNode(name, kind, id, identity, lib, role, ringCap)
        val nonces = DetNonces(id)
        val self = SelfStatus(
            battPct = hb?.battPctOrDefault ?: -1,
            battMv = hb?.battMvOrDefault ?: -1,
            charging = hb?.chargingOrDefault ?: -1,
            runtimeMin = hb?.runtimeMinOrDefault ?: -1,
            state = hb?.stateOrDefault ?: 0,
            hubAirAgoS = hb?.hubAirAgoS,
        )
        val node = SyncNode(
            cfg = NodeConfig(id, kind, o.int("maxMsg"), o.strOrNull("version"), o.strOrNull("name")),
            identity = identity,
            library = lib,
            roster = FakeRoster(),
            sched = sched,
            role = role,
            self = { self.copy(uptimeS = 1000 + sched.now() / 1000) },
            policy = NodePolicy.TRANSCRIPT,
            nonces = { nonces.next() },
            bootId = o.int("bootId"),
        )
        node.trace = NodeTrace(name)
        lib.setListener(node.inlineListener())
        rn.node = node
        return rn
    }

    /** The scenario's own sim.at() calls, recovered from the steps they logged. */
    private fun pushStimuli() {
        for (st in j.arr("steps").objects()) {
            val t = st.long("t")
            when (st.str("ev")) {
                "link_up" -> {
                    val lid = st.str("link")
                    val c = st.str("central")
                    val p = st.str("peripheral")
                    val mtu = st.int("mtu")
                    sched.at(t) { linkUp(lid, c, p, mtu) }
                }
                "link_down" -> if (st.str("reason") !in internalReasons) {
                    val lid = st.str("link")
                    val reason = st.str("reason")
                    sched.at(t) { linkDown(lid, reason) }
                }
                "msg" -> if (st.str("by") == "script") {
                    val lid = st.str("link")
                    val from = nodes.getValue(st.str("from"))
                    val data = st.hex("hex")
                    sched.at(t) { simSend(lid, from, data) }
                }
                "local" -> {
                    val n = nodes.getValue(st.str("node")) as RealNode
                    when (st.str("op")) {
                        "edit" -> {
                            val cls = RecordClass.valueOf(st.str("cls"))
                            val body = RecordBody.decode(st.hex("bodyHex"))
                            sched.at(t) { localEdit(n, cls, body) }
                        }
                        "learn" -> {
                            val key = RecordKey.parseKeyString(st.str("key"))!!
                            sched.at(t) { localLearn(n, key.packet) }
                        }
                        "heard" -> {
                            val packet = st.hex("packet")
                            val ep = st.long("epoch")
                            val seq = st.long("seq")
                            sched.at(t) { heard(n, packet, evtFields[ep to seq]?.rssi ?: -60) }
                        }
                        "service_restart" -> {
                            val boot = st.int("bootId")
                            sched.at(t) { serviceRestart(n, boot) }
                        }
                        "sync_reset" -> {
                            val db = st.hex("dbId")
                            sched.at(t) { syncReset(n, db) }
                        }
                        else -> throw AssertionError("unknown local op ${st.str("op")}")
                    }
                }
            }
        }
    }

    // ---- links (gen_vectors.Sim) ---------------------------------------------------------------

    var relinks = 0
        private set

    fun linkUp(lid: String, central: String, peripheral: String, mtu: Int) {
        val c = nodes.getValue(central)
        val p = nodes.getValue(peripheral)
        val gen = (gens[lid] ?: 0) + 1
        gens[lid] = gen
        val link = SimLink(lid, c, p, mtu, gen)
        links[lid] = link
        log("link_up", "link" to lid, "gen" to gen, "central" to central, "peripheral" to peripheral, "mtu" to mtu)
        val rng = loopback
        if (rng != null) {
            val g = LoopbackGatt(sched, rng, mtu, lid, lid, dropOneIn, onClosed = { reason ->
                val l = links[lid]
                if (l != null && l.gen == gen && l.up) linkDown(lid, reason)
            })
            gatts[lid] = g
            allGatts.add(g)
            val cp = p as RealNode
            val cc = c as RealNode
            val chP = LinkChannel(g.b, sched, cp.node.cfg.maxMsg, onMessage = { m -> cp.node.onMessage(lid, m) })
            val chC = LinkChannel(g.a, sched, cc.node.cfg.maxMsg, onMessage = { m -> cc.node.onMessage(lid, m) })
            g.b.channel = chP
            g.a.channel = chC
            channels[lid to p.name] = chP
            channels[lid to c.name] = chC
            cp.node.linkUp(CheckedPort(chP, cp, c.name), SessionRole.PERIPHERAL, mtu, null)
            cc.node.linkUp(CheckedPort(chC, cc, p.name), SessionRole.CENTRAL, mtu, p.kind)
            return
        }
        if (p is RealNode) p.node.linkUp(Port(lid, p), SessionRole.PERIPHERAL, mtu, null)
        if (c is RealNode) c.node.linkUp(Port(lid, c), SessionRole.CENTRAL, mtu, p.kind)
    }


    fun linkDown(lid: String, reason: String) {
        val link = links[lid] ?: return
        if (!link.up) return
        link.up = false
        val relink = autoRelinkMs
        if (relink != null && reason != SCENARIO_DOWN) {
            val gen = link.gen
            sched.at(sched.now() + relink) {
                val l = links[lid]
                if (l != null && l.gen == gen && !l.up) {
                    relinks++
                    linkUp(lid, link.c.name, link.p.name, link.mtu)
                }
            }
        }
        log("link_down", "link" to lid, "reason" to reason)
        gatts.remove(lid)?.cut()
        channels.remove(lid to link.p.name)?.linkLost()
        channels.remove(lid to link.c.name)?.linkLost()
        for (n in listOf(link.p, link.c)) if (n is RealNode) n.node.linkDown(lid)
    }

    private fun scheduleDisconnect(lid: String, reason: String) {
        val link = links[lid] ?: return
        if (!link.up) return
        val gen = link.gen
        sched.at(sched.now() + lat + 1) {
            val l = links[lid]
            if (l != null && l.gen == gen && l.up) linkDown(lid, reason)
        }
    }

    private fun simSend(lid: String, from: SimNode, data: Bytes) {
        val link = links[lid] ?: return
        if (!link.up) return
        val to = link.other(from)
        log("msg", "link" to lid, "gen" to link.gen, "from" to from.name, "to" to to.name, "type" to MsgType.name(data[0]), "hex" to data)
        val gen = link.gen
        sched.at(sched.now() + lat) {
            val l = links[lid]
            if (l != null && l.gen == gen && l.up) {
                when (to) {
                    is RealNode -> to.node.onMessage(lid, data)
                    is ScriptedNode -> to.received.add(data)
                }
            }
        }
    }

    // ---- local ops -------------------------------------------------------------------------------

    fun localEdit(n: RealNode, cls: RecordClass, b: RecordBody) {
        n.lib.localEdit(
            cls, b.key, n.id, label = b.label, category = b.category, kind = b.kind, place = b.place, note = b.note,
            preset = b.flags and SyncConst.FLAG_PRESET != 0, userEdited = b.flags and SyncConst.FLAG_USER_EDITED != 0,
        ) { r ->
            log("local", "node" to n.name, "op" to "edit", "cls" to cls.name, "key" to r.body.key.keyString, "bodyHex" to r.bodyBytes,
                "seq" to (r.entry?.seq ?: -1L))
        }
    }

    fun localLearn(n: RealNode, packet: Bytes) {
        n.lib.localLearn(packet) { e ->
            log("local", "node" to n.name, "op" to "learn", "key" to RecordKey(SyncConst.NS_LIB, packet).keyString, "created" to (e != null))
        }
    }

    fun heard(n: RealNode, packet: Bytes, rssi: Int?) {
        val role = n.role as AndroidRole
        val next = (role.events?.seq ?: 0) + 1
        role.originate(packet, rssi, 1, 283852000 + next.toInt(), -815639000, 8, Bytes.fromHex("D0C1B2A39400"), 0)
    }

    private fun serviceRestart(n: RealNode, bootId: Int) {
        val role = n.role as AndroidRole
        val old = role.events!!.epoch
        val epoch = maxOf((base + sched.now()) / 1000, old + 1)
        role.serviceRestart(bootId, FakeEventOrigin(n.id, epoch, n.ringCap))
        log("local", "node" to n.name, "op" to "service_restart", "bootId" to bootId, "epoch" to epoch)
    }

    private fun syncReset(n: RealNode, db: Bytes) {
        n.identity.db = db
        n.lib.reset()
        log("local", "node" to n.name, "op" to "sync_reset", "dbId" to db)
        n.node.dbReset("db_reset")
    }

    // ---- run and compare ---------------------------------------------------------------------------

    fun run(extraMs: Long = 0): TranscriptDriver {
        sched.run(j.obj("final").long("t") + extraMs)
        return this
    }

    /** Links that are up now. */
    fun upLinks(): List<String> = links.values.filter { it.up }.map { it.id }

    /** key -> (u, o, c, b) of a node's ledger (what must converge; s and f are local). */
    fun versions(name: String): Map<String, List<String?>> =
        real(name).lib.ledger.entriesByKey().associate { e -> e.keyString to listOf(e.version.updatedAt.toString(), e.origin?.hex(), e.version.crc.toString(), e.bodyBytes.hex()) }

    /** First mismatch between the produced steps and the transcript's (notes excluded), or null. */
    fun stepMismatch(): String? {
        val want = j.arr("steps").objects().filter { it.str("ev") != "note" }
        val got = steps
        for (i in 0 until maxOf(want.size, got.size)) {
            val g = got.getOrNull(i)
            val w = want.getOrNull(i)
            if (g == null || w == null) return "step $i: got ${g ?: "<end>"} want ${w ?: "<end>"}"
            val wSub = JsonObject()
            for (k in g.keySet()) wSub.add(k, w.get(k))
            if (!jsonEq(g, wSub)) return "step $i:\n  got:  $g\n  want: $w"
        }
        return null
    }

    fun finalJson(name: String): JsonObject {
        val n = nodes.getValue(name) as RealNode
        val o = JsonObject()
        o.add("dbId", toJson(n.identity.dbId))
        o.add("groupId", toJson(n.identity.group?.groupId))
        o.add("durableHigh", toJson(n.lib.durableHigh()))
        o.add("nextSyncSeq", toJson(n.lib.ledger.nextSyncSeq))
        o.add("ledger", SyncJson.ledgerToJson(n.lib.ledger))
        val peers = JsonObject()
        for ((k, v) in n.node.peerTable().entries.sortedBy { it.key.hex() }) {
            peers.add(k.hex(), jsonOf("dbId" to v.dbId, "wm" to v.wm, "excludeOk" to v.excludeOk))
        }
        o.add("peers", peers)
        when (val r = n.role) {
            is AndroidRole -> {
                val ev = r.events as FakeEventOrigin
                o.add("epoch", toJson(ev.epoch))
                o.add("evtSeq", toJson(ev.seq))
                o.add("ring", JsonArray().also { a -> ev.ringIds().forEach { a.add(toJson(listOf(it.epoch, it.seq))) } })
            }
            is IosStandInRole -> {
                val w = JsonObject()
                for (origin in r.dedupe.origins().sortedBy { it.hex() }) {
                    w.add(origin.hex(), JsonArray().also { a ->
                        r.dedupe.windows(origin).forEach { a.add(jsonOf("epoch" to it.epoch, "hc" to it.hc, "bits" to it.bitsHex())) }
                    })
                }
                o.add("evtWindows", w)
            }
        }
        return o
    }

    fun real(name: String): RealNode = nodes.getValue(name) as RealNode

    companion object {
        const val SCENARIO_DOWN: String = "out of range"
    }
}
