package com.tennanova.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/**
 * Wire protocol v1. Mirrors `protocol/PROTOCOL.md` — change both together.
 *
 * Uses org.json rather than a serialization library: the message set is small and
 * fixed, and this keeps the dependency list short.
 */
object Proto {
    const val VERSION = 1
    const val BONJOUR_TYPE = "_tennanova._tcp"
    const val DEFAULT_PORT = 18777
    const val IMAGE_CLIPBOARD_CAPABILITY = "clip.image.v1"
    const val MAX_IMAGE_BYTES = 25 * 1024 * 1024
    val CAPABILITIES = listOf(IMAGE_CLIPBOARD_CAPABILITY)

    fun envelope(type: String): JSONObject =
        JSONObject().put("v", VERSION).put("type", type)
}

/** Payload encoded in the pairing QR shown by the Mac. */
data class PairingPayload(
    val host: String,
    val port: Int,
    val spki: String,
    val token: String,
    val usbPort: Int? = null,
    /**
     * Every address the Mac answers on, `host` first. Additive within v1 — an older Mac
     * sends only `host`, and the list is then just that one entry.
     */
    val hosts: List<String> = listOf(host)
) {
    companion object {
        fun parse(raw: String): PairingPayload? {
            return try {
                val o = JSONObject(raw)
                if (o.getInt("v") != Proto.VERSION) return null
                val host = o.getString("host").trim()
                val port = o.getInt("port")
                val spki = o.getString("spki").trim()
                val token = o.getString("token").trim()
                val usbPort = if (o.has("usbPort")) o.getInt("usbPort") else null
                val hosts = (listOf(host) + hostList(o.optJSONArray("hosts")))
                    .filter { isValidHost(it) }
                    .distinct()
                if (!isValidHost(host) ||
                    port !in 1..65535 ||
                    usbPort != null && usbPort !in 1..65535 ||
                    runCatching { Base64.getDecoder().decode(spki).size }.getOrNull() != 32 ||
                    runCatching { Base64.getDecoder().decode(token).size }.getOrNull() != 32
                ) null else PairingPayload(host, port, spki, token, usbPort, hosts)
            } catch (_: Exception) {
                null
            }
        }

        /** Shared with `hello.ack` and `mac.hosts`, which carry the same shape. */
        fun hostList(array: JSONArray?): List<String> {
            if (array == null) return emptyList()
            return (0 until array.length())
                .mapNotNull { array.optString(it).trim().takeIf(::isValidHost) }
                .distinct()
        }

        private fun isValidHost(host: String): Boolean =
            host.isNotEmpty() && host.length <= 253 &&
                host.all { it.isLetterOrDigit() || it in ".-_:%" }
    }
}

data class NotifAction(val id: Int, val label: String, val isReply: Boolean)

object Messages {

    fun hello(
        deviceId: String,
        deviceName: String,
        model: String,
        sdk: Int,
        battery: Int?,
        pairingToken: String?,
        deviceToken: String?
    ): JSONObject = Proto.envelope("hello").apply {
        pairingToken?.let { put("token", it) }
        deviceToken?.let { put("deviceToken", it) }
        put("device", JSONObject().apply {
            put("id", deviceId)
            put("name", deviceName)
            put("model", model)
            put("androidSdk", sdk)
            battery?.let { put("battery", it) }
        })
        put("capabilities", JSONArray(Proto.CAPABILITIES))
    }

    fun deviceState(battery: Int?, charging: Boolean, dnd: Boolean): JSONObject =
        Proto.envelope("device.state").apply {
            battery?.let { put("battery", it) }
            put("charging", charging)
            put("dnd", dnd)
        }

    fun notifPosted(
        key: String,
        pkg: String,
        appLabel: String,
        iconHash: String?,
        avatarHash: String?,
        title: String?,
        body: String?,
        whenMs: Long,
        category: String?,
        senderName: String?,
        conversationTitle: String?,
        resync: Boolean,
        actions: List<NotifAction>
    ): JSONObject = Proto.envelope("notif.posted").apply {
        put("key", key)
        put("pkg", pkg)
        put("appLabel", appLabel)
        iconHash?.let { put("iconHash", it) }
        avatarHash?.let { put("avatarHash", it) }
        title?.let { put("title", it) }
        body?.let { put("body", it) }
        put("when", whenMs)
        category?.let { put("category", it) }
        senderName?.let { put("senderName", it) }
        conversationTitle?.let { put("conversationTitle", it) }
        if (resync) put("resync", true)
        put("actions", JSONArray().apply {
            actions.forEach {
                put(JSONObject()
                    .put("id", it.id)
                    .put("label", it.label)
                    .put("isReply", it.isReply))
            }
        })
    }

    fun notifRemoved(key: String): JSONObject =
        Proto.envelope("notif.removed").put("key", key)

    fun iconData(hash: String, bytes: Int): JSONObject =
        Proto.envelope("icon.data").put("hash", hash).put("bytes", bytes)

    fun clipUpdate(body: String, seq: Int): JSONObject =
        Proto.envelope("clip.update")
            .put("format", "text")
            .put("body", body)
            .put("origin", "android")
            .put("seq", seq)

    fun clipImage(image: ClipImageHeader): JSONObject =
        Proto.envelope("clip.image")
            .put("origin", image.origin)
            .put("seq", image.seq)
            .put("mime", image.mime)
            .put("bytes", image.bytes)
            .put("sha256", image.sha256)
            .apply { image.name?.let { put("name", it) } }
}

data class ClipImageHeader(
    val origin: String,
    val seq: Int,
    val mime: String,
    val bytes: Int,
    val sha256: String,
    val name: String?
) {
    val isValid: Boolean
        get() = origin in setOf("android", "mac") && seq >= 0 &&
            mime.length in 7..100 && mime.startsWith("image/") &&
            bytes in 1..Proto.MAX_IMAGE_BYTES &&
            sha256.length == 64 && sha256.all { it in '0'..'9' || it in 'a'..'f' }

    companion object {
        fun parse(obj: JSONObject): ClipImageHeader? = runCatching {
            ClipImageHeader(
                origin = obj.getString("origin"),
                seq = obj.getInt("seq"),
                mime = obj.getString("mime"),
                bytes = obj.getInt("bytes"),
                sha256 = obj.getString("sha256").lowercase(),
                name = obj.optString("name").take(120).takeIf { it.isNotBlank() }
            ).takeIf { it.isValid }
        }.getOrNull()
    }
}
