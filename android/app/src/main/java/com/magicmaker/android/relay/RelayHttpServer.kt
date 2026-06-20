package com.magicmaker.android.relay

import com.magicmaker.android.core.PacketBuilder
import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject

/**
 * HTTP relay for iPhone remote control.
 * Compatible with esp32_magicband POST /command and JSON /transmit /control.
 */
class RelayHttpServer(
    port: Int,
    private val onCommand: (hex: String) -> Unit,
    private val onVibrate: () -> Unit,
    private val statusProvider: () -> JSONObject,
    private val commandHandlers: RelayCommands.Handlers,
) : NanoHTTPD(port) {

    override fun serve(session: IHTTPSession): Response {
        val uri = session.uri ?: "/"
        return when {
            uri == "/health" && session.method == Method.GET ->
                json(Response.Status.OK, JSONObject().put("ok", true))
            uri == "/status" && session.method == Method.GET ->
                json(Response.Status.OK, statusProvider())
            uri == "/live" && session.method == Method.GET ->
                json(Response.Status.OK, commandHandlers.liveJson().put("ok", true))
            uri == "/catalog" && session.method == Method.GET ->
                json(Response.Status.OK, commandHandlers.catalogJson().put("ok", true))
            uri == "/vibrate" && session.method == Method.POST -> {
                onVibrate()
                json(Response.Status.OK, JSONObject().put("ok", true))
            }
            uri == "/command" && session.method == Method.POST ->
                handleCommand(session)
            uri == "/control" && session.method == Method.POST ->
                handleControl(session)
            uri == "/transmit" && session.method == Method.POST ->
                handleTransmit(session)
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND, MIME_PLAINTEXT, "Not found")
        }
    }

    private fun handleControl(session: IHTTPSession): Response {
        return try {
            val body = readBody(session)
            val json = RelayCommands.parseBody(body) ?: error("Expected JSON body")
            val result = RelayCommands.execute(json, commandHandlers)
            val status = if (result.optBoolean("ok", false)) Response.Status.OK else Response.Status.BAD_REQUEST
            json(status, result)
        } catch (e: Exception) {
            json(Response.Status.BAD_REQUEST, JSONObject().put("ok", false).put("error", e.message))
        }
    }

    private fun handleCommand(session: IHTTPSession): Response {
        return try {
            val params = readForm(session)
            val action = params["action"] ?: error("Missing action")
            if (action.equals("vibrate", ignoreCase = true)) {
                onVibrate()
                return json(Response.Status.OK, JSONObject().put("ok", true))
            }
            val hex = PacketBuilder.fromCommand(action, params) ?: error("Unknown action: $action")
            onCommand(hex)
            json(Response.Status.OK, JSONObject().put("ok", true).put("hex", hex))
        } catch (e: Exception) {
            json(Response.Status.BAD_REQUEST, JSONObject().put("ok", false).put("error", e.message))
        }
    }

    private fun handleTransmit(session: IHTTPSession): Response {
        return try {
            val body = readBody(session)
            if (body.trim().startsWith("{")) {
                val json = JSONObject(body)
                val hex = json.getString("hex")
                onCommand(hex)
                return json(Response.Status.OK, JSONObject().put("ok", true).put("hex", hex))
            }
            val parsed = RelayProtocol.parseTransmitPayload(body.trim())
            if (parsed != null) {
                onCommand(parsed.first)
                return json(Response.Status.OK, JSONObject().put("ok", true).put("hex", parsed.first))
            }
            error("Invalid transmit body")
        } catch (e: Exception) {
            json(Response.Status.BAD_REQUEST, JSONObject().put("ok", false).put("error", e.message))
        }
    }

    private fun readForm(session: IHTTPSession): Map<String, String> {
        val files = HashMap<String, String>()
        session.parseBody(files)
        val raw = files["postData"] ?: ""
        if (raw.isBlank()) return emptyMap()
        return raw.split("&").mapNotNull { part ->
            val kv = part.split("=", limit = 2)
            if (kv.isEmpty()) null else kv[0] to (if (kv.size > 1) java.net.URLDecoder.decode(kv[1], "UTF-8") else "")
        }.toMap()
    }

    private fun readBody(session: IHTTPSession): String {
        val files = HashMap<String, String>()
        session.parseBody(files)
        return files["postData"] ?: ""
    }

    private fun json(status: Response.Status, obj: JSONObject) =
        newFixedLengthResponse(status, "application/json", obj.toString())
}
