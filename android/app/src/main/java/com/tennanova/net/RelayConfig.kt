package com.tennanova.net

/**
 * Where the Mac can be reached when the local network refuses to carry traffic between
 * its own clients. See `relay/README.md` for why that is a real and common condition.
 *
 * The phone never derives a room id — it is handed one, in the pairing QR or in
 * `hello.ack`. All it has to do is ask for that room by name.
 */
object RelayConfig {

    /**
     * Percent-encodes a query value, `+` included.
     *
     * The relay reads its parameters with `URLSearchParams`, which follows the
     * form-encoding rule that a bare `+` means a space. Room ids are base64url and so
     * never contain one, but encoding here rather than trusting that keeps this honest
     * if the id format ever changes — and it mirrors what the Mac does with its secret,
     * which is plain base64 and does contain `+`.
     */
    fun escape(value: String): String = buildString(value.length) {
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt().toChar()
            if (c.isLetterOrDigit() && c.code < 128 || c in "-._~") {
                append(c)
            } else {
                append('%').append(HEX[(byte.toInt() shr 4) and 0xF]).append(HEX[byte.toInt() and 0xF])
            }
        }
    }

    /** wss on 443: the one outbound port a captive or filtered network still allows. */
    fun joinUrl(host: String, room: String): String? {
        if (!isValidHost(host) || !isValidRoom(room)) return null
        return "wss://$host/v1/join?room=${escape(room)}"
    }

    fun isValidHost(host: String): Boolean =
        host.isNotEmpty() && host.length <= 253 &&
            host.all { it.isLetterOrDigit() || it in ".-" } &&
            !host.startsWith('.') && !host.endsWith('.') && '.' in host

    /** base64url of a SHA-256, so 43 characters from a known alphabet and nothing else. */
    fun isValidRoom(room: String): Boolean =
        room.length in 16..128 && room.all { it.isLetterOrDigit() || it in "-_" }

    private const val HEX = "0123456789ABCDEF"
}
