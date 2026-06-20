package com.magicmaker.android.relay

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper

class HotspotManager(
    private val context: Context,
    private val onStatus: (String) -> Unit,
) {
    data class HotspotInfo(val ssid: String, val password: String, val gatewayIp: String)

    private enum class ActiveMode { NONE, NAMED, LOCAL_ONLY }

    private var localOnlyReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var activeMode = ActiveMode.NONE
    private val mainHandler = Handler(Looper.getMainLooper())

    @SuppressLint("MissingPermission")
    fun startHotspot(onReady: (HotspotInfo) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            onStatus("Hotspot requires Android 8+")
            return
        }
        stopHotspot()
        if (tryStartNamedHotspot(onReady)) return
        startLocalOnlyHotspot(onReady)
    }

    @SuppressLint("MissingPermission")
    private fun tryStartNamedHotspot(onReady: (HotspotInfo) -> Unit): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java) ?: return false
        return try {
            val config = buildSoftApConfiguration(HOTSPOT_SSID, HOTSPOT_PASSWORD) ?: return false
            val started = invokeBoolean(wifi, "startTetheredHotspot", config)
                || invokeSetConfigAndStart(wifi, config)
            if (!started) return false
            activeMode = ActiveMode.NAMED
            onStatus("Hotspot: $HOTSPOT_SSID")
            mainHandler.postDelayed({
                onReady(HotspotInfo(HOTSPOT_SSID, HOTSPOT_PASSWORD, guessGatewayIp()))
            }, 1200)
            true
        } catch (e: SecurityException) {
            onStatus("Hotspot blocked — trying fallback")
            false
        } catch (e: Exception) {
            onStatus("Named hotspot failed — trying fallback")
            false
        }
    }

    private fun buildSoftApConfiguration(ssid: String, password: String): Any? {
        return try {
            val builderClass = Class.forName("android.net.wifi.SoftApConfiguration\$Builder")
            val builder = builderClass.getConstructor().newInstance()
            builderClass.getMethod("setSsid", String::class.java).invoke(builder, ssid)
            builderClass.getMethod(
                "setPassphrase",
                String::class.java,
                Int::class.javaPrimitiveType,
            ).invoke(builder, password, 1) // SECURITY_TYPE_WPA2_PSK
            builderClass.getMethod("build").invoke(builder)
        } catch (_: Exception) {
            null
        }
    }

    private fun invokeSetConfigAndStart(wifi: WifiManager, config: Any): Boolean {
        if (!invokeBoolean(wifi, "setSoftApConfiguration", config)) return false
        return invokeBoolean(wifi, "startSoftAp") || invokeBoolean(wifi, "startTetheredHotspot", config)
    }

    private fun invokeBoolean(wifi: WifiManager, method: String, vararg args: Any?): Boolean {
        return try {
            val m = if (args.isEmpty()) {
                wifi.javaClass.getMethod(method)
            } else {
                val types = args.map { it!!.javaClass }.toTypedArray()
                wifi.javaClass.getMethod(method, *types)
            }
            when (val result = m.invoke(wifi, *args)) {
                is Boolean -> result
                else -> result != null
            }
        } catch (_: Exception) {
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun startLocalOnlyHotspot(onReady: (HotspotInfo) -> Unit) {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifi == null) {
            onStatus("WiFi unavailable")
            return
        }
        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        try {
                            activeMode = ActiveMode.LOCAL_ONLY
                            localOnlyReservation = reservation
                            val cfg = reservation.wifiConfiguration
                            val ssid = cfg?.SSID?.trim('"') ?: HOTSPOT_SSID
                            val password = cfg?.preSharedKey ?: ""
                            onStatus("Hotspot active: $ssid")
                            onReady(HotspotInfo(ssid, password, guessGatewayIp()))
                        } catch (_: Exception) {
                            onReady(
                                HotspotInfo(
                                    ssid = reservation.wifiConfiguration?.SSID?.trim('"') ?: HOTSPOT_SSID,
                                    password = reservation.wifiConfiguration?.preSharedKey ?: "",
                                    gatewayIp = DEFAULT_GATEWAY,
                                ),
                            )
                        }
                    }

                    override fun onFailed(reason: Int) {
                        onStatus("Hotspot failed: $reason")
                    }

                    override fun onStopped() {
                        onStatus("Hotspot stopped")
                    }
                },
                mainHandler,
            )
        } catch (e: SecurityException) {
            onStatus("Hotspot permission denied — grant Nearby devices")
        } catch (e: Exception) {
            onStatus("Hotspot error: ${e.message ?: "unknown"}")
        }
    }

    @SuppressLint("MissingPermission")
    fun stopHotspot() {
        mainHandler.removeCallbacksAndMessages(null)
        localOnlyReservation?.close()
        localOnlyReservation = null
        if (activeMode == ActiveMode.NAMED && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.applicationContext.getSystemService(WifiManager::class.java)?.let { wifi ->
                invokeBoolean(wifi, "stopSoftAp")
            }
        }
        activeMode = ActiveMode.NONE
    }

    fun guessGatewayIp(): String {
        return try {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return DEFAULT_GATEWAY
            val link = cm.activeNetwork ?: return DEFAULT_GATEWAY
            val props = cm.getLinkProperties(link) ?: return DEFAULT_GATEWAY
            props.linkAddresses.firstOrNull()?.address?.hostAddress?.let { ip ->
                val parts = ip.split(".")
                if (parts.size == 4) return "${parts[0]}.${parts[1]}.${parts[2]}.1"
            }
            DEFAULT_GATEWAY
        } catch (_: SecurityException) {
            DEFAULT_GATEWAY
        } catch (_: Exception) {
            DEFAULT_GATEWAY
        }
    }

    fun currentHotspotInfo(): HotspotInfo? {
        if (activeMode == ActiveMode.NAMED) {
            return HotspotInfo(HOTSPOT_SSID, HOTSPOT_PASSWORD, guessGatewayIp())
        }
        localOnlyReservation?.wifiConfiguration?.let { cfg ->
            return HotspotInfo(
                ssid = cfg.SSID?.trim('"') ?: HOTSPOT_SSID,
                password = cfg.preSharedKey ?: "",
                gatewayIp = guessGatewayIp(),
            )
        }
        return null
    }

    companion object {
        const val HOTSPOT_SSID = "MagicMaker"
        const val HOTSPOT_PASSWORD = "magic123"
        const val DEFAULT_GATEWAY = "192.168.43.1"
    }
}
