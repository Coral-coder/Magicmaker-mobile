package com.magicmaker.android.core

object HexUtils {
    const val DISNEY_COMPANY_ID = 0x0183
    const val MAX_MFG_PAYLOAD_BYTES = 27
    const val MAGIC_MAKER_LOCAL_NAME_PREFIX = "MM:"

    fun bytesToHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02X".format(it) }

    fun hexToBytes(hex: String): ByteArray {
        val clean = hex.uppercase().filter { it in "0123456789ABCDEF" }
        require(clean.length % 2 == 0) { "Invalid hex length" }
        return ByteArray(clean.length / 2) { i ->
            clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    fun canonicalHex(hex: String): String {
        val clean = hex.uppercase().filter { it in "0123456789ABCDEF" }
        if (clean.startsWith("8301")) return clean
        if (clean.startsWith("CF9B") || clean.startsWith("CF0B")) return "8301$clean"
        if (clean.isNotEmpty()) return "8301$clean"
        return clean
    }

    fun isStarlightPacket(hex: String): Boolean {
        val h = canonicalHex(hex)
        return h.contains("CF9B") || h.contains("CF0B")
    }

    fun isDisneyBlePacket(hex: String): Boolean {
        val clean = canonicalHex(hex)
        return clean.length >= 4 && clean.length % 2 == 0
    }

    fun isDisneyManufacturerData(data: ByteArray): Boolean {
        if (data.size < 2) return false
        val companyId = (data[0].toInt() and 0xFF) or ((data[1].toInt() and 0xFF) shl 8)
        return companyId == DISNEY_COMPANY_ID
    }

    fun iosMfgPayload(hex: String): ByteArray {
        val bytes = hexToBytes(canonicalHex(hex))
        return if (bytes.size >= 2 && bytes[0] == 0x83.toByte() && bytes[1] == 0x01.toByte()) {
            bytes.copyOfRange(2, bytes.size)
        } else {
            bytes
        }
    }

    fun canonicalFromMfgData(data: ByteArray): String {
        if (data.size >= 2 && data[0] == 0x83.toByte() && data[1] == 0x01.toByte()) {
            return bytesToHex(data)
        }
        return "8301${bytesToHex(data)}"
    }

    /** Manufacturer payload for Android AdvertiseData.addManufacturerData(0x0183, …) — without company ID bytes. */
    fun disneyAdvertisePayload(hex: String): ByteArray = iosMfgPayload(hex)

    fun legacyAdvertiseRejectReason(hex: String): String? {
        val payload = iosMfgPayload(hex)
        if (payload.isEmpty()) return "Empty packet"
        if (payload.size > MAX_MFG_PAYLOAD_BYTES) {
            return "Packet too long for BLE ADV (${payload.size} bytes, max $MAX_MFG_PAYLOAD_BYTES)"
        }
        val adLen = 1 + 2 + payload.size
        if (adLen + 1 > 31) return "Packet too long for BLE ADV"
        return null
    }

    fun hexFromMagicMakerLocalName(name: String): String? {
        if (!name.startsWith(MAGIC_MAKER_LOCAL_NAME_PREFIX)) return null
        val hex = name.removePrefix(MAGIC_MAKER_LOCAL_NAME_PREFIX)
        if (!isDisneyBlePacket(hex)) return null
        return canonicalHex(hex)
    }

    /** Starlight / Disney packets embedded in a BLE service UUID (iOS path). */
    fun hexFromAdvertisementUuid(uuid: java.util.UUID): String? {
        val bytes = uuidToBytes(uuid)
        if (bytes.size >= 3 && bytes[0] == 0x83.toByte() && bytes[1] == 0x01.toByte()) {
            val length = bytes[2].toInt() and 0xFF
            if (length > 0 && length <= MAX_MFG_PAYLOAD_BYTES + 2 && 3 + length <= bytes.size) {
                return bytesToHex(bytes.copyOfRange(0, 3 + length))
            }
        }
        scanForDisneyMarker(bytes)?.let { return it }
        return null
    }

    fun hexFromServiceData(data: ByteArray): String? {
        if (data.size >= 2 && data[0] == 0x83.toByte() && data[1] == 0x01.toByte()) {
            return bytesToHex(data)
        }
        return scanForDisneyMarker(data)
    }

    /** True when a starlight ADV includes the serial + color byte (not a truncated UUID slice). */
    fun hasCompleteStarlightPayload(hex: String): Boolean {
        val h = canonicalHex(hex)
        if (!isStarlightPacket(h)) return false
        val markerPos = h.indexOf("CF9B").takeIf { it >= 0 } ?: h.indexOf("CF0B").takeIf { it >= 0 } ?: return false
        var pos = markerPos + 4
        if (pos + 2 <= h.length && h.substring(pos, pos + 2) == "00") pos += 2
        return pos + StarlightSerial.SERIAL_HEX_LEN + 2 <= h.length
    }

    fun disneyHexScore(hex: String): Int {
        val h = canonicalHex(hex)
        var score = h.length
        if (isStarlightPacket(h)) score += 200
        if (hasCompleteStarlightPayload(h)) score += 150
        if (StarlightSerial.extractSerial(h) != null) score += 50
        return score
    }

    fun pickBestDisneyHex(candidates: Collection<String>): String? =
        candidates
            .map { canonicalHex(it) }
            .filter { isDisneyBlePacket(it) }
            .distinct()
            .maxByOrNull { disneyHexScore(it) }

    /** Collect every Disney payload from a scan record (manufacturer, service UUID, service data, raw AD). */
    fun collectDisneyHexCandidates(record: android.bluetooth.le.ScanRecord): List<String> {
        val out = mutableListOf<String>()

        val mfgMap = record.manufacturerSpecificData
        for (i in 0 until mfgMap.size()) {
            val companyId = mfgMap.keyAt(i)
            val payload = mfgMap.valueAt(i) ?: continue
            if (payload.isEmpty()) continue
            if (companyId == DISNEY_COMPANY_ID) {
                val hex = canonicalFromMfgData(payload)
                if (isDisneyBlePacket(hex)) out.add(hex)
            }
            hexFromServiceData(payload)?.let { out.add(it) }
        }

        record.getManufacturerSpecificData(DISNEY_COMPANY_ID)?.let { legacy ->
            if (legacy.isNotEmpty()) {
                val hex = canonicalFromMfgData(legacy)
                if (isDisneyBlePacket(hex)) out.add(hex)
            }
        }

        record.serviceUuids?.forEach { parcelUuid ->
            hexFromAdvertisementUuid(parcelUuid.uuid)?.let { out.add(it) }
        }
        record.serviceData?.forEach { (_, data) ->
            hexFromServiceData(data)?.let { out.add(it) }
        }

        record.bytes?.let { ad ->
            extractDisneyPayload(ad)?.let { out.add(it) }
        }
        return out
    }

    private fun scanForDisneyMarker(bytes: ByteArray): String? {
        if (bytes.size < 4) return null
        val hex = bytesToHex(bytes)
        val idx = listOf(hex.indexOf("CF9B"), hex.indexOf("CF0B")).filter { it >= 0 }.minOrNull() ?: return null
        val slice = hex.substring(idx)
        return canonicalHex(slice)
    }

    private fun uuidToBytes(uuid: java.util.UUID): ByteArray {
        val msb = uuid.mostSignificantBits
        val lsb = uuid.leastSignificantBits
        return ByteArray(16) { i ->
            val shift = if (i < 8) 8 * (7 - i) else 8 * (7 - (i - 8))
            val v = if (i < 8) msb shr shift else lsb shr shift
            v.toByte()
        }
    }

    fun extractDisneyPayload(ad: ByteArray): String? {
        var i = 0
        while (i < ad.size) {
            val len = ad[i].toInt() and 0xFF
            if (len == 0) break
            val typeIndex = i + 1
            if (typeIndex >= ad.size) break
            val type = ad[typeIndex]
            val dataStart = typeIndex + 1
            val dataEnd = i + 1 + len
            if (dataEnd > ad.size) break
            if (type == 0xFF.toByte() && dataEnd - dataStart >= 2) {
                val companyId = (ad[dataStart].toInt() and 0xFF) or ((ad[dataStart + 1].toInt() and 0xFF) shl 8)
                if (companyId == DISNEY_COMPANY_ID) {
                    return bytesToHex(ad.copyOfRange(dataStart, dataEnd))
                }
                scanForDisneyMarker(ad.copyOfRange(dataStart, dataEnd))?.let { return it }
            }
            i += len + 1
        }
        return null
    }
}
