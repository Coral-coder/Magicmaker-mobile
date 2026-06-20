package com.magicmaker.android.relay

import org.json.JSONObject

/** Pairing payloads for iPhone remote — QR on Relay tab + GATT/HTTP status. */
object RelayPairingPayload {
    fun wifiQrString(ssid: String, password: String): String {
        val s = escapeWifiField(ssid)
        val p = escapeWifiField(password)
        return "WIFI:T:WPA;S:$s;P:$p;;"
    }

    fun json(ssid: String, password: String, gatewayIp: String, httpPort: Int): JSONObject =
        JSONObject()
            .put("magicmaker", true)
            .put("ssid", ssid)
            .put("password", password)
            .put("ip", gatewayIp)
            .put("port", httpPort)
            .put("wifiQr", wifiQrString(ssid, password))

    private fun escapeWifiField(value: String): String =
        value.replace("\\", "\\\\").replace(";", "\\;").replace(":", "\\:").replace(",", "\\,")
}
