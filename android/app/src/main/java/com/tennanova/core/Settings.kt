package com.tennanova.core

import android.content.Context
import java.util.UUID

/** Persisted pairing state and user preferences. */
class Settings(context: Context) {

    private val prefs = context.getSharedPreferences("tennanova", Context.MODE_PRIVATE)

    /** Stable identifier for this phone, generated once. */
    val deviceId: String
        get() = prefs.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString(KEY_DEVICE_ID, it).apply()
        }

    /**
     * Every address the Mac has told us about, best-known first.
     *
     * A list rather than one address because the Mac moves: LAN today, the far side of a
     * phone hotspot tomorrow, and it can hold several addresses at once. The phone walks
     * this list on every connect, so a stale entry costs one short connect timeout.
     */
    var hosts: List<String>
        get() {
            prefs.getString(KEY_HOSTS, null)?.let { stored ->
                return stored.split(SEPARATOR).filter { it.isNotBlank() }
            }
            // Upgrade path: builds before multi-address pairing stored a single host.
            // Losing it here would silently unpair a working phone.
            return listOfNotNull(prefs.getString(KEY_HOST, null)?.takeIf { it.isNotBlank() })
        }
        private set(v) {
            prefs.edit().putString(KEY_HOSTS, v.joinToString(SEPARATOR)).apply()
        }

    /** The address tried first. The dashboard shows this one. */
    val host: String? get() = hosts.firstOrNull()

    /**
     * The Mac's own account of where it can be reached, from `hello.ack` or `mac.hosts`.
     * It is complete, so it replaces what we had — that is what stops dead addresses
     * accumulating — but whatever we are connected on right now stays in front.
     */
    fun replaceHosts(reported: List<String>) {
        val clean = sanitize(reported)
        if (clean.isEmpty()) return
        val leader = hosts.firstOrNull()
        val merged = if (leader != null && leader in clean) {
            listOf(leader) + clean.filterNot { it == leader }
        } else {
            clean
        }
        if (merged != hosts) hosts = merged.take(MAX_HOSTS)
    }

    /**
     * Addresses found by mDNS or by probing the subnet — a hint, not the whole truth, so
     * these are merged rather than substituted.
     *
     * They go to the *front*: something just answered there, while everything already in
     * the list has just failed. Appending would also let a full list discard the one
     * address that works, which is precisely the hotspot case this exists for.
     */
    fun rememberHosts(found: List<String>) {
        val clean = sanitize(found)
        if (clean.isEmpty()) return
        val merged = (clean + hosts).distinct().take(MAX_HOSTS)
        if (merged != hosts) hosts = merged
    }

    /** Moves the address that just worked to the front, so the next connect starts there. */
    fun promoteHost(host: String) {
        val clean = sanitize(listOf(host)).firstOrNull() ?: return
        if (clean == hosts.firstOrNull()) return
        hosts = (listOf(clean) + hosts.filterNot { it == clean }).take(MAX_HOSTS)
    }

    /** Loopback belongs to `usbPort`, not here, or the USB tunnel gets tried twice. */
    private fun sanitize(values: List<String>): List<String> = values
        .map { it.trim() }
        .filter { it.isNotEmpty() && SEPARATOR !in it && !isLoopback(it) }
        .distinct()

    var port: Int
        get() = prefs.getInt(KEY_PORT, Proto.DEFAULT_PORT)
        set(v) = prefs.edit().putInt(KEY_PORT, v).apply()

    /** Optional localhost port reached through a Mac-managed `adb reverse` tunnel. */
    var usbPort: Int?
        get() = if (prefs.contains(KEY_USB_PORT)) prefs.getInt(KEY_USB_PORT, 0) else null
        set(v) {
            prefs.edit().apply {
                if (v == null) remove(KEY_USB_PORT) else putInt(KEY_USB_PORT, v)
            }.apply()
        }

    /** Base64 SHA-256 of the Mac's public key. The trust anchor for the whole system. */
    var spki: String?
        get() = prefs.getString(KEY_SPKI, null)
        set(v) = prefs.edit().putString(KEY_SPKI, v).apply()

    /** One-time token from the QR, cleared once the Mac issues a long-lived one. */
    var pairingToken: String?
        get() = prefs.getString(KEY_PAIRING_TOKEN, null)
        set(v) = prefs.edit().putString(KEY_PAIRING_TOKEN, v).apply()

    var deviceToken: String?
        get() = prefs.getString(KEY_DEVICE_TOKEN, null)
        set(v) = prefs.edit().putString(KEY_DEVICE_TOKEN, v).apply()

    /** Packages the user has muted. */
    var mutedPackages: Set<String>
        get() = prefs.getStringSet(KEY_MUTED, emptySet()) ?: emptySet()
        set(v) = prefs.edit().putStringSet(KEY_MUTED, v).apply()

    val isPaired: Boolean get() = spki != null && hosts.isNotEmpty()

    fun savePairing(p: PairingPayload) {
        prefs.edit()
            .putString(KEY_HOSTS, sanitize(p.hosts).joinToString(SEPARATOR))
            .remove(KEY_HOST)
            .putInt(KEY_PORT, p.port)
            .putString(KEY_SPKI, p.spki)
            .putString(KEY_PAIRING_TOKEN, p.token)
            .apply { if (p.usbPort == null) remove(KEY_USB_PORT) else putInt(KEY_USB_PORT, p.usbPort) }
            .remove(KEY_DEVICE_TOKEN)
            .apply()
    }

    fun clearPairing() {
        prefs.edit()
            .remove(KEY_HOST).remove(KEY_HOSTS).remove(KEY_PORT).remove(KEY_SPKI)
            .remove(KEY_USB_PORT)
            .remove(KEY_PAIRING_TOKEN).remove(KEY_DEVICE_TOKEN)
            .apply()
    }

    private companion object {
        /** Newline: an ordered list is needed, and a StringSet does not keep order. */
        const val SEPARATOR = "\n"
        const val MAX_HOSTS = 8

        fun isLoopback(host: String): Boolean =
            host.equals("localhost", ignoreCase = true) || host == "127.0.0.1" ||
                host == "::1" || host == "[::1]"

        const val KEY_DEVICE_ID = "deviceId"
        const val KEY_HOST = "host"
        const val KEY_HOSTS = "hosts"
        const val KEY_PORT = "port"
        const val KEY_USB_PORT = "usbPort"
        const val KEY_SPKI = "spki"
        const val KEY_PAIRING_TOKEN = "pairingToken"
        const val KEY_DEVICE_TOKEN = "deviceToken"
        const val KEY_MUTED = "mutedPackages"
    }
}
