package com.magicmaker.android.relay

import org.json.JSONArray
import org.json.JSONObject

/**
 * Chunked catalog transfer for BLE GATT STATUS (512-byte ATT limit).
 * iPhone requests catalog_sync_begin, then catalog_sync_chunk per section/index.
 * Each chunk response is kept under [MAX_RESPONSE_BYTES] so a single STATUS read succeeds.
 */
object CatalogSync {
    const val PROTOCOL_VERSION = 1
    /** Max UTF-8 length of full chunk JSON (wrapper + items). Must stay under ATT 512. */
    const val MAX_RESPONSE_BYTES = 460

    fun buildBegin(catalog: JSONObject, storeRevision: Int): JSONObject =
        JSONObject().apply {
            val tx = catalog.optJSONArray("transmitPresets") ?: JSONArray()
            val wand = catalog.optJSONArray("wandColors") ?: JSONArray()
            val rules = catalog.optJSONArray("autoRules") ?: JSONArray()
            put("ok", true)
            put("protocol", PROTOCOL_VERSION)
            put("storeRevision", storeRevision)
            put("wakeupPreambleMs", catalog.optInt("wakeupPreambleMs", 520))
            put("commandBurstMs", catalog.optInt("commandBurstMs", 2000))
            put("starlightBurstMs", catalog.optInt("starlightBurstMs", com.magicmaker.android.core.TransmitTiming.STARLIGHT_BURST_MS))
            put("txCount", tx.length())
            put("wandCount", wand.length())
            put("ruleCount", rules.length())
            put("txChunks", chunkCount(tx, "tx"))
            put("wandChunks", chunkCount(wand, "wand"))
            put("ruleChunks", chunkCount(rules, "rules"))
        }

    fun buildChunk(catalog: JSONObject, section: String, index: Int): JSONObject {
        val norm = normalizeSection(section)
        val array = sectionArray(catalog, section)
            ?: return JSONObject().put("ok", false).put("error", "Unknown section: $section")
        val chunks = splitChunks(array, norm)
        if (index < 0 || index >= chunks.size) {
            return JSONObject().put("ok", false).put("error", "Bad chunk index $index")
        }
        val items = if (norm == "rules") compactRules(chunks[index]) else compactPresets(chunks[index])
        return JSONObject()
            .put("ok", true)
            .put("protocol", PROTOCOL_VERSION)
            .put("section", norm)
            .put("index", index)
            .put("total", chunks.size)
            .put("items", items)
    }

    private fun sectionArray(catalog: JSONObject, section: String): JSONArray? =
        when (section.lowercase()) {
            "tx", "transmit", "transmitpresets", "presets" -> catalog.optJSONArray("transmitPresets")
            "wand", "wandcolors", "starlight" -> catalog.optJSONArray("wandColors")
            "rules", "autorules", "auto" -> catalog.optJSONArray("autoRules")
            else -> null
        }

    private fun normalizeSection(section: String): String =
        when (section.lowercase()) {
            "tx", "transmit", "transmitpresets", "presets" -> "tx"
            "wand", "wandcolors", "starlight" -> "wand"
            else -> "rules"
        }

    private fun chunkCount(arr: JSONArray, section: String): Int = splitChunks(arr, normalizeSection(section)).size

    /** Compact preset rows — omits optional fields to keep each chunk under ATT limit. */
    private fun compactPresets(arr: JSONArray): JSONArray {
        val out = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            out.put(
                JSONObject()
                    .put("id", o.optLong("id", 0))
                    .put("hex", o.getString("hex"))
                    .put("label", o.optString("label", "?"))
                    .put("category", o.optString("category", "UNKNOWN"))
                    .put("typeInfo", o.optString("typeInfo", "raw"))
                    .put("simKey", o.optString("simKey", "")),
            )
        }
        return out
    }

    private fun compactRules(arr: JSONArray): JSONArray {
        val out = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            out.put(
                JSONObject()
                    .put("id", o.optLong("id", 0))
                    .put("name", o.optString("name", "Rule"))
                    .put("triggerPatternId", o.optString("triggerPatternId", ""))
                    .put("responsePatternId", o.optString("responsePatternId", ""))
                    .put("enabled", o.optBoolean("enabled", true))
                    .put("responseHexes", o.optJSONArray("responseHexes") ?: JSONArray()),
            )
        }
        return out
    }

    private fun splitChunks(arr: JSONArray, section: String): List<JSONArray> {
        if (arr.length() == 0) return listOf(JSONArray())
        val chunks = mutableListOf<JSONArray>()
        var current = JSONArray()
        for (i in 0 until arr.length()) {
            val item = arr.get(i)
            val trial = JSONArray()
            for (j in 0 until current.length()) trial.put(current.get(j))
            trial.put(item)
            if (current.length() > 0 && chunkResponseSize(trial, section) > MAX_RESPONSE_BYTES) {
                chunks.add(current)
                current = JSONArray().put(item)
            } else {
                current = trial
            }
        }
        chunks.add(current)
        return chunks
    }

    private fun chunkResponseSize(items: JSONArray, section: String): Int {
        val compact = if (section == "rules") compactRules(items) else compactPresets(items)
        return JSONObject()
            .put("ok", true)
            .put("protocol", PROTOCOL_VERSION)
            .put("section", section)
            .put("index", 0)
            .put("total", 1)
            .put("items", compact)
            .toString().length
    }
}
