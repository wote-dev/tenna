package com.tennanova.notifications

import android.app.Notification
import android.app.PendingIntent
import android.app.Person
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkRequest
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.BatteryManager
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import com.tennanova.calls.CallAction
import com.tennanova.calls.CallDirection
import com.tennanova.calls.CallIntents
import com.tennanova.calls.CallMonitor
import com.tennanova.calls.CallSignal
import com.tennanova.calls.CallSnapshot
import com.tennanova.calls.CallState
import com.tennanova.core.CallAccessStatus
import com.tennanova.core.SmsAccessStatus
import com.tennanova.core.SmsMessageWire
import com.tennanova.core.SmsThreadWire
import com.tennanova.sms.SmsMessage
import com.tennanova.sms.SmsMirror
import com.tennanova.sms.SmsThreadSummary
import com.tennanova.core.Messages
import com.tennanova.core.NotifAction
import com.tennanova.core.ClipImageHeader
import com.tennanova.core.ConnectionStatus
import com.tennanova.core.Proto
import com.tennanova.core.RuntimeStatusStore
import com.tennanova.clipboard.ClipboardPayload
import com.tennanova.clipboard.ImageTransfer
import com.tennanova.clipboard.ClipboardAccessStatus
import com.tennanova.clipboard.TennaAccessibilityService
import com.tennanova.core.PairingPayload
import com.tennanova.core.Settings
import com.tennanova.net.ConnectionEndpoint
import com.tennanova.net.ConnectionTransport
import com.tennanova.net.DiscoveredEndpoint
import com.tennanova.net.RelayBridge
import com.tennanova.net.SocketClient
import com.tennanova.net.MacDiscovery
import com.tennanova.net.SubnetScanner
import org.json.JSONObject
import com.tennanova.files.FileTransfers
import com.tennanova.files.FileTransport
import com.tennanova.files.TransferNotifier
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger

/**
 * The heart of the Android side.
 *
 * This is a *bound* service: the system starts it, keeps it alive, and rebinds it if it
 * dies. That's why the WebSocket lives here rather than in a foreground service — it
 * sidesteps Android 15's 6-hour cap on `dataSync` foreground services entirely.
 */
class TennaNotificationListener : NotificationListenerService() {

    private lateinit var settings: Settings
    private lateinit var discovery: MacDiscovery
    private lateinit var relay: RelayBridge
    private var socket: SocketClient? = null
    private var authenticated = false
    private var peerSupportsImages = false
    private var peerSupportsFiles = false

    /**
     * The one header still waiting for its binary frame.
     *
     * Still a single slot, not a map, and a second header arriving while one is
     * outstanding is fatal to the session: a binary frame carries no id, so it can only be
     * attributed to the header immediately before it. Both senders queue a header and its
     * body as one indivisible pair, which is what makes that safe.
     */
    private var pendingBinary: PendingBinary? = null

    private sealed interface PendingBinary {
        data class Image(val header: ClipImageHeader) : PendingBinary
        data class FileChunk(val header: com.tennanova.core.FileChunkHeader) : PendingBinary
    }

    private var files: FileTransfers? = null
    private var notifier: TransferNotifier? = null
    private var networkCallbackRegistered = false
    private var allNetworksCallbackRegistered = false
    /** Live all-network NSD results. Unlike persisted hosts these retain their exact route. */
    @Volatile
    private var discoveredEndpoints: List<DiscoveredEndpoint> = emptyList()
    /** Consecutive rounds in which every known address failed. Reset by `hello.ack`. */
    private var exhaustedRounds = 0

    /** Reply/action plumbing for notifications currently on screen, keyed by SBN key. */
    private val actionMap = RetainedActions<List<Notification.Action>>()

    /**
     * What this phone has recently said on the Mac's behalf, keyed by the same SBN key.
     *
     * The last line of defence in [SelfMessage]: an app that re-posts a conversation
     * carrying the reply we just fired is echoing us, whatever its notification looks
     * like. Bounded and least-recently-used like the action map, and for the same reason —
     * this service is long-lived.
     */
    private val ourReplies = RetainedActions<SelfMessage.SentReply>(OWN_REPLY_MEMORY)
    private val sms by lazy { SmsMirror(this) }
    /**
     * Live calls, and the intents that answer them. Fed from the notification stream
     * rather than from a telephony API, which is what makes it cover WhatsApp and Signal
     * calls as well as cellular ones — see [CallMonitor].
     */
    private val calls by lazy { CallMonitor(this) }
    /** Resolved once: it cannot change without the user changing a system setting. */
    private val defaultSmsPackage: String? by lazy {
        runCatching { android.provider.Telephony.Sms.getDefaultSmsPackage(this) }.getOrNull()
    }

    /**
     * Content-addressed PNGs the Mac can ask for by hash — app icons and contact photos
     * share one store, since `icon.request` is just a hash-to-bytes channel. Bounded so a
     * long-lived service doesn't accumulate every avatar it has ever seen; an evicted
     * entry costs the Mac a thumbnail, nothing more.
     */
    private val assetBytes = object : LinkedHashMap<String, ByteArray>(0, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, ByteArray>) = size > MAX_ASSETS
    }

    private val clipSeq = AtomicInteger(0)
    private val imageJob = AtomicInteger(0)

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = onNetworkChanged()
    }

    /**
     * Starting a hotspot does not change the *default* network — it stays cellular — so
     * the default-network callback never fires for the one case that needs it most.
     * This one watches every network, which is what notices the Mac becoming reachable.
     */
    private val allNetworksCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = onNetworkChanged()
        override fun onLost(network: Network) = onNetworkChanged()
    }

    private fun onNetworkChanged() {
        if (settings.isPaired) discovery.start()
        socket?.retryNow()
    }

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        discovery = MacDiscovery(this, expectedSpki = { settings.spki }) { endpoints ->
            discoveredEndpoints = endpoints
            val currentPort = settings.port
            settings.rememberHosts(endpoints.filter { it.port == currentPort }.map { it.host })
            // retryNow refuses to disturb an authenticated socket. While offline it
            // cancels stale address attempts and takes the newly resolved route at once.
            socket?.retryNow()
        }
        relay = RelayBridge(this) {
            settings.relayTarget?.let { (host, room) -> RelayBridge.RelayTarget(host, room) }
        }
        notifier = TransferNotifier(this)
        files = FileTransfers(
            context = this,
            transport = object : FileTransport {
                override fun sendJson(message: JSONObject): Boolean =
                    socket?.send(message) == true

                override fun sendChunk(header: JSONObject, body: ByteArray): Boolean =
                    socket?.sendBinary(header, body) == true
            },
            onChanged = RuntimeStatusStore::updateTransfers,
            onArrived = { item, uri -> notifier?.arrived(item, uri) },
            onSummary = RuntimeStatusStore::transfer
        ).also { it.sweepStaleStaging() }

        RuntimeStatusStore.attach(this)
        RuntimeStatusStore.updatePairing(settings.isPairingConfirmed, settings.macName)
        RuntimeStatusStore.updateClipboard(
            if (TennaAccessibilityService.isEnabled(this)) ClipboardAccessStatus.READY
            else ClipboardAccessStatus.NEEDS_ACCESSIBILITY
        )
        val connectivity = getSystemService(ConnectivityManager::class.java)
        runCatching {
            connectivity.registerDefaultNetworkCallback(networkCallback)
            networkCallbackRegistered = true
        }
        runCatching {
            connectivity.registerNetworkCallback(
                NetworkRequest.Builder().clearCapabilities().build(),
                allNetworksCallback
            )
            allNetworksCallbackRegistered = true
        }
        Log.i(TAG, "notification listener created")
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "listener connected to the system")
        RuntimeStatusStore.updateConnectionService(true)
        if (settings.isPaired) relay.start()
        startSocket()
        if (settings.isPaired) discovery.start()
    }

    override fun onListenerDisconnected() {
        Log.w(TAG, "listener disconnected — requesting rebind")
        RuntimeStatusStore.updateConnectionService(false)
        setAuthenticated(false)
        socket?.stop()
        socket = null
        relay.stop()
        // Without this the service can stay dead until reboot.
        requestRebind(android.content.ComponentName(this, TennaNotificationListener::class.java))
    }

    override fun onDestroy() {
        RuntimeStatusStore.updateConnectionService(false)
        sms.stop()
        socket?.stop()
        relay.stop()
        discovery.stop()
        val connectivity = getSystemService(ConnectivityManager::class.java)
        if (networkCallbackRegistered) runCatching {
            connectivity.unregisterNetworkCallback(networkCallback)
        }
        if (allNetworksCallbackRegistered) runCatching {
            connectivity.unregisterNetworkCallback(allNetworksCallback)
        }
        RuntimeStatusStore.detach(this)
        super.onDestroy()
    }

    // MARK: - Socket

    private fun startSocket() {
        // The system rebinds this service freely, so onListenerConnected can arrive more
        // than once. Without this, each arrival stranded a live SocketClient that kept
        // reconnecting forever — and since the Mac drops its existing session whenever a
        // new connection arrives, the orphans knocked each other offline in a loop.
        socket?.stop()
        socket = null
        if (!settings.isPaired) {
            Log.i(TAG, "not paired yet — socket idle")
            RuntimeStatusStore.updateConnection(ConnectionStatus.UNPAIRED)
            return
        }
        val client = SocketClient(
            context = this,
            settings = settings,
            onMessage = ::handleMessage,
            onBinary = ::handleBinary,
            onEndpointsExhausted = ::probeForMac,
            discoveredEndpoints = {
                discoveredEndpoints.map {
                    ConnectionEndpoint(it.host, it.port, isUsb = false, network = it.network)
                }
            },
            relayPort = { relay.localPort },
            onStateChange = { state ->
                when (state) {
                    SocketClient.State.CONNECTED -> {
                        setAuthenticated(false)
                        RuntimeStatusStore.updateTransport(
                            socket?.transport ?: ConnectionTransport.NONE
                        )
                        RuntimeStatusStore.updateConnection(ConnectionStatus.AUTHENTICATING)
                        sendHello()
                    }
                    SocketClient.State.CONNECTING -> {
                        setAuthenticated(false)
                        RuntimeStatusStore.updateTransport(ConnectionTransport.NONE)
                        // A diagnostic found after several failed rounds must not flash
                        // away for every automatic retry and then reappear seconds later.
                        RuntimeStatusStore.updateConnection(
                            ConnectionStatus.CONNECTING,
                            RuntimeStatusStore.state.value.connectionError
                        )
                    }
                    SocketClient.State.PIN_MISMATCH -> {
                        setAuthenticated(false)
                        RuntimeStatusStore.updateConnection(
                            ConnectionStatus.PIN_MISMATCH,
                            "The Mac identity changed. Re-pair to continue."
                        )
                    }
                    SocketClient.State.AUTH_FAILED -> {
                        setAuthenticated(false)
                        RuntimeStatusStore.updateConnection(
                            ConnectionStatus.AUTH_FAILED,
                            "The Mac rejected this pairing. Scan a fresh code on the Mac."
                        )
                    }
                    SocketClient.State.UNPAIRED -> {
                        setAuthenticated(false)
                        RuntimeStatusStore.updateConnection(ConnectionStatus.UNPAIRED)
                    }
                    SocketClient.State.DISCONNECTED -> {
                        setAuthenticated(false)
                        // Keeps any isolation hint from the previous exhausted round: this
                        // fires before onEndpointsExhausted on the first round, but after
                        // it on every one that follows, and passing null would blank it.
                        RuntimeStatusStore.updateConnection(
                            ConnectionStatus.DISCONNECTED,
                            RuntimeStatusStore.state.value.connectionError
                        )
                    }
                }
            }
        )
        // Assigned before starting: start() delivers its first state change synchronously,
        // and the DISCONNECTED branch reads `socket` back.
        socket = client
        client.start()
    }

    /**
     * Nothing we know about answered. On a hotspot that is the normal first outcome —
     * the Mac's address there is one neither device has ever seen — so sweep the subnets
     * the phone is actually attached to. [SubnetScanner] rate-limits itself.
     */
    private fun probeForMac() {
        if (!settings.isPaired) return
        exhaustedRounds++
        // mDNS answers are multicast, which a router with AP client isolation still
        // forwards, while the unicast TCP connect they advertise is exactly what it
        // blocks. Watching the Mac announce itself and still failing to reach it, round
        // after round, is that signature — and "Mac offline" is a bad description of it,
        // because the Mac is right there. USB is the way out, so say so.
        if (discoveredEndpoints.isNotEmpty() && exhaustedRounds >= ISOLATION_HINT_ROUNDS) {
            RuntimeStatusStore.updateConnection(
                ConnectionStatus.DISCONNECTED,
                if (settings.relayTarget != null) {
                    "This network blocks traffic between its own devices, so Tennanova " +
                        "is connecting over the internet instead."
                } else {
                    "Your Mac is on this network but the connection is being blocked — " +
                        "many routers block device-to-device traffic. Connect the phone " +
                        "by USB, or use your phone's hotspot."
                }
            )
        } else if (discoveredEndpoints.isEmpty()) {
            RuntimeStatusStore.updateConnection(
                ConnectionStatus.DISCONNECTED,
                if (settings.relayTarget != null) {
                    "This network is not carrying device-to-device traffic. Tennanova " +
                        "is reaching your Mac over the internet instead."
                } else {
                    "No connection reached the Mac at ${settings.hosts.joinToString(", ")}. " +
                        "The connection service is running, but the network is not " +
                        "carrying traffic between your phone and your Mac."
                }
            )
        }
        SubnetScanner.scan(this, settings.port) { found ->
            settings.rememberHosts(found)
            socket?.retryNow()
        }
    }

    /** Called by the UI after a successful QR pair. */
    fun onPairingChanged() {
        setAuthenticated(false)
        RuntimeStatusStore.updatePairing(settings.isPairingConfirmed, settings.macName)
        RuntimeStatusStore.updateConnection(
            if (settings.isPaired) ConnectionStatus.DISCONNECTED
            else ConnectionStatus.UNPAIRED
        )
        // A different Mac may push different content; don't suppress its first write.
        ClipboardWriter.reset()
        if (settings.isPaired) {
            discovery.start()
            relay.start()
        } else {
            discovery.stop()
            relay.stop()
        }
        startSocket()
    }

    private fun sendHello() {
        val bm = getSystemService(BatteryManager::class.java)
        val battery = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        socket?.send(
            Messages.hello(
                deviceId = settings.deviceId,
                deviceName = android.os.Build.MODEL ?: "Android",
                model = android.os.Build.MODEL ?: "Android",
                sdk = android.os.Build.VERSION.SDK_INT,
                battery = battery,
                pairingToken = settings.pairingToken,
                deviceToken = settings.deviceToken,
                extraCapabilities = buildList {
                    if (smsAvailable()) add(Proto.SMS_CAPABILITY)
                    if (settings.callsEnabled) add(Proto.CALL_CAPABILITY)
                }
            )
        )
    }

    private fun handleMessage(msg: JSONObject) {
        when (msg.optString("type")) {
            "hello.ack" -> {
                msg.optString("deviceToken").takeIf { it.isNotEmpty() }?.let {
                    settings.deviceToken = it
                    settings.pairingToken = null
                    Log.i(TAG, "paired — long-lived token stored")
                }
                msg.optString("macName").takeIf { it.isNotBlank() }?.let {
                    settings.macName = it
                }
                RuntimeStatusStore.updatePairing(true, settings.macName)
                adoptReportedHosts(msg)
                peerSupportsImages = msg.optJSONArray("capabilities")?.let { array ->
                    (0 until array.length()).any {
                        array.optString(it) == Proto.IMAGE_CLIPBOARD_CAPABILITY
                    }
                } == true
                peerSupportsFiles = msg.optJSONArray("capabilities")?.let { array ->
                    (0 until array.length()).any {
                        array.optString(it) == Proto.FILE_TRANSFER_CAPABILITY
                    }
                } == true
                RuntimeStatusStore.updatePeerCapabilities(peerSupportsImages, peerSupportsFiles)
                exhaustedRounds = 0
                socket?.sessionAuthenticated()
                setAuthenticated(true)
                RuntimeStatusStore.updateConnection(ConnectionStatus.CONNECTED)
                // Populate the Mac and rebuild action mappings only after authentication.
                activeNotifications?.forEach { handlePosted(it, resync = true) }
                startSmsMirror()
                publishCallStatus()
                // Anything paused by the last disconnect is re-offered under the same id,
                // so a transfer interrupted by a walk out of Wi-Fi range picks up where it
                // stopped rather than starting over.
                files?.sessionReady(peerSupportsFiles)
                // After the replay, and not before: the replay is what repopulates the
                // action map for everything still on the phone's shade. Anything the user
                // cleared before this service last started is genuinely unreplyable, and
                // the Mac has to be told rather than left to guess from its own history.
                sendReplyableKeys()
            }

            "hello.nack" -> {
                val reason = msg.optString("reason")
                Log.e(TAG, "Mac rejected us: $reason")
                setAuthenticated(false)
                socket?.failAuthentication()
                // After failAuthentication, whose state change carries only a generic
                // message — this one names the reason the Mac actually gave.
                RuntimeStatusStore.updateConnection(
                    ConnectionStatus.AUTH_FAILED,
                    "Pairing was rejected ($reason). Scan a fresh code on the Mac."
                )
            }

            else -> if (!authenticated) {
                Log.w(TAG, "ignoring ${msg.optString("type")} before hello.ack")
                return
            }
        }

        if (!authenticated) return

        when (msg.optString("type")) {

            "notif.reply" -> {
                val key = msg.optString("key")
                val actionId = msg.optInt("actionId")
                val text = msg.optString("text")
                // Absent from older Mac builds; then the result simply goes unclaimed.
                val clientId = msg.optString("clientId").ifEmpty { null }
                sendReply(key, actionId, text, clientId)
            }

            "sms.thread.request" -> {
                val threadId = msg.optLong("threadId")
                val beforeId = if (msg.has("beforeId")) msg.optLong("beforeId") else null
                val limit = msg.optInt("limit", 100)
                sendSmsThread(threadId, beforeId, limit)
            }

            "sms.send" -> {
                sendSms(
                    address = msg.optString("address"),
                    body = msg.optString("body"),
                    clientId = msg.optString("clientId")
                )
            }

            "call.action" -> {
                val id = msg.optString("id")
                val clientId = msg.optString("clientId").ifEmpty { null }
                val action = CallAction.parse(msg.optString("action"))
                if (action == null) {
                    Log.w(TAG, "unknown call action: ${msg.optString("action")}")
                } else {
                    val error = calls.perform(id, action)
                    if (error != null) Log.w(TAG, "call ${action.wire} failed: $error")
                    socket?.send(
                        Messages.callActionResult(clientId, id, action, error == null, error)
                    )
                    publishCallStatus()
                }
            }

            "notif.action" -> {
                invokeAction(msg.optString("key"), msg.optInt("actionId"))
            }

            "mac.hosts" -> adoptReportedHosts(msg)

            "notif.dismiss" -> {
                val key = msg.optString("key")
                Log.i(TAG, "dismissing $key at the Mac's request")
                cancelNotification(key)
            }

            "icon.request" -> {
                val hash = msg.optString("hash")
                assetBytes[hash]?.let { bytes ->
                    socket?.sendBinary(Messages.iconData(hash, bytes.size), bytes)
                }
            }

            "clip.update" -> {
                // Writing the clipboard needs no permission at all — OP_WRITE_CLIPBOARD
                // is unconditional in AOSP. Only *reading* is restricted.
                val body = msg.optString("body")
                // Absent origin is tolerated — it is additive within v1 — but a message the
                // Mac has labelled as ours is our own copy coming home, and applying it would
                // raise a second system "Copied" panel for one user action.
                val echoed = msg.optString("origin") == "android"
                if (body.isNotEmpty() && !echoed) {
                    when (val result = ClipboardWriter.writeText(this, body)) {
                        is ClipboardWriteResult.Written ->
                            RuntimeStatusStore.transfer("Text received from Mac")
                        // The Mac re-pushes its clipboard on every hello; saying nothing
                        // is the whole point.
                        ClipboardWriteResult.Unchanged -> Unit
                        is ClipboardWriteResult.Failed ->
                            RuntimeStatusStore.transfer("Text rejected", result.error.message)
                    }
                }
            }

            "clip.image" -> {
                val header = ClipImageHeader.parse(msg)
                if (!peerSupportsImages || header == null || header.origin != "mac" ||
                    pendingBinary != null) {
                    RuntimeStatusStore.transfer("Image rejected", "Invalid image metadata")
                    pendingBinary = null
                } else {
                    pendingBinary = PendingBinary.Image(header)
                }
            }

            "file.offer" -> files?.onOffer(msg)
            "file.begin" -> files?.onBegin(msg)
            "file.ack" -> files?.onAck(msg)
            "file.done" -> files?.onDone(msg)
            "file.result" -> files?.onResult(msg)
            "file.cancel" -> files?.onCancel(msg)

            "file.chunk" -> {
                val header = com.tennanova.core.FileChunkHeader.parse(msg)
                if (header == null || pendingBinary != null) {
                    // Writing one transfer's bytes into another's file is worse than
                    // losing the session, so this is not something to recover from.
                    Log.w(TAG, "invalid or interleaved file.chunk header")
                    pendingBinary = null
                    socket?.stop()
                } else {
                    pendingBinary = PendingBinary.FileChunk(header)
                }
            }
        }
    }

    private fun handleBinary(bytes: ByteArray) {
        val pending = pendingBinary
        pendingBinary = null
        if (!authenticated || pending == null) {
            Log.w(TAG, "received binary data with no header expecting it")
            return
        }

        when (pending) {
            is PendingBinary.FileChunk -> files?.onChunk(pending.header, bytes)

            is PendingBinary.Image -> {
                val header = pending.header
                if (bytes.size != header.bytes ||
                    ImageTransfer.sha256(bytes) != header.sha256
                ) {
                    RuntimeStatusStore.transfer("Image rejected", "Image validation failed")
                    Log.w(TAG, "received invalid or unexpected binary clipboard payload")
                    return
                }
                when (val result = ClipboardWriter.writeImage(this, header, bytes)) {
                    is ClipboardWriteResult.Written ->
                        RuntimeStatusStore.transfer("Image received from Mac")
                    ClipboardWriteResult.Unchanged -> Unit
                    is ClipboardWriteResult.Failed ->
                        RuntimeStatusStore.transfer("Image rejected", result.error.message)
                }
            }
        }
    }

    // MARK: - Files

    /** Called from the UI when the user shares documents into this app. */
    fun onFilesShared(uris: List<android.net.Uri>) {
        files?.enqueue(uris)
    }

    fun onCancelTransfer(id: String) {
        files?.cancel(id)
    }

    fun onClearFinishedTransfers() {
        files?.clearFinished()
    }

    // MARK: - Notifications out

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        handlePosted(sbn, resync = false)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        // Withdrawn *before* the authentication check, because a call the phone is no
        // longer showing is a call that has ended whether or not a Mac is listening, and
        // leaving it in the monitor would let a later `call.action` fire a dead intent.
        val ended = calls.onRemoved(sbn.key)
        if (!authenticated) return
        if (ended != null) {
            socket?.send(Messages.callState(ended, resync = false))
            publishCallStatus()
            return
        }
        // The actions deliberately survive this. See [RetainedActions] — a cancelled
        // notification does not cancel its reply PendingIntent, and messaging apps
        // withdraw their notification the moment the chat is read on the phone.
        socket?.send(Messages.notifRemoved(sbn.key))
    }

    private fun handlePosted(sbn: StatusBarNotification, resync: Boolean) {
        if (!authenticated) return

        val n = sbn.notification
        val extras: Bundle = n.extras

        // Calls leave here and never enter the notification stream. They are a different
        // thing on the Mac — a ringing card with Answer and Decline, not a chat row that
        // can never be replied to — and mirroring both would show every call twice.
        if (settings.callsEnabled && mirrorCall(sbn, n, extras, resync)) return
        if (!shouldMirror(sbn)) return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val body = bodyText(extras)
        val messaging = messagingStyle(n)

        // Our own words coming back. A messaging app answers a reply by re-posting the
        // conversation with what you just said as its newest line, so mirroring this would
        // alert you about your own message and — since the repost is titled with the
        // speaker rather than the chat — file it under a conversation called "You".
        if (SelfMessage.isOurOwn(selfPost(extras, messaging, title, body),
                                 ourReplies.get(sbn.key), System.currentTimeMillis())) {
            // The actions are kept even so. After a reconnect this repost is often the
            // only sighting the phone gets of a chat, and dropping it whole would take the
            // Mac's composer for that conversation with it.
            n.actions?.let { actionMap.put(sbn.key, it.toList()) }
            Log.i(TAG, "not mirroring ${sbn.packageName}: newest message is our own")
            return
        }

        val appLabel = appLabel(sbn.packageName)
        val iconHash = cacheIcon(sbn.packageName)

        val actions = mutableListOf<NotifAction>()
        n.actions?.forEachIndexed { index, action ->
            val isReply = action.remoteInputs?.isNotEmpty() == true
            actions.add(NotifAction(index, action.title?.toString() ?: "Action", isReply))
        }
        n.actions?.let { actionMap.put(sbn.key, it.toList()) }

        socket?.send(
            Messages.notifPosted(
                key = sbn.key,
                pkg = sbn.packageName,
                appLabel = appLabel,
                iconHash = iconHash,
                avatarHash = cacheAvatar(n, messaging),
                title = title,
                body = body,
                whenMs = n.`when`,
                category = n.category,
                senderName = messaging?.let { lastSender(it) },
                conversationTitle = messaging?.conversationTitle?.toString()
                    ?: extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString(),
                resync = resync,
                actions = actions
            )
        )
    }

    // MARK: - Calls

    /**
     * Sends a call to the Mac, and answers whether this notification was one at all.
     *
     * True means the caller must stop: a call notification is *not* also mirrored as a
     * notification. Today those are dropped outright — `shouldMirror` refuses anything
     * ongoing, which every incoming call is — so nothing that used to reach the Mac stops
     * reaching it here.
     */
    private fun mirrorCall(
        sbn: StatusBarNotification,
        n: Notification,
        extras: Bundle,
        resync: Boolean
    ): Boolean {
        if (sbn.packageName == packageName) return false
        // Group summaries are the single biggest source of duplicates for notifications,
        // and a summary that inherits its group's `call` category would be a phantom call
        // ringing beside the real one.
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        // A muted app stays muted. Nothing in the app mutes one today, but the setting is
        // the user's word about that package and a call is not an exception to it.
        if (sbn.packageName in settings.mutedPackages) return false

        val answer = extras.getParcelable(
            Notification.EXTRA_ANSWER_INTENT, PendingIntent::class.java
        )
        val decline = extras.getParcelable(
            Notification.EXTRA_DECLINE_INTENT, PendingIntent::class.java
        )
        val hangUp = extras.getParcelable(
            Notification.EXTRA_HANG_UP_INTENT, PendingIntent::class.java
        )
        val state = CallSignal.classify(
            category = n.category,
            callType = if (extras.containsKey(Notification.EXTRA_CALL_TYPE)) {
                extras.getInt(Notification.EXTRA_CALL_TYPE)
            } else null,
            hasAnswerIntent = answer != null,
            hasHangUpIntent = hangUp != null,
            isOngoing = n.flags and Notification.FLAG_ONGOING_EVENT != 0
        ) ?: return false

        val person = extras.getParcelable(Notification.EXTRA_CALL_PERSON, Person::class.java)
        val number = CallSignal.numberFrom(person?.uri)

        // The dialer's own buttons — "Message", "Remind me". Answer and decline are not
        // among them; those are resolved by the monitor. Retained under the same key the
        // notification stream uses, so the Mac fires one with the existing `notif.action`
        // and no second action channel has to exist.
        val actions = mutableListOf<NotifAction>()
        n.actions?.forEachIndexed { index, action ->
            actions.add(
                NotifAction(
                    index,
                    action.title?.toString() ?: "Action",
                    action.remoteInputs?.isNotEmpty() == true
                )
            )
        }
        n.actions?.let { actionMap.put(sbn.key, it.toList()) }

        val snapshot = CallSnapshot(
            id = sbn.key,
            state = state,
            // Replaced by the monitor, which is the only thing that knows how this call
            // was first seen and therefore which way it was going.
            direction = CallDirection.INCOMING,
            pkg = sbn.packageName,
            appLabel = appLabel(sbn.packageName),
            displayName = CallSignal.displayName(
                personName = person?.name?.toString(),
                title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
                number = number
            ),
            number = number,
            isVideo = extras.getBoolean(Notification.EXTRA_CALL_IS_VIDEO, false),
            whenMs = if (n.`when` > 0) n.`when` else System.currentTimeMillis(),
            canAnswer = false,
            canDecline = false,
            canHangUp = false,
            iconHash = cacheIcon(sbn.packageName),
            avatarHash = cacheCallerPhoto(person, n),
            actions = actions
        )

        val resolved = calls.onPosted(snapshot, CallIntents(answer, decline, hangUp))
        socket?.send(Messages.callState(resolved, resync))
        publishCallStatus()
        Log.i(TAG, "call ${state.wire} from ${resolved.displayName ?: "unknown"} " +
            "(${resolved.appLabel}); answerable=${resolved.canAnswer}")
        return true
    }

    /**
     * The caller's photo. `CallStyle` names the person outright; everything else puts the
     * same picture in the large icon, which is where [cacheAvatar] looks for chats.
     */
    private fun cacheCallerPhoto(person: Person?, n: Notification): String? = try {
        val drawable = person?.icon?.loadDrawable(this) ?: n.getLargeIcon()?.loadDrawable(this)
        drawable?.let { cacheAsset(drawableToPng(it, AVATAR_PX)) }
    } catch (e: Exception) {
        Log.w(TAG, "no caller photo: ${e.message}")
        null
    }

    /**
     * `LIMITED` is the honest description of the common case: calls reach the Mac and most
     * dialers put answer and decline intents in the notification, but a dialer that does
     * not leaves nothing to press without the optional call-control grant.
     */
    private fun publishCallStatus() {
        RuntimeStatusStore.updateCalls(
            when {
                !settings.callsEnabled -> CallAccessStatus.OFF
                calls.hasCallControl() -> CallAccessStatus.READY
                else -> CallAccessStatus.LIMITED
            }
        )
    }

    private fun messagingStyle(n: Notification): NotificationCompat.MessagingStyle? =
        runCatching {
            NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)
        }.getOrNull()

    private fun lastSender(style: NotificationCompat.MessagingStyle): String? =
        style.messages.lastOrNull()?.person?.name?.toString()?.takeIf { it.isNotBlank() }

    /** The line the phone is showing, wherever this app chose to put it. */
    private fun bodyText(extras: Bundle): String? =
        (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()
            ?: extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
                ?.joinToString("\n")

    /** Everything [SelfMessage] needs, lifted out of a real notification. */
    private fun selfPost(
        extras: Bundle,
        messaging: NotificationCompat.MessagingStyle?,
        title: String?,
        body: String?
    ): SelfMessage.Post {
        val last = messaging?.messages?.lastOrNull()
        return SelfMessage.Post(
            hasMessages = last != null,
            lastSenderName = last?.person?.name?.toString(),
            lastSenderKey = last?.person?.key,
            selfName = messaging?.user?.name?.toString(),
            selfKey = messaging?.user?.key,
            title = title,
            conversationTitle = messaging?.conversationTitle?.toString()
                ?: extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString(),
            body = body,
            remoteInputHistory = extras
                .getCharSequenceArray(Notification.EXTRA_REMOTE_INPUT_HISTORY)
                ?.map { it.toString() } ?: emptyList()
        )
    }

    /**
     * Filters that keep the Mac quiet and duplicate-free.
     * Group summaries are the single biggest source of duplicates.
     */
    private fun shouldMirror(sbn: StatusBarNotification): Boolean {
        val n = sbn.notification
        val extras = n.extras
        return MirrorDecision.shouldMirror(
            packageName = sbn.packageName,
            ownPackage = packageName,
            flags = n.flags,
            hasText = extras.getCharSequence(Notification.EXTRA_TEXT) != null ||
                extras.getCharSequence(Notification.EXTRA_BIG_TEXT) != null ||
                extras.getCharSequence(Notification.EXTRA_TITLE) != null,
            mutedPackages = settings.mutedPackages,
            smsActive = smsAvailable(),
            defaultSmsPackage = defaultSmsPackage
        )
    }

    // MARK: - Replies

    private fun sendReply(key: String, actionId: Int, text: String, clientId: String?) {
        val action = actionMap.get(key)?.getOrNull(actionId) ?: run {
            Log.w(TAG, "no action $actionId for $key")
            replyResult(clientId, key, actionId, false,
                "This phone no longer has a way to reply to that conversation.")
            return
        }
        val remoteInputs = action.remoteInputs ?: run {
            Log.w(TAG, "action $actionId on $key has no RemoteInput")
            replyResult(clientId, key, actionId, false,
                "That notification does not accept replies.")
            return
        }

        val intent = Intent().addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val bundle = Bundle()
        remoteInputs.forEach { bundle.putCharSequence(it.resultKey, text) }

        val androidxInputs = remoteInputs.map { ri ->
            RemoteInput.Builder(ri.resultKey)
                .setLabel(ri.label)
                .setChoices(ri.choices)
                .setAllowFreeFormInput(ri.allowFreeFormInput)
                .build()
        }.toTypedArray()

        RemoteInput.addResultsToIntent(androidxInputs, intent, bundle)

        // Before the intent, not after: the app can re-post the conversation with this
        // very text before `send` has returned, and a repost that arrives before we have
        // written this down is one the Mac would show as an incoming message.
        ourReplies.put(key, SelfMessage.SentReply(text, System.currentTimeMillis()))

        try {
            action.actionIntent.send(this, 0, intent)
            Log.i(TAG, "reply sent for $key")
            replyResult(clientId, key, actionId, true, null)
        } catch (e: PendingIntent.CanceledException) {
            // The only case where a gone notification really does mean a gone reply: the
            // app withdrew the intent itself. Worth saying out loud rather than letting
            // the message sit at "Sent" forever.
            Log.w(TAG, "reply PendingIntent was cancelled: ${e.message}")
            replyResult(clientId, key, actionId, false,
                "The app withdrew this conversation's reply.")
        }
    }

    // MARK: - SMS

    /** Switched on by the user *and* actually permitted. Both, or the Mac is not told. */
    private fun smsAvailable(): Boolean = settings.smsEnabled && sms.hasReadAccess()

    private fun startSmsMirror() {
        if (!settings.smsEnabled) {
            RuntimeStatusStore.updateSms(SmsAccessStatus.OFF, 0)
            return
        }
        if (!sms.hasReadAccess()) {
            RuntimeStatusStore.updateSms(SmsAccessStatus.NEEDS_PERMISSION, 0)
            return
        }
        val threads = sms.threads()
        RuntimeStatusStore.updateSms(SmsAccessStatus.READY, threads.size)
        Log.i(TAG, "mirroring ${threads.size} SMS conversation(s); " +
            "suppressing notifications from ${defaultSmsPackage ?: "no default SMS app"}")
        socket?.send(Messages.smsThreads(threads.map { it.toWire() }))
        // Idempotent: the mirror ignores a second call while it is already watching, so a
        // reconnect re-sends the thread list without stacking observers.
        sms.observe { fresh ->
            if (!authenticated) return@observe
            fresh.forEach { socket?.send(Messages.smsReceived(it.toWire())) }
        }
    }

    private fun sendSmsThread(threadId: Long, beforeId: Long?, limit: Int) {
        if (!smsAvailable()) return
        val capped = limit.coerceIn(1, 200)
        val messages = sms.messages(threadId, beforeId, capped)
        socket?.send(
            Messages.smsMessages(
                threadId,
                messages.map { it.toWire() },
                // Fewer than asked for means we reached the start of the conversation, so
                // the Mac can stop asking for more.
                complete = messages.size < capped
            )
        )
    }

    private fun sendSms(address: String, body: String, clientId: String) {
        if (!settings.smsEnabled) {
            socket?.send(Messages.smsSendResult(clientId, false,
                "SMS is switched off in Tennanova on this phone.", null))
            return
        }
        if (body.isBlank()) {
            socket?.send(Messages.smsSendResult(clientId, false, "Nothing to send.", null))
            return
        }
        sms.send(address, body) { ok, error ->
            socket?.send(Messages.smsSendResult(clientId, ok, error, null))
        }
    }

    private fun SmsThreadSummary.toWire() = SmsThreadWire(
        id, address, displayName, snippet, whenMs, unread
    )

    private fun SmsMessage.toWire() = SmsMessageWire(
        id, threadId, address, displayName, body, whenMs, outgoing, read
    )

    /** Tells the Mac which conversations it may offer a composer for. */
    private fun sendReplyableKeys() {
        if (!authenticated) return
        val keys = actionMap.keysWhere { actions ->
            actions.any { it.remoteInputs?.isNotEmpty() == true }
        }
        Log.i(TAG, "can reply to ${keys.size} conversation(s)")
        socket?.send(Messages.notifReplyKeys(keys))
    }

    /** Tells the Mac what actually happened, so a reply cannot silently vanish. */
    private fun replyResult(
        clientId: String?,
        key: String,
        actionId: Int,
        ok: Boolean,
        error: String?
    ) {
        socket?.send(Messages.notifReplyResult(clientId, key, actionId, ok, error))
    }

    private fun invokeAction(key: String, actionId: Int) {
        val action = actionMap.get(key)?.getOrNull(actionId) ?: return
        try {
            action.actionIntent.send()
        } catch (e: PendingIntent.CanceledException) {
            Log.w(TAG, "action PendingIntent was cancelled: ${e.message}")
        }
    }

    // MARK: - Icons

    private fun appLabel(pkg: String): String = try {
        val pm = packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        pkg
    }

    /** Renders the app icon to PNG once and returns its content hash. */
    private fun cacheIcon(pkg: String): String? = try {
        cacheAsset(drawableToPng(packageManager.getApplicationIcon(pkg), ICON_PX))
    } catch (e: Exception) {
        Log.w(TAG, "no icon for $pkg: ${e.message}")
        null
    }

    /**
     * The sender's photo, so the Mac shows a face rather than a generic app tile.
     * MessagingStyle carries the best one; the large icon is what most other apps set.
     */
    private fun cacheAvatar(
        n: Notification,
        messaging: NotificationCompat.MessagingStyle?
    ): String? = try {
        val personIcon = messaging?.messages
            ?.lastOrNull { it.person?.icon != null }?.person?.icon
        val drawable = personIcon?.loadDrawable(this) ?: n.getLargeIcon()?.loadDrawable(this)
        drawable?.let { cacheAsset(drawableToPng(it, AVATAR_PX)) }
    } catch (e: Exception) {
        Log.w(TAG, "no avatar for ${n.category}: ${e.message}")
        null
    }

    private fun cacheAsset(png: ByteArray): String =
        sha256Hex(png).also { assetBytes[it] = png }

    private fun drawableToPng(drawable: Drawable, size: Int): ByteArray {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            Bitmap.createScaledBitmap(drawable.bitmap, size, size, true)
        } else {
            Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { bmp ->
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, size, size)
                drawable.draw(canvas)
            }
        }
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
    }

    private fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it) }

    // MARK: - Clipboard out

    /** Called by the accessibility service or the explicit Share fallback. */
    fun onClipboardChanged(payload: ClipboardPayload) {
        if (!authenticated) return
        when (payload) {
            is ClipboardPayload.Text -> {
                ClipboardWriter.noteLocalClip(payload.fingerprint)
                socket?.send(Messages.clipUpdate(payload.value, clipSeq.incrementAndGet()))
                RuntimeStatusStore.transfer("Text sent to Mac")
            }
            is ClipboardPayload.ImageReference -> {
                if (!peerSupportsImages) {
                    RuntimeStatusStore.transfer(
                        "Image not sent",
                        "This Mac build doesn't accept images yet."
                    )
                    return
                }
                val job = imageJob.incrementAndGet()
                RuntimeStatusStore.transfer("Reading image…")
                val descriptor = runCatching {
                    contentResolver.openFileDescriptor(payload.uri, "r")
                        ?: error("Image content is unavailable")
                }.getOrElse {
                    RuntimeStatusStore.transfer("Image could not be read", it.message)
                    return
                }
                ImageTransfer.prepare(this, descriptor, payload.mime, payload.name) { result ->
                    if (job != imageJob.get()) return@prepare
                    result.onFailure {
                        RuntimeStatusStore.transfer("Image could not be sent", it.message)
                    }.onSuccess { image ->
                        if (!authenticated || !peerSupportsImages) return@onSuccess
                        val header = ClipImageHeader(
                            origin = "android",
                            seq = clipSeq.incrementAndGet(),
                            mime = image.mime,
                            bytes = image.bytes.size,
                            sha256 = image.sha256,
                            name = image.name
                        )
                        ClipboardWriter.noteLocalClip(payload.fingerprint, image.sha256)
                        if (socket?.sendBinary(Messages.clipImage(header), image.bytes) == true) {
                            RuntimeStatusStore.transfer("Image sent to Mac")
                        } else {
                            RuntimeStatusStore.transfer("Image send failed", "Mac disconnected")
                        }
                    }
                }
            }
        }
    }

    private fun setAuthenticated(value: Boolean) {
        authenticated = value
        if (!value) {
            peerSupportsImages = false
            peerSupportsFiles = false
            pendingBinary = null
            imageJob.incrementAndGet()
            RuntimeStatusStore.updatePeerCapabilities(false)
            // Paused, not failed: the partials stay on disk and the next connection
            // continues them.
            files?.sessionLost()
        }
    }

    /**
     * The Mac listing its own addresses, from `hello.ack` or `mac.hosts`. That list is
     * complete, so it replaces ours — which is what keeps dead addresses from piling up
     * as the Mac moves between a LAN and a hotspot.
     */
    private fun adoptReportedHosts(msg: JSONObject) {
        // Authoritative, like `hosts`: present means use it, absent means the Mac has no
        // USB tunnel right now. That is what lets plugging the phone in mid-session start
        // working, and unplugging it stop being tried, without anyone rescanning the QR.
        val reportedUsb = if (msg.has("usbPort")) msg.optInt("usbPort").takeIf { it in 1..65535 } else null
        if (reportedUsb != settings.usbPort) {
            settings.usbPort = reportedUsb
            Log.i(TAG, if (reportedUsb != null) "Mac USB tunnel up on $reportedUsb" else "Mac USB tunnel down")
        }

        // Merged rather than replaced, unlike `hosts`: a Mac whose relay control channel
        // is momentarily down omits these, and forgetting the relay at that exact moment
        // would throw away the one route that survives a network like this one.
        val hadRelay = settings.relayTarget
        settings.rememberRelay(msg.optString("relayHost").trim(), msg.optString("relayRoom").trim())
        if (settings.relayTarget != hadRelay) {
            settings.relayTarget?.let { (host, _) -> Log.i(TAG, "Mac relay available at $host") }
            // The bridge captures nothing; it reads the target per stream. It only has to
            // be running, which it is not if the phone paired before the Mac had a relay.
            if (settings.isPaired) relay.start()
        }

        val reported = PairingPayload.hostList(msg.optJSONArray("hosts"))
        if (reported.isEmpty()) return
        val port = msg.optInt("port", settings.port)
        if (port in 1..65535 && port != settings.port) settings.port = port
        settings.replaceHosts(reported)
        Log.i(TAG, "Mac reachable at ${reported.joinToString(", ")}")
    }

    companion object {
        private const val TAG = "TennaNova"
        private const val ICON_PX = 128
        /** Contact photos are the card's thumbnail, so they earn Retina pixels. */
        private const val AVATAR_PX = 256
        private const val MAX_ASSETS = 128
        /** Conversations whose last outgoing reply is still remembered. */
        private const val OWN_REPLY_MEMORY = 64
        /** One failed round is just a roaming Mac; a run of them is the network. */
        private const val ISOLATION_HINT_ROUNDS = 3
    }
}
