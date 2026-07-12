package com.magicmaker.android.service

import android.app.*
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.magicmaker.android.MainActivity
import com.magicmaker.android.MagicMakerApp
import com.magicmaker.android.R
import com.magicmaker.android.ble.BleAdvertiser
import com.magicmaker.android.ble.BleScanner
import com.magicmaker.android.core.*
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.relay.HotspotManager
import com.magicmaker.android.relay.RelayCommands
import com.magicmaker.android.relay.RelayGattServer
import com.magicmaker.android.relay.RelayHttpServer
import com.magicmaker.android.relay.RelayPairingPayload
import com.magicmaker.android.relay.RelayProtocol
import java.util.concurrent.Executors

/**
 * Background BLE engine: scan, auto-response, transmit.
 * Relay (WiFi / GATT) reserved for future iPhone remote control.
 */
class MagicMakerForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "magicmaker_ble"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.magicmaker.android.START"
        const val ACTION_STOP = "com.magicmaker.android.STOP"
        const val ACTION_TRANSMIT = "com.magicmaker.android.TRANSMIT"
        const val ACTION_VIBRATE = "com.magicmaker.android.VIBRATE"
        const val ACTION_SET_RELAY = "com.magicmaker.android.SET_RELAY"
        const val ACTION_SET_RECORDING = "com.magicmaker.android.SET_RECORDING"
        const val ACTION_SET_AUTO = "com.magicmaker.android.SET_AUTO"
        const val ACTION_CLEAR_LIVE = "com.magicmaker.android.CLEAR_LIVE"
        const val ACTION_SET_SCAN = "com.magicmaker.android.SET_SCAN"
        const val ACTION_SET_STARLIGHT_LOOP = "com.magicmaker.android.SET_STARLIGHT_LOOP"
        const val ACTION_SET_TX_LOOP = "com.magicmaker.android.SET_TX_LOOP"
        const val ACTION_SET_RANDOM_SHOW = "com.magicmaker.android.SET_RANDOM_SHOW"
        const val ACTION_REFRESH_RELAY_CACHE = "com.magicmaker.android.REFRESH_RELAY_CACHE"
        const val ACTION_REPLAY = "com.magicmaker.android.REPLAY"
        const val ACTION_REPLAY_STOP = "com.magicmaker.android.REPLAY_STOP"

        const val EXTRA_HEX = "hex"
        const val EXTRA_RELAY_MODE = "relay_mode"
        const val EXTRA_RECORDING = "recording"
        const val EXTRA_SCAN = "scan_active"
        const val EXTRA_AUTO = "auto"
        const val EXTRA_STARLIGHT_ENABLED = "starlight_enabled"
        const val EXTRA_STARLIGHT_PACKET_ID = "starlight_packet_id"
        const val EXTRA_STARLIGHT_INTERVAL_MS = "starlight_interval_ms"
        const val EXTRA_TX_LOOP_ENABLED = "tx_loop_enabled"
        const val EXTRA_TX_LOOP_PACKET_ID = "tx_loop_packet_id"
        const val EXTRA_TX_LOOP_INTERVAL_MS = "tx_loop_interval_ms"
        const val EXTRA_RANDOM_SHOW_ENABLED = "random_show_enabled"
        const val EXTRA_RANDOM_SHOW_INTERVAL_MS = "random_show_interval_ms"
        const val EXTRA_REPLAY_PATH = "replay_path"
        const val EXTRA_REPLAY_CATEGORIES = "replay_categories"
        const val EXTRA_REPLAY_ADDRESS = "replay_address"
        const val EXTRA_REPLAY_BAND_ONLY = "replay_band_only"

        fun start(context: Context) {
            launch(context, ACTION_START)
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean(PREF_SERVICE_STARTED, true)
                .apply()
        }

        fun stop(context: Context) {
            launch(context, ACTION_STOP)
        }

        fun transmit(context: Context, hex: String) {
            launch(context, ACTION_TRANSMIT) { putExtra(EXTRA_HEX, hex) }
        }

        fun vibrate(context: Context) {
            launch(context, ACTION_VIBRATE)
        }

        fun send(context: Context, action: String, configure: Intent.() -> Unit = {}) {
            launch(context, action, configure)
        }

        fun setStarlightLoop(
            context: Context,
            enabled: Boolean,
            packetId: Long? = null,
            intervalMs: Long? = null,
        ) {
            launch(context, ACTION_SET_STARLIGHT_LOOP) {
                putExtra(EXTRA_STARLIGHT_ENABLED, enabled)
                packetId?.let { putExtra(EXTRA_STARLIGHT_PACKET_ID, it) }
                intervalMs?.let { putExtra(EXTRA_STARLIGHT_INTERVAL_MS, it) }
            }
        }

        fun setTxLoop(
            context: Context,
            enabled: Boolean,
            packetId: Long? = null,
            intervalMs: Long? = null,
        ) {
            launch(context, ACTION_SET_TX_LOOP) {
                putExtra(EXTRA_TX_LOOP_ENABLED, enabled)
                packetId?.let { putExtra(EXTRA_TX_LOOP_PACKET_ID, it) }
                intervalMs?.let { putExtra(EXTRA_TX_LOOP_INTERVAL_MS, it) }
            }
        }

        fun setRandomShow(
            context: Context,
            enabled: Boolean,
            intervalMs: Long? = null,
        ) {
            launch(context, ACTION_SET_RANDOM_SHOW) {
                putExtra(EXTRA_RANDOM_SHOW_ENABLED, enabled)
                intervalMs?.let { putExtra(EXTRA_RANDOM_SHOW_INTERVAL_MS, it) }
            }
        }

        /** Push latest storeRevision / catalog to GATT after UI-side MagicStore edits. */
        fun refreshRelayCache(context: Context) {
            launch(context, ACTION_REFRESH_RELAY_CACHE)
        }

        fun replay(
            context: Context,
            path: String,
            categories: List<String>,
            address: String,
            bandOnly: Boolean,
        ) {
            launch(context, ACTION_REPLAY) {
                putExtra(EXTRA_REPLAY_PATH, path)
                putExtra(EXTRA_REPLAY_CATEGORIES, categories.joinToString(","))
                putExtra(EXTRA_REPLAY_ADDRESS, address)
                putExtra(EXTRA_REPLAY_BAND_ONLY, bandOnly)
            }
        }

        fun stopReplay(context: Context) {
            launch(context, ACTION_REPLAY_STOP)
        }

        private fun launch(context: Context, action: String, configure: Intent.() -> Unit = {}) {
            val i = Intent(context, MagicMakerForegroundService::class.java)
                .setAction(action)
                .apply(configure)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        private const val PREFS = "magicmaker"
        private const val PREF_SERVICE_STARTED = "service_was_started"
        const val PREF_START_ON_BOOT = "start_on_boot"
        const val PREF_SCAN_ACTIVE = "scan_active"
        const val PREF_RECORD_SESSION = "record_session"

        // Replay step bounds: each packet is broadcast for the recorded gap to the next,
        // clamped so BLE advertising is practical.
        private const val REPLAY_MIN_STEP_MS = 60L
        private const val REPLAY_MAX_STEP_MS = 10_000L
        private const val REPLAY_TAIL_MS = 800L
    }

    private lateinit var store: MagicStore
    private var transmitter: MagicTransmitter? = null
    private var bleAdvertiser: BleAdvertiser? = null
    private var bleScanner: BleScanner? = null
    private var leScanner: android.bluetooth.le.BluetoothLeScanner? = null
    private var scanCallback: android.bluetooth.le.ScanCallback? = null
    private var httpServer: RelayHttpServer? = null
    private var gattServer: RelayGattServer? = null
    private var hotspotManager: HotspotManager? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null
    private var locationManager: LocationManager? = null
    @Volatile private var lastLocation: Location? = null
    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) { lastLocation = location }
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var scanResumeRunnable: Runnable? = null
    private var relayMode = RelayControlMode.STANDALONE
    private var recordSession = true
    private var autoEnabled = true
    private var lastAutoAt = 0L
    private var lastNotifyAt = 0L
    private var lastHeardUiAt = 0L
    private var booted = false
    private var starlightLoopEnabled = false
    private var starlightLoopPacketId = -1L
    private var starlightIntervalMs = 3000L
    private var starlightLoopRunnable: Runnable? = null
    private var txLoopEnabled = false
    private var txLoopPacketId = -1L
    private var txLoopIntervalMs = 3000L
    private var txLoopRunnable: Runnable? = null
    private var randomShowEnabled = false
    private var randomShowIntervalMs = 3000L
    private var randomShowLabel = ""
    private var randomShowRunnable: Runnable? = null
    private var screenOn = true
    private var userWantsScan = true
    private var txRunning = false
    private val txQueue = ArrayDeque<() -> Unit>()
    private var replaying = false
    private var replayCancel = false

    private val systemEventsReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    screenOn = false
                    if (booted && userWantsScan) restartScanWithScreenMode()
                }
                Intent.ACTION_SCREEN_ON -> {
                    screenOn = true
                    ensureWakeLockHeld()
                    if (booted && userWantsScan) restartScanWithScreenMode()
                }
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                    when (state) {
                        BluetoothAdapter.STATE_ON -> {
                            if (!booted) boot() else {
                                restartRelay()
                                if (userWantsScan) restartScanWithScreenMode()
                            }
                        }
                        BluetoothAdapter.STATE_OFF -> {
                            publishState { it.copy(running = false, scanActive = false, status = "Turn on Bluetooth") }
                        }
                    }
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        store = (application as MagicMakerApp).store
        loadPrefs()
        registerSystemEventsReceiver()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                shutdown()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_TRANSMIT -> {
                if (!booted) boot()
                intent.getStringExtra(EXTRA_HEX)?.let { queueSend(it) }
                return START_STICKY
            }
            ACTION_VIBRATE -> {
                if (!booted) boot()
                queueVibrate()
                return START_STICKY
            }
            ACTION_SET_RELAY -> {
                intent.getStringExtra(EXTRA_RELAY_MODE)?.let {
                    relayMode = runCatching { RelayControlMode.valueOf(it) }.getOrDefault(relayMode)
                    savePrefs()
                    if (!booted) boot() else restartRelay()
                }
                return START_STICKY
            }
            ACTION_SET_RECORDING -> {
                recordSession = intent.getBooleanExtra(EXTRA_RECORDING, recordSession)
                if (recordSession) {
                    val file = store.beginScanSession()
                    publishState {
                        it.copy(recordSessionActive = true, activeSessionName = file.name)
                    }
                } else {
                    val name = store.endScanSession()
                    publishState {
                        it.copy(recordSessionActive = false, activeSessionName = name ?: "")
                    }
                }
                return START_STICKY
            }
            ACTION_SET_AUTO -> {
                autoEnabled = intent.getBooleanExtra(EXTRA_AUTO, autoEnabled)
                savePrefs()
                publishState { it.copy(autoEnabled = autoEnabled) }
                gattServer?.refreshStatusCharacteristic()
                gattServer?.refreshCatalogBuffer()
                return START_STICKY
            }
            ACTION_CLEAR_LIVE -> {
                ServiceState.clearLive()
                return START_STICKY
            }
            ACTION_SET_SCAN -> {
                if (!booted) boot()
                userWantsScan = intent.getBooleanExtra(EXTRA_SCAN, true)
                savePrefs()
                if (userWantsScan) {
                    resumeScan()
                    ensureLoggingStarted() // always-on capture while scanning
                } else {
                    pauseScan()
                    stopLogging()
                }
                return START_STICKY
            }
            ACTION_REPLAY -> {
                if (!booted) boot()
                val path = intent.getStringExtra(EXTRA_REPLAY_PATH)
                if (path != null) {
                    startReplay(
                        path = path,
                        categories = intent.getStringExtra(EXTRA_REPLAY_CATEGORIES)
                            ?.split(",")?.filter { it.isNotEmpty() }?.toSet() ?: emptySet(),
                        address = intent.getStringExtra(EXTRA_REPLAY_ADDRESS).orEmpty(),
                        bandOnly = intent.getBooleanExtra(EXTRA_REPLAY_BAND_ONLY, false),
                    )
                }
                return START_STICKY
            }
            ACTION_REPLAY_STOP -> {
                replayCancel = true
                return START_STICKY
            }
            ACTION_SET_STARLIGHT_LOOP -> {
                if (!booted) boot()
                if (intent.hasExtra(EXTRA_STARLIGHT_ENABLED)) {
                    starlightLoopEnabled = intent.getBooleanExtra(EXTRA_STARLIGHT_ENABLED, false)
                }
                if (intent.hasExtra(EXTRA_STARLIGHT_PACKET_ID)) {
                    starlightLoopPacketId = intent.getLongExtra(EXTRA_STARLIGHT_PACKET_ID, starlightLoopPacketId)
                }
                if (intent.hasExtra(EXTRA_STARLIGHT_INTERVAL_MS)) {
                    starlightIntervalMs = intent.getLongExtra(EXTRA_STARLIGHT_INTERVAL_MS, starlightIntervalMs)
                        .coerceIn(500L, 60_000L)
                }
                savePrefs()
                if (starlightLoopEnabled) {
                    stopTxLoop()
                    stopRandomShow()
                    startStarlightLoop()
                } else {
                    stopStarlightLoop()
                }
                publishStarlightState()
                return START_STICKY
            }
            ACTION_SET_TX_LOOP -> {
                if (!booted) boot()
                if (intent.hasExtra(EXTRA_TX_LOOP_ENABLED)) {
                    txLoopEnabled = intent.getBooleanExtra(EXTRA_TX_LOOP_ENABLED, false)
                }
                if (intent.hasExtra(EXTRA_TX_LOOP_PACKET_ID)) {
                    txLoopPacketId = intent.getLongExtra(EXTRA_TX_LOOP_PACKET_ID, txLoopPacketId)
                }
                if (intent.hasExtra(EXTRA_TX_LOOP_INTERVAL_MS)) {
                    txLoopIntervalMs = intent.getLongExtra(EXTRA_TX_LOOP_INTERVAL_MS, txLoopIntervalMs)
                        .coerceIn(500L, 60_000L)
                }
                savePrefs()
                if (txLoopEnabled) {
                    stopStarlightLoop()
                    stopRandomShow()
                    startTxLoop()
                } else {
                    stopTxLoop()
                }
                publishTxLoopState()
                return START_STICKY
            }
            ACTION_SET_RANDOM_SHOW -> {
                if (!booted) boot()
                if (intent.hasExtra(EXTRA_RANDOM_SHOW_ENABLED)) {
                    randomShowEnabled = intent.getBooleanExtra(EXTRA_RANDOM_SHOW_ENABLED, false)
                }
                if (intent.hasExtra(EXTRA_RANDOM_SHOW_INTERVAL_MS)) {
                    randomShowIntervalMs = intent.getLongExtra(EXTRA_RANDOM_SHOW_INTERVAL_MS, randomShowIntervalMs)
                        .coerceIn(500L, 60_000L)
                }
                savePrefs()
                if (randomShowEnabled) {
                    stopStarlightLoop()
                    stopTxLoop()
                    startRandomShow()
                } else {
                    stopRandomShow()
                }
                publishRandomShowState()
                return START_STICKY
            }
            ACTION_REFRESH_RELAY_CACHE -> {
                if (!booted) boot()
                gattServer?.refreshStatusCharacteristic()
                gattServer?.refreshCatalogBuffer()
                return START_STICKY
            }
            else -> boot()
        }
        return START_STICKY
    }

    private fun boot() {
        ensureWakeLockHeld()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification("Starting…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification("Starting…"))
        }

        val adapter = getSystemService(BluetoothManager::class.java)?.adapter
        if (adapter == null || !adapter.isEnabled) {
            publishState { it.copy(running = false, status = "Turn on Bluetooth") }
            return
        }

        if (booted) {
            if (userWantsScan && bleScanner?.isScanning != true) resumeScan()
            publishState {
                it.copy(
                    running = true,
                    scanActive = bleScanner?.isScanning == true,
                    status = if (screenOn) "Scanning" else "Scanning (screen off)",
                )
            }
            ensureWakeLockHeld()
            return
        }
        booted = true
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(PREF_SERVICE_STARTED, true)
            .apply()

        bleAdvertiser = BleAdvertiser(
            adapter.bluetoothLeAdvertiser,
            onStatus = { msg -> publishStatus(msg) },
            txPowerLevel = { store.getTxPowerLevel() },
        )
        transmitter = MagicTransmitter(
            bleAdvertiser!!,
            { store.getWakeupPreambleMs() },
            { store.getCommandBurstMs() },
            { store.getStarlightBurstMs() },
            { store.getTxInterleave() },
        )
        bleScanner = BleScanner(
            onDisneyPacket = { hex, rssi, address -> onHeard(hex, rssi, address) },
            onScanFailed = { code -> restartScanDelayed(code) },
        )
        leScanner = adapter.bluetoothLeScanner
        scanCallback = bleScanner!!.buildCallback()
        if (userWantsScan) startScan() else publishState { it.copy(scanActive = false) }
        runCatching { restartRelay() }.onFailure { publishStatus("Relay error: ${it.message ?: "unknown"}") }

        publishState {
            it.copy(
                running = true,
                status = "Scanning",
                scanActive = true,
                relayMode = relayMode,
                autoEnabled = autoEnabled,
                recordSessionActive = recordSession,
                activeSessionName = store.scanSessions.firstOrNull()?.name ?: it.activeSessionName,
                starlightLoopEnabled = starlightLoopEnabled,
                starlightLoopPacketId = starlightLoopPacketId,
                starlightIntervalMs = starlightIntervalMs,
                starlightLoopLabel = starlightLoopLabel(),
                txLoopEnabled = txLoopEnabled,
                txLoopPacketId = txLoopPacketId,
                txLoopIntervalMs = txLoopIntervalMs,
                txLoopLabel = txLoopLabel(),
                randomShowEnabled = randomShowEnabled,
                randomShowIntervalMs = randomShowIntervalMs,
                wakeupPreambleMs = store.getWakeupPreambleMs(),
                commandBurstMs = store.getCommandBurstMs(),
                starlightBurstMs = store.getStarlightBurstMs(),
            )
        }
        if (userWantsScan) ensureLoggingStarted()
        startLocationUpdates()
        if (starlightLoopEnabled) startStarlightLoop()
        if (txLoopEnabled) startTxLoop()
        if (randomShowEnabled) startRandomShow()
    }

    private fun txLoopHex(): String? {
        if (txLoopPacketId < 0) return null
        return store.findTransmitPacket(txLoopPacketId)?.hex?.let { HexUtils.canonicalHex(it) }
    }

    private fun txLoopLabel(): String {
        if (txLoopPacketId < 0) return "none"
        return store.findTransmitPacket(txLoopPacketId)?.label ?: "unknown"
    }

    private fun starlightLoopHex(): String? {
        if (starlightLoopPacketId < 0) return null
        return store.findLearnedStarlight(starlightLoopPacketId)?.hex?.let { HexUtils.canonicalHex(it) }
    }

    private fun starlightLoopLabel(): String {
        if (starlightLoopPacketId < 0) return "none"
        return store.findLearnedStarlight(starlightLoopPacketId)?.label ?: "unknown"
    }

    /** Stamp each captured packet with the latest fix so packets can be mapped. */
    private fun startLocationUpdates() {
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) return
        val lm = locationManager
            ?: (getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.also { locationManager = it }
            ?: return
        runCatching {
            lastLocation = lm.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?: lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
        }
        runCatching { lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 2000L, 0f, locationListener) }
        runCatching { lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 2000L, 0f, locationListener) }
    }

    private fun stopLocationUpdates() {
        runCatching { locationManager?.removeUpdates(locationListener) }
    }

    /** Always-on capture: ensure a log session is open while scanning. */
    private fun ensureLoggingStarted() {
        recordSession = true
        if (!store.sessionActive) {
            val file = store.beginScanSession()
            publishState { it.copy(recordSessionActive = true, activeSessionName = file.name) }
        } else {
            publishState { it.copy(recordSessionActive = true) }
        }
    }

    private fun stopLogging() {
        val name = store.endScanSession()
        publishState { it.copy(recordSessionActive = false, activeSessionName = name ?: "") }
    }

    // ---- Replay -------------------------------------------------------------

    private fun startReplay(path: String, categories: Set<String>, address: String, bandOnly: Boolean) {
        if (replaying) return
        executor.execute {
            val filtered = store.readLog(path)
                .filter { p ->
                    (categories.isEmpty() || p.category in categories) &&
                        (address.isEmpty() || p.sourceAddress.equals(address, ignoreCase = true)) &&
                        (!bandOnly || p.isBand)
                }
                .sortedBy { it.timestampMs }
            if (filtered.isEmpty()) {
                publishStatus("Replay: no matching packets")
                return@execute
            }
            val steps = ArrayList<Pair<String, Long>>(filtered.size)
            for (i in filtered.indices) {
                val hex = HexUtils.canonicalHex(filtered[i].hex)
                if (hex.isEmpty()) continue
                val gap = if (i < filtered.lastIndex) {
                    filtered[i + 1].timestampMs - filtered[i].timestampMs
                } else {
                    REPLAY_TAIL_MS
                }
                steps.add(hex to gap.coerceIn(REPLAY_MIN_STEP_MS, REPLAY_MAX_STEP_MS))
            }
            if (steps.isEmpty()) {
                publishStatus("Replay: nothing to send")
                return@execute
            }
            replaying = true
            replayCancel = false
            mainHandler.post {
                pauseScanNow()
                pauseGattForManufacturerTx()
                publishState {
                    it.copy(
                        replayActive = true,
                        replayTotal = steps.size,
                        replayProgress = 0,
                        replayLabel = path.substringAfterLast('/'),
                        status = "Replaying",
                    )
                }
                runReplayStep(steps, 0)
            }
        }
    }

    private fun runReplayStep(steps: List<Pair<String, Long>>, index: Int) {
        if (replayCancel || index >= steps.size) {
            finishReplay()
            return
        }
        publishState { it.copy(replayProgress = index + 1) }
        val (hex, durationMs) = steps[index]
        val adv = bleAdvertiser
        if (adv == null) {
            finishReplay()
            return
        }
        adv.burst(hex, durationMs.toInt()) {
            runReplayStep(steps, index + 1)
        }
    }

    private fun finishReplay() {
        if (!replaying) return
        replaying = false
        bleAdvertiser?.stopAll()
        resumeGattAfterManufacturerTx()
        publishState { it.copy(replayActive = false, status = if (scanActiveNow()) "Scanning" else "Idle") }
        if (userWantsScan) scheduleResumeScan()
    }

    private fun scanActiveNow(): Boolean = userWantsScan

    private fun pauseGattForManufacturerTx() {
        gattServer?.pauseConnectableAdvertising()
    }

    private fun resumeGattAfterManufacturerTx() {
        gattServer?.resumeConnectableAdvertising()
    }

    private fun enqueueRadioWork(preempt: Boolean = false, work: () -> Unit) {
        mainHandler.post {
            if (preempt) {
                // A new manual command supersedes anything pending/in-flight: drop the queued
                // backlog and signal the running transmission to abort at its next slice.
                txQueue.clear()
                transmitter?.cancel()
            }
            txQueue.addLast(work)
            drainRadioQueue()
        }
    }

    private fun drainRadioQueue() {
        if (txRunning || txQueue.isEmpty()) return
        txRunning = true
        transmitter?.clearCancel()
        txQueue.removeFirst()()
    }

    private fun finishRadioWork() {
        txRunning = false
        drainRadioQueue()
    }

    /** Pause scan (+ GATT relay ADV when active), run one manufacturer burst, then restore. */
    private fun runManufacturerTx(
        status: String,
        onCompleteStatus: String,
        send: (onDone: () -> Unit) -> Unit,
        afterComplete: (() -> Unit)? = null,
        preempt: Boolean = false,
    ) {
        enqueueRadioWork(preempt) {
            pauseScanNow()
            pauseGattForManufacturerTx()
            publishStatus(status)
            // stopScan() is async at the radio level — give it a beat to tear down before we
            // advertise, otherwise the BLE stack drops/delays the advertise while a scan is
            // still active ("doesn't send in time" when scanning).
            mainHandler.postDelayed({
                send {
                    resumeGattAfterManufacturerTx()
                    publishStatus(onCompleteStatus)
                    scheduleResumeScan()
                    afterComplete?.invoke()
                    finishRadioWork()
                }
            }, TransmitTiming.RADIO_SETTLE_MS)
        }
    }

    private fun queueSend(hex: String) {
        val txHex = HexUtils.canonicalHex(hex)
        val starlight = HexUtils.isStarlightPacket(txHex)
        if (starlight) {
            val idx = MagicClassifier.starlightLearnColorIndex(txHex)
                ?: MagicClassifier.starlightColorIndex(txHex)
            publishState { it.copy(wandDisplayColorIndex = idx) }
        }
        val doneStatus = when {
            txLoopEnabled -> "TX loop"
            randomShowEnabled -> "Random show"
            starlight && starlightLoopEnabled -> "Wand loop"
            else -> "Scanning"
        }
        runManufacturerTx(
            status = if (starlight) "Wand TX…" else "TX…",
            onCompleteStatus = doneStatus,
            send = { onDone ->
                if (transmitter != null) transmitter?.send(txHex, onDone) else onDone()
            },
            afterComplete = {
                // The preempt below may have dropped a queued show burst — put the show back
                // on the clock so a manual send never silently kills the loop.
                if (randomShowEnabled) scheduleRandomShowBurst(immediate = false)
            },
            // A tap supersedes whatever is in flight or queued, so it goes out right away.
            preempt = true,
        )
    }

    private fun queueVibrate() {
        runManufacturerTx(
            status = "Vibrate…",
            onCompleteStatus = "Scanning",
            send = { onDone ->
                if (transmitter != null) transmitter?.vibrateBand(onDone) else onDone()
            },
        )
    }

    private fun startStarlightLoop() {
        stopStarlightLoopSchedule()
        starlightLoopEnabled = true
        scheduleStarlightBurst(immediate = true)
    }

    private fun stopStarlightLoop() {
        starlightLoopEnabled = false
        stopStarlightLoopSchedule()
    }

    private fun stopStarlightLoopSchedule() {
        starlightLoopRunnable?.let { mainHandler.removeCallbacks(it) }
        starlightLoopRunnable = null
    }

    private fun scheduleStarlightBurst(immediate: Boolean) {
        stopStarlightLoopSchedule()
        val task = Runnable {
            if (!starlightLoopEnabled || !booted) return@Runnable
            val hex = starlightLoopHex()
            if (hex == null) {
                publishStatus("Wand: pick a learned color")
                stopStarlightLoop()
                publishStarlightState()
                return@Runnable
            }
            runManufacturerTx(
                status = "Wand loop…",
                onCompleteStatus = "Wand loop",
                send = { onDone ->
                    if (transmitter != null) transmitter?.send(hex, onDone) else onDone()
                },
                afterComplete = {
                    publishStarlightState()
                    if (starlightLoopEnabled) {
                        starlightLoopRunnable = Runnable { scheduleStarlightBurst(immediate = true) }
                        mainHandler.postDelayed(starlightLoopRunnable!!, starlightIntervalMs)
                    }
                },
            )
        }
        starlightLoopRunnable = task
        if (immediate) mainHandler.post(task) else mainHandler.postDelayed(task, starlightIntervalMs)
    }

    private fun publishStarlightState() {
        publishState {
            it.copy(
                starlightLoopEnabled = starlightLoopEnabled,
                starlightLoopPacketId = starlightLoopPacketId,
                starlightIntervalMs = starlightIntervalMs,
                starlightLoopLabel = starlightLoopLabel(),
            )
        }
    }

    private fun startTxLoop() {
        stopTxLoopSchedule()
        txLoopEnabled = true
        scheduleTxBurst(immediate = true)
    }

    private fun stopTxLoop() {
        txLoopEnabled = false
        stopTxLoopSchedule()
    }

    private fun stopTxLoopSchedule() {
        txLoopRunnable?.let { mainHandler.removeCallbacks(it) }
        txLoopRunnable = null
    }

    private fun scheduleTxBurst(immediate: Boolean) {
        stopTxLoopSchedule()
        val task = Runnable {
            if (!txLoopEnabled || !booted) return@Runnable
            val hex = txLoopHex()
            if (hex == null) {
                publishStatus("TX loop: pick a library row")
                stopTxLoop()
                publishTxLoopState()
                return@Runnable
            }
            runManufacturerTx(
                status = "TX loop…",
                onCompleteStatus = "TX loop",
                send = { onDone ->
                    if (transmitter != null) transmitter?.send(hex, onDone) else onDone()
                },
                afterComplete = {
                    publishTxLoopState()
                    if (txLoopEnabled) {
                        txLoopRunnable = Runnable { scheduleTxBurst(immediate = true) }
                        mainHandler.postDelayed(txLoopRunnable!!, txLoopIntervalMs)
                    }
                },
            )
        }
        txLoopRunnable = task
        if (immediate) mainHandler.post(task) else mainHandler.postDelayed(task, txLoopIntervalMs)
    }

    private fun publishTxLoopState() {
        publishState {
            it.copy(
                txLoopEnabled = txLoopEnabled,
                txLoopPacketId = txLoopPacketId,
                txLoopIntervalMs = txLoopIntervalMs,
                txLoopLabel = txLoopLabel(),
            )
        }
    }

    private fun startRandomShow() {
        stopRandomShowSchedule()
        randomShowEnabled = true
        scheduleRandomShowBurst(immediate = true)
    }

    private fun stopRandomShow() {
        randomShowEnabled = false
        stopRandomShowSchedule()
    }

    private fun stopRandomShowSchedule() {
        randomShowRunnable?.let { mainHandler.removeCallbacks(it) }
        randomShowRunnable = null
    }

    /** Random light show: a fresh surprise packet every burst, until stopped. */
    private fun scheduleRandomShowBurst(immediate: Boolean) {
        stopRandomShowSchedule()
        val task = Runnable {
            if (!randomShowEnabled || !booted) return@Runnable
            val (label, hex) = LabPacketBuilder.buildRandomShow()
            randomShowLabel = label
            runManufacturerTx(
                status = "$label…",
                onCompleteStatus = "Random show",
                send = { onDone ->
                    if (transmitter != null) transmitter?.send(hex, onDone) else onDone()
                },
                afterComplete = {
                    publishRandomShowState()
                    if (randomShowEnabled) {
                        randomShowRunnable = Runnable { scheduleRandomShowBurst(immediate = true) }
                        mainHandler.postDelayed(randomShowRunnable!!, randomShowIntervalMs)
                    }
                },
            )
        }
        randomShowRunnable = task
        if (immediate) mainHandler.post(task) else mainHandler.postDelayed(task, randomShowIntervalMs)
    }

    private fun publishRandomShowState() {
        publishState {
            it.copy(
                randomShowEnabled = randomShowEnabled,
                randomShowIntervalMs = randomShowIntervalMs,
                randomShowLabel = randomShowLabel,
            )
        }
    }

    private fun publishTimingState() {
        publishState {
            it.copy(
                wakeupPreambleMs = store.getWakeupPreambleMs(),
                commandBurstMs = store.getCommandBurstMs(),
                starlightBurstMs = store.getStarlightBurstMs(),
            )
        }
    }

    private fun onHeard(hex: String, rssi: Int, address: String = "") {
        // Guard the whole pipeline: a throw here would otherwise kill the single executor
        // thread, crashing the app AND silently stopping all further packet reception.
        executor.execute {
            runCatching { handleHeard(hex, rssi, address) }
                .onFailure { CrashLog.record(it, "onHeard") }
        }
    }

    private fun handleHeard(hex: String, rssi: Int, address: String) {
        run {
            val loc = lastLocation
            val event = store.processHeardPacket(
                hex, rssi, recordSession, address,
                lat = loc?.latitude ?: Double.NaN,
                lng = loc?.longitude ?: Double.NaN,
                accuracy = loc?.accuracy ?: -1f,
            )
            val classified = MagicClassifier.classify(HexUtils.canonicalHex(hex))
            val label = event?.packet?.label ?: classified?.label ?: "?"
            val note = event?.reason ?: "Heard"
            val now = System.currentTimeMillis()
            val isBand = store.isBandAddress(address)

            ServiceState.appendLive(hex, label, rssi, note, address, isBand)
            if (now - lastHeardUiAt > 250) {
                lastHeardUiAt = now
                val wandIdx = if (classified?.typeInfo == "starlight") {
                    MagicClassifier.starlightLearnColorIndex(hex)
                        ?: MagicClassifier.starlightColorIndex(HexUtils.canonicalHex(hex))
                } else null
                publishState {
                    it.copy(
                        packetsHeard = it.packetsHeard + 1,
                        lastHeardHex = hex,
                        lastHeardLabel = label,
                        wandDisplayColorIndex = wandIdx ?: it.wandDisplayColorIndex,
                    )
                }
            } else {
                ServiceState.update { it.copy(packetsHeard = it.packetsHeard + 1) }
            }

            if (!autoEnabled || classified == null) return@run
            if (now - lastAutoAt < 800) return@run
            val responseHexes = store.findAutoResponses(classified, hex) ?: return@run
            lastAutoAt = now
            publishState { it.copy(autoResponsesSent = it.autoResponsesSent + 1, status = "Auto→${classified.label} (${responseHexes.size})") }
            mainHandler.post {
                runManufacturerTx(
                    status = "Auto→${classified.label}",
                    onCompleteStatus = "Scanning",
                    send = { onDone ->
                        if (transmitter != null) transmitter?.sendSequence(responseHexes, onDone) else onDone()
                    },
                )
            }
        }
    }

    private fun restartRelay() {
        httpServer?.stop()
        httpServer = null
        gattServer?.stop()
        gattServer = null
        hotspotManager?.stopHotspot()

        val handlers = relayCommandHandlers()
        startGattRelay(handlers)

        when (relayMode) {
            RelayControlMode.STANDALONE, RelayControlMode.BLE_GATT -> publishState {
                it.copy(
                    relayMode = relayMode,
                    relayIp = "",
                    hotspotSsid = "",
                    hotspotPassword = "",
                    status = if (it.scanActive) "Scanning" else it.status,
                )
            }
            RelayControlMode.WIFI_HOTSPOT -> {
                hotspotManager = HotspotManager(this) { publishStatus(it) }
                hotspotManager?.startHotspot { info ->
                    httpServer = RelayHttpServer(
                        RelayProtocol.HTTP_PORT,
                        onCommand = { hex -> queueSend(hex) },
                        onVibrate = { queueVibrate() },
                        statusProvider = { ServiceState.statusJson() },
                        commandHandlers = handlers,
                    ).also { it.start() }
                    publishState {
                        it.copy(
                            relayMode = relayMode,
                            relayIp = info.gatewayIp,
                            httpPort = RelayProtocol.HTTP_PORT,
                            hotspotSsid = info.ssid,
                            hotspotPassword = info.password,
                            status = "WiFi relay ${info.gatewayIp}:${RelayProtocol.HTTP_PORT}",
                            relayLinked = gattServer != null && ServiceState.state.value.relayLinked,
                        )
                    }
                }
            }
        }
    }

    private fun startGattRelay(handlers: RelayCommands.Handlers) {
        val bt = getSystemService(BluetoothManager::class.java) ?: run {
            publishStatus("Bluetooth unavailable")
            return
        }
        runCatching {
            gattServer = RelayGattServer(
                this, bt,
                onTransmit = { hex, _ -> queueSend(hex) },
                onStatus = { msg ->
                    publishStatus(msg)
                    when {
                        msg.contains("linked", ignoreCase = true) -> {
                            publishState { s -> s.copy(relayLinked = true, status = msg) }
                            gattServer?.refreshStatusCharacteristic()
                            gattServer?.refreshCatalogBuffer()
                        }
                        msg.contains("idle", ignoreCase = true) ||
                            msg.contains("disconnected", ignoreCase = true) -> {
                            publishState { s -> s.copy(relayLinked = false, status = msg) }
                            gattServer?.refreshStatusCharacteristic()
                            gattServer?.refreshCatalogBuffer()
                        }
                        msg.contains("listening", ignoreCase = true) ||
                            msg.contains("failed", ignoreCase = true) -> {
                            publishState { s -> s.copy(status = msg) }
                        }
                    }
                },
                commandHandlers = handlers,
            ).also { it.start() }
        }.onFailure { publishStatus("GATT relay failed: ${it.message}") }
    }

    private fun relayCommandHandlers(): RelayCommands.Handlers = RelayCommands.Handlers(
        transmit = { hex -> queueSend(hex) },
        vibrate = { queueVibrate() },
        interrogate = { queueSend(PacketBuilder.WAKEUP_PING) },
        setScan = { enabled ->
            if (enabled) resumeScan() else pauseScan()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        setAuto = { enabled ->
            autoEnabled = enabled
            savePrefs()
            publishState { it.copy(autoEnabled = enabled) }
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        setRecording = { enabled ->
            if (enabled == recordSession) return@Handlers
            recordSession = enabled
            if (enabled) {
                val file = store.beginScanSession()
                publishState { it.copy(recordSessionActive = true, activeSessionName = file.name) }
            } else {
                val name = store.endScanSession()
                publishState { it.copy(recordSessionActive = false, activeSessionName = name ?: "") }
            }
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        clearLive = {
            ServiceState.clearLive()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        setStarlightLoop = { enabled, packetId, intervalMs ->
            if (!booted) boot()
            starlightLoopEnabled = enabled
            packetId?.let { starlightLoopPacketId = it }
            intervalMs?.let { starlightIntervalMs = it.coerceIn(500L, 60_000L) }
            savePrefs()
            if (starlightLoopEnabled) {
                stopTxLoop()
                stopRandomShow()
                startStarlightLoop()
            } else {
                stopStarlightLoop()
            }
            publishStarlightState()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        setTxLoop = { enabled, packetId, intervalMs ->
            if (!booted) boot()
            txLoopEnabled = enabled
            packetId?.let { txLoopPacketId = it }
            intervalMs?.let { txLoopIntervalMs = it.coerceIn(500L, 60_000L) }
            savePrefs()
            if (txLoopEnabled) {
                stopStarlightLoop()
                stopRandomShow()
                startTxLoop()
            } else {
                stopTxLoop()
            }
            publishTxLoopState()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        setWakeupPreamble = { ms ->
            store.saveWakeupPreambleMs(ms)
            publishTimingState()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        setCommandBurst = { ms ->
            store.saveCommandBurstMs(ms)
            publishTimingState()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        setStarlightBurst = { ms ->
            store.saveStarlightBurstMs(ms)
            publishTimingState()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        saveCustomPreset = { label, hex ->
            val err = store.saveCustomPreset(label, hex)
            if (err != null) throw IllegalArgumentException(err)
            ServiceState.bumpStoreRevision()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        removeLive = { dedupeKey ->
            ServiceState.removeLive(dedupeKey)
            gattServer?.refreshStatusCharacteristic()
        },
        removeRawLive = { timestampMs, hex ->
            ServiceState.removeRawLive(timestampMs, hex)
            gattServer?.refreshStatusCharacteristic()
        },
        deleteWandColor = { packetId ->
            store.deleteLearnedColor(packetId)
            if (starlightLoopEnabled && packetId == starlightLoopPacketId) {
                val next = store.learnedStarlightPackets().firstOrNull()
                if (next != null) {
                    starlightLoopPacketId = next.id
                    savePrefs()
                    startStarlightLoop()
                } else {
                    starlightLoopEnabled = false
                    starlightLoopPacketId = -1L
                    savePrefs()
                    stopStarlightLoop()
                }
            }
            publishStarlightState()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        clearWandLibrary = {
            store.clearLearnedStarlight()
            starlightLoopEnabled = false
            starlightLoopPacketId = -1L
            savePrefs()
            stopStarlightLoop()
            publishStarlightState()
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        addAutoRule = { name, triggerId, responseIds, responseHexes ->
            store.addAutoRule(name, triggerId, responseIds, responseHexes)
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        deleteAutoRule = { ruleId ->
            store.deleteAutoRule(ruleId)
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        setAutoRuleEnabled = { ruleId, enabled ->
            store.setAutoRuleEnabled(ruleId, enabled)
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
        catalogJson = {
            RelayCommands.buildCatalog(
                transmitPresets = store.allTransmitPackets(),
                wandColors = store.learnedStarlightPackets(),
                autoRules = store.autoRules,
                wakeupPreambleMs = store.getWakeupPreambleMs(),
                commandBurstMs = store.getCommandBurstMs(),
                starlightBurstMs = store.getStarlightBurstMs(),
            )
        },
        statusJson = { ServiceState.statusJson() },
        liveJson = { ServiceState.liveJson() },
        pairingJson = {
            val s = ServiceState.state.value
            RelayPairingPayload.json(
                ssid = s.hotspotSsid.ifEmpty { HotspotManager.HOTSPOT_SSID },
                password = s.hotspotPassword.ifEmpty { HotspotManager.HOTSPOT_PASSWORD },
                gatewayIp = s.relayIp.ifEmpty { HotspotManager.DEFAULT_GATEWAY },
                httpPort = s.httpPort,
            )
        },
        mbleTap = { token, durationMs ->
            val payload = com.magicmaker.android.core.MbleBeaconBuilder.manufacturerPayload(token)
            bleAdvertiser?.burstManufacturer(
                manufacturerId = com.magicmaker.android.core.MbleBeaconBuilder.MANUFACTURER_ID,
                payload = payload,
                durationMs = durationMs,
            ) {}
            gattServer?.refreshStatusCharacteristic()
            gattServer?.refreshCatalogBuffer()
        },
    )

    private fun restartScanWithScreenMode() {
        mainHandler.post {
            if (!booted || !userWantsScan) return@post
            startScanNow()
        }
    }

    private fun restartScanDelayed(errorCode: Int = 0) {
        val reason = when (errorCode) {
            1 -> "scan failed (already started)"
            2 -> "scan failed (app registration)"
            3 -> "scan failed (internal error)"
            4 -> "scan failed (feature unsupported)"
            5 -> "scan failed (out of hardware resources)"
            6 -> "scan failed (scanning too frequently)"
            else -> "scan restarting"
        }
        publishStatus(reason)
        mainHandler.postDelayed({
            if (leScanner != null && scanCallback != null && userWantsScan) startScanNow()
        }, 800)
    }

    private fun scheduleResumeScan() {
        scanResumeRunnable?.let { mainHandler.removeCallbacks(it) }
        scanResumeRunnable = Runnable { startScanNow() }
        mainHandler.postDelayed(scanResumeRunnable!!, TransmitTiming.SCAN_RESUME_DELAY_MS)
    }

    private fun startScanNow() {
        val s = leScanner ?: return
        val cb = scanCallback ?: return
        val scanner = bleScanner ?: return
        if (!userWantsScan) return
        runCatching {
            runCatching { s.stopScan(cb) }
            scanner.markStopped()
            s.startScan(scanner.scanFilters(screenOn), scanner.scanSettings(screenOn), cb)
            scanner.markStarted()
            publishState {
                it.copy(
                    scanActive = true,
                    status = if (screenOn) "Scanning" else "Scanning (screen off)",
                )
            }
        }.onFailure { e ->
            publishStatus("Scan error: ${e.message ?: "unknown"}")
            restartScanDelayed()
        }
    }

    private fun pauseScanNow() {
        scanResumeRunnable?.let { mainHandler.removeCallbacks(it) }
        val s = leScanner ?: return
        val cb = scanCallback ?: return
        runCatching { s.stopScan(cb) }
        bleScanner?.markStopped()
        publishState { it.copy(scanActive = false) }
    }

    private fun startScan() = mainHandler.post { startScanNow() }

    private fun pauseScanQuiet() {
        val s = leScanner ?: return
        val cb = scanCallback ?: return
        runCatching { s.stopScan(cb) }
        bleScanner?.markStopped()
    }

    private fun pauseScan() = mainHandler.post { pauseScanNow() }

    private fun resumeScan() = scheduleResumeScan()

    private fun shutdown() {
        scanResumeRunnable?.let { mainHandler.removeCallbacks(it) }
        txQueue.clear()
        txRunning = false
        stopStarlightLoop()
        stopTxLoop()
        stopRandomShow()
        pauseScanNow()
        httpServer?.stop()
        gattServer?.stop()
        hotspotManager?.stopHotspot()
        bleAdvertiser?.stopAll()
        stopLocationUpdates()
        releaseWakeLock()
        booted = false
        ServiceState.update { ServiceState.UiState() }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun loadPrefs() {
        val p = getSharedPreferences(PREFS, MODE_PRIVATE)
        relayMode = runCatching {
            RelayControlMode.valueOf(p.getString("relay_mode", RelayControlMode.BLE_GATT.name)!!)
        }.getOrDefault(RelayControlMode.BLE_GATT)
        autoEnabled = p.getBoolean("auto_enabled", true)
        recordSession = p.getBoolean(PREF_RECORD_SESSION, true)
        userWantsScan = p.getBoolean(PREF_SCAN_ACTIVE, true)
        starlightLoopEnabled = p.getBoolean("starlight_loop_enabled", false)
        starlightLoopPacketId = p.getLong("starlight_loop_packet_id", -1L)
        starlightIntervalMs = p.getLong("starlight_interval_ms", 3000L).coerceIn(500L, 60_000L)
        txLoopEnabled = p.getBoolean("tx_loop_enabled", false)
        txLoopPacketId = p.getLong("tx_loop_packet_id", -1L)
        txLoopIntervalMs = p.getLong("tx_loop_interval_ms", 3000L).coerceIn(500L, 60_000L)
        randomShowEnabled = p.getBoolean("random_show_enabled", false)
        randomShowIntervalMs = p.getLong("random_show_interval_ms", 3000L).coerceIn(500L, 60_000L)
    }

    private fun savePrefs() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString("relay_mode", relayMode.name)
            .putBoolean("auto_enabled", autoEnabled)
            .putBoolean(PREF_RECORD_SESSION, recordSession)
            .putBoolean(PREF_SCAN_ACTIVE, userWantsScan)
            .putBoolean("starlight_loop_enabled", starlightLoopEnabled)
            .putLong("starlight_loop_packet_id", starlightLoopPacketId)
            .putLong("starlight_interval_ms", starlightIntervalMs)
            .putBoolean("tx_loop_enabled", txLoopEnabled)
            .putLong("tx_loop_packet_id", txLoopPacketId)
            .putLong("tx_loop_interval_ms", txLoopIntervalMs)
            .putBoolean("random_show_enabled", randomShowEnabled)
            .putLong("random_show_interval_ms", randomShowIntervalMs)
            .apply()
    }

    private fun publishStatus(msg: String) = publishState { it.copy(status = msg) }

    private fun publishState(transform: (ServiceState.UiState) -> ServiceState.UiState) {
        ServiceState.update(transform)
        gattServer?.refreshStatusCharacteristic()
        gattServer?.refreshCatalogBuffer()
        val now = System.currentTimeMillis()
        if (now - lastNotifyAt < 800) return
        lastNotifyAt = now
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification(ServiceState.state.value.status))
    }

    private fun acquireWakeLock() {
        ensureWakeLockHeld()
    }

    private fun ensureWakeLockHeld() {
        val pm = getSystemService(PowerManager::class.java) ?: return
        if (wakeLock?.isHeld != true) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MagicMaker::Ble").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        // Keep WiFi awake too so the iPhone relay (HTTP :8765 / hotspot) stays reachable
        // with the screen off — WiFi otherwise powers down and drops the relay.
        ensureWifiLockHeld()
    }

    private fun ensureWifiLockHeld() {
        if (wifiLock?.isHeld == true) return
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? android.net.wifi.WifiManager ?: return
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = wm.createWifiLock(mode, "MagicMaker::Relay").apply {
            setReferenceCounted(false)
            runCatching { acquire() }
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun registerSystemEventsReceiver() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(systemEventsReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(systemEventsReceiver, filter)
        }
    }

    private fun unregisterSystemEventsReceiver() {
        runCatching { unregisterReceiver(systemEventsReceiver) }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, getString(R.string.notification_channel_name), NotificationManager.IMPORTANCE_LOW),
            )
        }
    }

    private fun notification(text: String): Notification {
        val s = ServiceState.state.value
        val detail = buildString {
            append(text)
            if (s.scanActive) append(" · scan")
            if (s.autoEnabled) append(" · auto")
            if (s.recordSessionActive) append(" · rec")
            if (s.starlightLoopEnabled) append(" · wand ${s.starlightLoopLabel}")
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(detail)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setContentIntent(
                PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE),
            )
            .build()
    }

    override fun onDestroy() {
        unregisterSystemEventsReceiver()
        shutdown()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (prefs.getBoolean(PREF_SERVICE_STARTED, false)) {
            start(applicationContext)
        }
    }
}
