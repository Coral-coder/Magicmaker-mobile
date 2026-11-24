package com.magicmaker.android.sync

import java.security.MessageDigest
import java.util.zip.CRC32
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Primitives (§2) and the sync-group crypto (§13). JDK only: java.util.zip, java.security, javax.crypto. */
object SyncCrypto {
    /** CRC-32/ISO-HDLC (zlib crc32) as an unsigned value 0..0xFFFFFFFF. */
    fun crc32(data: Bytes): Long {
        val c = CRC32()
        c.update(data.raw())
        return c.value
    }

    /** FNV-1a 64 (the hub's key hash over the encoded key bytes, §3). */
    fun fnv1a64(data: Bytes): Long {
        var h = SyncConst.FNV64_OFFSET
        for (i in 0 until data.size) {
            h = h xor data[i].toLong()
            h *= SyncConst.FNV64_PRIME
        }
        return h
    }

    fun sha256(data: Bytes): Bytes = Bytes.wrap(MessageDigest.getInstance("SHA-256").digest(data.raw()))

    /** HMAC-SHA256 (RFC 2104) through javax.crypto.Mac. */
    fun hmacSha256(key: Bytes, data: Bytes): Bytes {
        if (key.isEmpty()) return hmacSha256Portable(key, data) // SecretKeySpec rejects an empty key
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key.raw(), "HmacSHA256"))
        return Bytes.wrap(mac.doFinal(data.raw()))
    }

    /** RFC 2104 over SHA-256 (only used for an empty key, which javax.crypto cannot express). */
    private fun hmacSha256Portable(key: Bytes, data: Bytes): Bytes {
        val block = ByteArray(64)
        val k = if (key.size > 64) sha256(key).raw() else key.raw()
        System.arraycopy(k, 0, block, 0, k.size)
        val ipad = ByteArray(64) { (block[it].toInt() xor 0x36).toByte() }
        val opad = ByteArray(64) { (block[it].toInt() xor 0x5C).toByte() }
        val inner = sha256(Bytes.wrap(ipad + data.raw()))
        return sha256(Bytes.wrap(opad + inner.raw()))
    }

    /** Constant-time comparison (proofs, §13.2). */
    fun constantTimeEquals(a: Bytes, b: Bytes): Boolean {
        if (a.size != b.size) return false
        var d = 0
        for (i in 0 until a.size) d = d or (a[i] xor b[i])
        return d == 0
    }

    val GROUP_ID_PREFIX: Bytes = Bytes.of(*"MMGROUP1".map { it.code }.toIntArray())
    val PROOF_P_PREFIX: Bytes = Bytes.of(*"MMSYNC1P".map { it.code }.toIntArray())
    val PROOF_C_PREFIX: Bytes = Bytes.of(*"MMSYNC1C".map { it.code }.toIntArray())

    /** groupId = SHA-256("MMGROUP1" ‖ groupKey)[0..7]. */
    fun groupId(groupKey: Bytes): Bytes {
        require(groupKey.size == 16) { "groupKey must be 16 bytes" }
        return sha256(GROUP_ID_PREFIX + groupKey).slice(0, 8)
    }

    /** T = nonceC ‖ nonceP ‖ idC ‖ idP (32 bytes). */
    fun authTranscript(nonceC: Bytes, nonceP: Bytes, idC: Bytes, idP: Bytes): Bytes {
        for (x in arrayOf(nonceC, nonceP, idC, idP)) require(x.size == 8) { "transcript parts are 8 bytes" }
        return nonceC + nonceP + idC + idP
    }

    /** proofP = HMAC-SHA256(groupKey, "MMSYNC1P" ‖ T)[0..15] (peripheral -> central, HELLO 0x0F). */
    fun proofP(groupKey: Bytes, nonceC: Bytes, nonceP: Bytes, idC: Bytes, idP: Bytes): Bytes =
        hmacSha256(groupKey, PROOF_P_PREFIX + authTranscript(nonceC, nonceP, idC, idP)).slice(0, 16)

    /** proofC = HMAC-SHA256(groupKey, "MMSYNC1C" ‖ T)[0..15] (central -> peripheral, AUTH 0x01). */
    fun proofC(groupKey: Bytes, nonceC: Bytes, nonceP: Bytes, idC: Bytes, idP: Bytes): Bytes =
        hmacSha256(groupKey, PROOF_C_PREFIX + authTranscript(nonceC, nonceP, idC, idP)).slice(0, 16)
}

/** A sync group: the 16-byte key and its derived 8-byte id (§13.1). */
data class SyncGroup(val groupId: Bytes, val groupKey: Bytes) {
    init {
        require(groupId.size == 8 && groupKey.size == 16) { "groupId 8 B, groupKey 16 B" }
    }

    /** First two bytes of groupId: Android's service-data tag (§13.1). */
    val advertTag: Bytes get() = groupId.slice(0, 2)

    /** True when [groupId] is SHA-256("MMGROUP1" ‖ [groupKey])[0..7] (JOIN check, §11.2). */
    fun isConsistent(): Boolean = SyncCrypto.groupId(groupKey) == groupId

    override fun toString(): String = "SyncGroup(${groupId.hex()})" // never print the key

    companion object {
        fun fromKey(groupKey: Bytes): SyncGroup = SyncGroup(SyncCrypto.groupId(groupKey), groupKey)
    }
}
