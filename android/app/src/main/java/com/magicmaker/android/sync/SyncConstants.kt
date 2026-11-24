package com.magicmaker.android.sync

/** SYNC v1 constants (docs/SYNC_PROTOCOL.md §18). */
object SyncConst {
    const val PROTO: Int = 1
    const val FRAME_VERSION: Int = 1
    const val FRAME_HEADER_LEN: Int = 2
    const val ATT_OVERHEAD: Int = 3
    const val MTU_MIN: Int = 23
    const val MTU_MAX: Int = 517
    /** MTU below this -> small pull profile (limit 8, maxBytes 512). */
    const val SMALL_MTU_BELOW: Int = 64
    const val MAXMSG_MIN: Int = 512
    const val HUB_MAXMSG: Int = 512
    const val PHONE_MAXMSG: Int = 1024

    const val PACKET_MIN: Int = 3
    const val PACKET_MAX: Int = 29
    const val LABEL_MAX: Int = 64
    const val NOTE_MAX: Int = 160
    const val KIND_MAX: Int = 16
    const val BODY_MAX: Int = 360
    const val SEENBY_MAX: Int = 4
    const val HB_LINKS_MAX: Int = 4
    const val HB_EVTWM_MAX: Int = 4

    const val NS_LIB: Int = 0
    const val NS_NEWWAND: Int = 1

    const val FLAG_DELETED: Int = 0x01
    const val FLAG_USER_EDITED: Int = 0x02
    const val FLAG_PRESET: Int = 0x04
    const val FLAG_MASK: Int = 0x07

    const val CAT_UNKNOWN: Int = 0
    const val CAT_SHOW: Int = 1
    const val CAT_ANIMATION: Int = 2
    const val CAT_COLOR: Int = 3

    const val PLACE_PRESETS: Int = 1
    const val PLACE_COLORS: Int = 2
    const val PLACE_LIBRARY: Int = 3
    const val PLACE_RAW: Int = 4

    const val U_PRESENCE: Long = 1
    const val U_LEGACY_ANDROID: Long = 2
    const val U_LEGACY_IOS: Long = 3
    const val U_MIN_MS: Long = 1_500_000_000_000L
    const val FUTURE_BOUND_MS: Long = 86_400_000L

    const val KIND_HUB: Int = 1
    const val KIND_ANDROID: Int = 2
    const val KIND_IOS: Int = 3

    const val SUB_RECORDS: Int = 0x01
    const val SUB_EVENTS: Int = 0x02
    const val SUB_HEARTBEATS: Int = 0x04

    const val CAP_FEED: Int = 0x0001
    const val CAP_EVENTS: Int = 0x0002
    const val CAP_TRANSMITTER: Int = 0x0008
    const val CAP_PROGRAMS: Int = 0x0010
    const val CAP_LOOPS_BY_HEX: Int = 0x0020

    const val CAPS_HUB: Int = CAP_FEED or CAP_TRANSMITTER or CAP_PROGRAMS or CAP_LOOPS_BY_HEX            // 0x0039
    const val CAPS_ANDROID: Int = CAP_FEED or CAP_EVENTS or CAP_TRANSMITTER or CAP_PROGRAMS or CAP_LOOPS_BY_HEX // 0x003B
    const val CAPS_IOS: Int = CAP_FEED                                                              // 0x0001

    const val PULL_LIMIT_DEFAULT: Int = 24
    const val PULL_MAXBYTES_DEFAULT: Int = 1536
    const val PULL_LIMIT_SMALL: Int = 8
    const val PULL_MAXBYTES_SMALL: Int = 512
    const val PULL_MAXBYTES_MIN: Int = 256

    const val T_HELLO_MS: Long = 5000
    const val HELLO_TRIES: Int = 3
    const val T_RETRY_INCOMPATIBLE_MS: Long = 60000
    const val T_AUTH_MS: Long = 5000
    const val T_DEADLINE_MS: Long = 10000
    const val T_PAGE_MS: Long = 10000
    const val PAGE_TRIES: Int = 3
    const val T_PAGE_FAIL_RETRY_MS: Long = 30000
    const val T_LIVE_PULL_MS: Long = 2000
    const val T_HB_MS: Long = 60000
    const val T_HB_SPACING_MS: Long = 5000
    const val T_PATH_FRESH_MS: Long = 90000
    const val NOT_READY_RETRY_MS: Int = 500
    const val BUSY_RETRY_MS: Int = 1000
    const val DEFAULT_RETRY_MS: Int = 1000

    const val EVT_WINDOW_BITS: Int = 64
    const val EVT_EPOCHS_KEPT: Int = 2
    const val EVT_REPLAY_DEDUPE_MS: Long = 5000
    const val ANDROID_EVT_RING: Int = 2000

    const val TOMBSTONE_CAP_PHONE: Int = 5000

    const val JOIN_FLAG_REKEY: Int = 0x01
    const val EVT_FLAG_TAGGED: Int = 0x01
    const val EVT_FLAG_REPLAY: Int = 0x02
    const val HB_LINK_SYNCED: Int = 0x01
    const val HB_LINK_TX_READY: Int = 0x02
    const val HB_LINK_WIFI: Int = 0x04

    const val FNV64_OFFSET: Long = -0x340d631b7bdddcdbL   // 0xCBF29CE484222325
    const val FNV64_PRIME: Long = 0x00000100000001B3L

    /** caps a v1 node of [kind] advertises in HELLO (§11.1). */
    fun capsByKind(kind: Int): Int = when (kind) {
        KIND_HUB -> CAPS_HUB
        KIND_ANDROID -> CAPS_ANDROID
        KIND_IOS -> CAPS_IOS
        else -> throw IllegalArgumentException("kind $kind")
    }
}

/** Message type codes (§11). */
object MsgType {
    const val HELLO: Int = 0x01
    const val PULL: Int = 0x02
    const val REC: Int = 0x03
    const val PAGE_END: Int = 0x04
    const val EVT: Int = 0x05
    const val EVT_SINCE: Int = 0x06
    const val EVT_GAP: Int = 0x07
    const val HB: Int = 0x08
    const val SUB: Int = 0x09
    const val ERR: Int = 0x0A
    const val AUTH: Int = 0x0B
    const val JOIN: Int = 0x0C

    private val NAMES = arrayOf(
        "", "HELLO", "PULL", "REC", "PAGE_END", "EVT", "EVT_SINCE", "EVT_GAP", "HB", "SUB", "ERR", "AUTH", "JOIN",
    )

    fun isKnown(t: Int): Boolean = t in HELLO..JOIN

    /** "HELLO" ... "JOIN", or "0xNN" for an unknown type. */
    fun name(t: Int): String = if (isKnown(t)) NAMES[t] else "0x%02X".format(t)

    fun code(name: String): Int? = NAMES.indexOf(name).takeIf { it >= 1 }
}

/** ERR codes (§12). */
object ErrCode {
    const val BAD_FRAME: Int = 1
    const val TOO_BIG: Int = 2
    const val BAD_MSG: Int = 3
    const val PROTO: Int = 4
    const val DB_CHANGED: Int = 5
    const val FULL: Int = 6
    const val CLOCK: Int = 7
    const val BUSY: Int = 8
    const val COLLISION: Int = 9
    const val AUTH: Int = 10
    const val NOT_READY: Int = 11

    private val NAMES = arrayOf(
        "", "BAD_FRAME", "TOO_BIG", "BAD_MSG", "PROTO", "DB_CHANGED", "FULL", "CLOCK", "BUSY", "COLLISION", "AUTH",
        "NOT_READY",
    )

    fun name(code: Int): String = if (code in 1 until NAMES.size) NAMES[code] else code.toString()

    fun code(name: String): Int? = NAMES.indexOf(name).takeIf { it >= 1 }
}

/**
 * A decode / validation failure. [code] is an ERR code (BAD_MSG or CLOCK); [reason] is the short
 * tag the vectors use (`truncated`, `order`, `range`, ...; informative, not normative).
 */
class SyncException(val code: Int, val reason: String) : Exception("${ErrCode.name(code)}:$reason")
