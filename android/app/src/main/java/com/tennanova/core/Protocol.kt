package com.tennanova.core

import com.tennanova.calls.CallAction
import com.tennanova.calls.CallSnapshot
import com.tennanova.net.RelayConfig
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

    /**
     * This build keeps a notification's reply action after the notification is gone, and
     * reports the outcome of every reply as `notif.reply.result`.
     *
     * The Mac needs to be told, because it decides whether to offer a composer for a
     * conversation the phone is no longer showing. Against a phone without this it must
     * keep refusing, or replies would be dropped in silence.
     */
    const val OFFLINE_REPLY_CAPABILITY = "notif.reply.offline.v1"

    /**
     * This phone mirrors the real SMS store: whole threads with history, live arrivals,
     * and sending to any number — none of it dependent on a notification.
     *
     * Advertised only while the user has turned SMS on *and* granted the permissions, so
     * the Mac can tell "this build cannot" from "this phone has not been asked yet", and
     * so it knows to stop mirroring the messaging app's notifications: with SMS live those
     * would show every text twice.
     */
    const val SMS_CAPABILITY = "sms.v1"

    /**
     * This phone mirrors incoming and ongoing calls, and can answer, decline and end one
     * on the Mac's behalf.
     *
     * Calls are read out of notifications, which is what makes this cover WhatsApp and
     * Signal calls as well as cellular ones and costs no permission beyond the notification
     * access the app already has. **Audio is not part of it and cannot be** — Android lets
     * no third-party app capture voice-call audio — so the Mac rings and controls, and the
     * sound stays on this phone.
     */
    const val CALL_CAPABILITY = "call.v1"

    /**
     * Generic file transfer, both directions, chunked and resumable.
     *
     * The clipboard carries one image at a time and stays that way; this is the channel
     * for everything else. Advertised unconditionally: receiving needs no permission on
     * API 33+ (`MediaStore` writes into the public Downloads collection), and sending is
     * driven by the user sharing something into this app.
     */
    const val FILE_TRANSFER_CAPABILITY = "file.v1"

    /** Public-API Android display capture over a second authenticated socket. */
    const val MIRROR_VIDEO_CAPABILITY = "mirror.video.v1"

    /** Pointer gestures and system navigation while a mirror session is active. */
    const val MIRROR_CONTROL_CAPABILITY = "mirror.control.v1"

    const val MAX_IMAGE_BYTES = 25 * 1024 * 1024

    /**
     * The largest file either end will accept. Beyond this the staging copy this app makes
     * in its own cache stops being a reasonable thing to keep on a phone.
     */
    const val MAX_FILE_BYTES = 2L * 1024 * 1024 * 1024

    /**
     * One `file.chunk` body. Not arbitrary: the relay re-chunks at 32 KiB with 2 MiB of
     * backpressure, OkHttp closes a socket whose outbound queue passes 16 MiB, and a
     * whole-file frame would move the progress bar exactly once.
     */
    const val FILE_CHUNK_BYTES = 256 * 1024

    /** How many chunks a sender may have unacked. `file.ack` returns the credit. */
    const val FILE_WINDOW_CHUNKS = 16

    /** How often a receiver acks — often enough to keep the window full, no more. */
    const val FILE_ACK_EVERY_CHUNKS = 4

    /** Everything this build can do. SMS is added per-connection once it is switched on. */
    val CAPABILITIES = listOf(
        IMAGE_CLIPBOARD_CAPABILITY,
        OFFLINE_REPLY_CAPABILITY,
        FILE_TRANSFER_CAPABILITY,
        MIRROR_VIDEO_CAPABILITY,
        MIRROR_CONTROL_CAPABILITY
    )

    /**
     * A transfer id. Hex only, so it can name a staging file without escaping the
     * directory it belongs in.
     */
    fun isTransferId(value: String): Boolean =
        value.length in 8..64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    /**
     * A filename off the wire, checked before it is stored anywhere. This is the refusal
     * bar, not the sanitiser: a name that passes here is still rewritten by
     * `TransferPlan.safeFilename` before anything is written under it.
     */
    fun isValidTransferName(value: String): Boolean {
        val bytes = value.toByteArray(Charsets.UTF_8).size
        if (bytes !in 1..255) return false
        if (value == "." || value == "..") return false
        return value.none { it == '/' || it == '\\' || it == '\u0000' }
    }

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
    val hosts: List<String> = listOf(host),
    /**
     * How to reach this Mac when the local network carries nothing between its own
     * clients. Absent when the Mac has no relay, or has not reached it yet.
     */
    val relayHost: String? = null,
    val relayRoom: String? = null
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
                // Both or neither: half a relay target is a guaranteed doomed round trip
                // on every reconnect, and it is silently useless rather than loudly wrong.
                val relayHost = o.optString("relayHost").trim()
                    .takeIf { RelayConfig.isValidHost(it) }
                val relayRoom = o.optString("relayRoom").trim()
                    .takeIf { RelayConfig.isValidRoom(it) }
                val relay = if (relayHost != null && relayRoom != null) {
                    relayHost to relayRoom
                } else null
                if (!isValidHost(host) ||
                    port !in 1..65535 ||
                    usbPort != null && usbPort !in 1..65535 ||
                    runCatching { Base64.getDecoder().decode(spki).size }.getOrNull() != 32 ||
                    runCatching { Base64.getDecoder().decode(token).size }.getOrNull() != 32
                ) null else PairingPayload(
                    host, port, spki, token, usbPort, hosts, relay?.first, relay?.second
                )
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
        deviceToken: String?,
        extraCapabilities: List<String> = emptyList(),
        transport: String? = null
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
        put("capabilities", JSONArray(Proto.CAPABILITIES + extraCapabilities))
        transport?.let { put("transport", it) }
    }

    fun deviceState(
        battery: Int?,
        charging: Boolean,
        dnd: Boolean,
        transport: String? = null
    ): JSONObject =
        Proto.envelope("device.state").apply {
            battery?.let { put("battery", it) }
            put("charging", charging)
            put("dnd", dnd)
            transport?.let { put("transport", it) }
        }

    fun mirrorState(
        state: String,
        requestId: String? = null,
        sessionId: String? = null,
        controlAvailable: Boolean,
        reason: String? = null
    ): JSONObject = Proto.envelope("mirror.state").apply {
        put("state", state)
        requestId?.let { put("requestId", it) }
        sessionId?.let { put("sessionId", it) }
        put("controlAvailable", controlAvailable)
        reason?.let { put("reason", it) }
    }

    fun mirrorInputResult(
        sessionId: String,
        inputId: String,
        ok: Boolean,
        error: String? = null
    ): JSONObject = Proto.envelope("mirror.input.result").apply {
        put("sessionId", sessionId)
        put("inputId", inputId)
        put("ok", ok)
        error?.let { put("error", it) }
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

    /**
     * Every notification key this phone still holds a reply action for.
     *
     * The Mac cannot work this out for itself. Its history remembers that a conversation
     * once offered a reply, but the intent that reply travels through lives only in this
     * process — a chat cleared before the service was last restarted is gone, and offering
     * a composer for it promises something that cannot be delivered.
     */
    fun notifReplyKeys(keys: Set<String>): JSONObject =
        Proto.envelope("notif.reply.keys").put("keys", JSONArray(keys.toList()))

    /**
     * The fate of one `notif.reply`. `clientId` is echoed straight back from the request
     * so the Mac can find the bubble it belongs to; it is absent from older Mac builds,
     * and then this is informational only.
     */
    fun notifReplyResult(
        clientId: String?,
        key: String,
        actionId: Int,
        ok: Boolean,
        error: String?
    ): JSONObject = Proto.envelope("notif.reply.result").apply {
        clientId?.let { put("clientId", it) }
        put("key", key)
        put("actionId", actionId)
        put("ok", ok)
        error?.let { put("error", it) }
    }

    fun iconData(hash: String, bytes: Int): JSONObject =
        Proto.envelope("icon.data").put("hash", hash).put("bytes", bytes)

    fun clipUpdate(body: String, seq: Int): JSONObject =
        Proto.envelope("clip.update")
            .put("format", "text")
            .put("body", body)
            .put("origin", "android")
            .put("seq", seq)

    // MARK: - Calls

    /**
     * One call, on every change to it. `ENDED` is the last thing sent for an id.
     *
     * The capability flags travel per call rather than per phone: whether *this*
     * notification carried an answer intent, and whether Telecom will take it otherwise.
     * A Mac that drew a button resolving to nothing would be worse than one that drew none.
     */
    fun callState(call: CallSnapshot, resync: Boolean): JSONObject =
        Proto.envelope("call.state").apply {
            put("id", call.id)
            put("state", call.state.wire)
            put("direction", call.direction.wire)
            put("pkg", call.pkg)
            put("appLabel", call.appLabel)
            call.iconHash?.let { put("iconHash", it) }
            call.avatarHash?.let { put("avatarHash", it) }
            call.displayName?.let { put("displayName", it) }
            call.number?.let { put("number", it) }
            put("video", call.isVideo)
            put("when", call.whenMs)
            put("canAnswer", call.canAnswer)
            put("canDecline", call.canDecline)
            put("canHangUp", call.canHangUp)
            if (resync) put("resync", true)
            put("actions", JSONArray().apply {
                call.actions.forEach {
                    put(JSONObject()
                        .put("id", it.id)
                        .put("label", it.label)
                        .put("isReply", it.isReply))
                }
            })
        }

    /** What became of a `call.action`. Failure carries a sentence the Mac shows as-is. */
    fun callActionResult(
        clientId: String?,
        id: String,
        action: CallAction,
        ok: Boolean,
        error: String?
    ): JSONObject = Proto.envelope("call.action.result").apply {
        clientId?.let { put("clientId", it) }
        put("id", id)
        put("action", action.wire)
        put("ok", ok)
        error?.let { put("error", it) }
    }

    // MARK: - SMS

    fun smsThreads(threads: List<SmsThreadWire>): JSONObject =
        Proto.envelope("sms.threads").put("threads", JSONArray().apply {
            threads.forEach { t ->
                put(JSONObject()
                    .put("id", t.id)
                    .put("address", t.address)
                    .put("displayName", t.displayName)
                    .put("snippet", t.snippet)
                    .put("when", t.whenMs)
                    .put("unread", t.unread))
            }
        })

    fun smsMessages(threadId: Long, messages: List<SmsMessageWire>, complete: Boolean)
        : JSONObject = Proto.envelope("sms.messages").apply {
            put("threadId", threadId)
            put("complete", complete)
            put("messages", JSONArray().apply { messages.forEach { put(smsBody(it)) } })
        }

    fun smsReceived(message: SmsMessageWire): JSONObject =
        Proto.envelope("sms.received").put("message", smsBody(message))

    fun smsSendResult(clientId: String, ok: Boolean, error: String?, threadId: Long?)
        : JSONObject = Proto.envelope("sms.send.result").apply {
            put("clientId", clientId)
            put("ok", ok)
            threadId?.let { put("threadId", it) }
            error?.let { put("error", it) }
        }

    private fun smsBody(m: SmsMessageWire): JSONObject = JSONObject()
        .put("id", m.id)
        .put("threadId", m.threadId)
        .put("address", m.address)
        .put("body", m.body)
        .put("when", m.whenMs)
        .put("outgoing", m.outgoing)
        .put("read", m.read)
        .apply { m.displayName?.let { put("displayName", it) } }

    fun clipImage(image: ClipImageHeader): JSONObject =
        Proto.envelope("clip.image")
            .put("origin", image.origin)
            .put("seq", image.seq)
            .put("mime", image.mime)
            .put("bytes", image.bytes)
            .put("sha256", image.sha256)
            .apply { image.name?.let { put("name", it) } }

    // Files — see `protocol/PROTOCOL.md`, "Files".

    fun fileOffer(offer: FileOfferHeader): JSONObject = Proto.envelope("file.offer")
        .put("id", offer.id)
        .put("name", offer.name)
        .put("bytes", offer.bytes)
        .put("mime", offer.mime)
        .put("sha256", offer.sha256)
        .apply { offer.modified?.let { put("modified", it) } }

    fun fileBegin(id: String, offset: Long): JSONObject = Proto.envelope("file.begin")
        .put("id", id)
        .put("offset", offset)

    fun fileChunk(id: String, offset: Long, bytes: Int): JSONObject =
        Proto.envelope("file.chunk")
            .put("id", id)
            .put("offset", offset)
            .put("bytes", bytes)

    fun fileAck(id: String, received: Long): JSONObject = Proto.envelope("file.ack")
        .put("id", id)
        .put("received", received)

    fun fileDone(id: String): JSONObject = Proto.envelope("file.done").put("id", id)

    /** `error` is absent rather than null on success: the Mac decodes it into an optional. */
    fun fileResult(id: String, ok: Boolean, error: String?): JSONObject =
        Proto.envelope("file.result")
            .put("id", id)
            .put("ok", ok)
            .apply { if (!ok && error != null) put("error", error.take(200)) }

    fun fileCancel(id: String, reason: String): JSONObject = Proto.envelope("file.cancel")
        .put("id", id)
        .put("reason", reason)
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

/**
 * Announces one file. Answered with `file.begin`, or `file.cancel` if this end will not
 * take it.
 *
 * `sha256` covers the whole file and is in the offer rather than in `file.done`
 * deliberately: it costs the sender one read pass before the first byte moves, and it is
 * what lets a resumed transfer be verified rather than assumed.
 */
data class FileOfferHeader(
    val id: String,
    val name: String,
    val bytes: Long,
    val mime: String,
    val sha256: String,
    /** Source modification time, epoch millis. Advisory; the receiver may ignore it. */
    val modified: Long?
) {
    val isValid: Boolean
        get() = Proto.isTransferId(id) && bytes in 1..Proto.MAX_FILE_BYTES &&
            mime.length in 1..100 && Proto.isValidTransferName(name) &&
            sha256.length == 64 && sha256.all { it in '0'..'9' || it in 'a'..'f' }

    companion object {
        fun parse(obj: JSONObject): FileOfferHeader? = runCatching {
            FileOfferHeader(
                id = obj.getString("id").lowercase(),
                name = obj.getString("name"),
                bytes = obj.getLong("bytes"),
                mime = obj.getString("mime"),
                sha256 = obj.getString("sha256").lowercase(),
                modified = if (obj.has("modified")) obj.getLong("modified") else null
            ).takeIf { it.isValid }
        }.getOrNull()
    }
}

/**
 * Metadata for one chunk. The next binary frame carries exactly `bytes` bytes.
 *
 * There is no id inside the binary frame, which is why header and body are sent as one
 * indivisible pair and why a second one arriving while this is outstanding is fatal to the
 * session: the alternative is writing one transfer's bytes into another's file.
 */
data class FileChunkHeader(val id: String, val offset: Long, val bytes: Int) {
    val isValid: Boolean
        get() = Proto.isTransferId(id) && offset >= 0 &&
            bytes in 1..Proto.FILE_CHUNK_BYTES

    companion object {
        fun parse(obj: JSONObject): FileChunkHeader? = runCatching {
            FileChunkHeader(
                id = obj.getString("id").lowercase(),
                offset = obj.getLong("offset"),
                bytes = obj.getInt("bytes")
            ).takeIf { it.isValid }
        }.getOrNull()
    }
}

/**
 * The wire shapes for `sms.*`, kept here beside every other message rather than in the
 * sms package: `protocol/PROTOCOL.md` is the source of truth and this file is its
 * counterpart. `com.tennanova.sms` maps its own models onto these.
 */
data class SmsThreadWire(
    val id: Long,
    val address: String,
    val displayName: String,
    val snippet: String,
    val whenMs: Long,
    val unread: Int
)

data class SmsMessageWire(
    val id: Long,
    val threadId: Long,
    val address: String,
    val displayName: String?,
    val body: String,
    val whenMs: Long,
    val outgoing: Boolean,
    val read: Boolean
)
