package com.tennanova.notifications

import android.app.Notification
import android.app.PendingIntent
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
import com.tennanova.net.SocketClient
import com.tennanova.net.MacDiscovery
import com.tennanova.net.SubnetScanner
import org.json.JSONObject
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
    private var socket: SocketClient? = null
    private var authenticated = false
    private var peerSupportsImages = false
    private var pendingImage: ClipImageHeader? = null
    private var networkCallbackRegistered = false
    private var allNetworksCallbackRegistered = false
    private var discoveredEndpoint: Pair<String, Int>? = null
    /** Consecutive rounds in which every known address failed. Reset by `hello.ack`. */
    private var exhaustedRounds = 0

    /** Reply/action plumbing for notifications currently on screen, keyed by SBN key. */
    private val actionMap = HashMap<String, List<Notification.Action>>()

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
        discovery = MacDiscovery(this) { host, port ->
            discoveredEndpoint = host to port
            adoptDiscoveredEndpointIfSafe()
        }
        RuntimeStatusStore.attach(this)
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
        startSocket()
        if (settings.isPaired) discovery.start()
    }

    override fun onListenerDisconnected() {
        Log.w(TAG, "listener disconnected — requesting rebind")
        setAuthenticated(false)
        socket?.stop()
        socket = null
        // Without this the service can stay dead until reboot.
        requestRebind(android.content.ComponentName(this, TennaNotificationListener::class.java))
    }

    override fun onDestroy() {
        socket?.stop()
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
            onStateChange = { state ->
                when (state) {
                    SocketClient.State.CONNECTED -> {
                        setAuthenticated(false)
                        RuntimeStatusStore.updateConnection(ConnectionStatus.AUTHENTICATING)
                        sendHello()
                    }
                    SocketClient.State.CONNECTING -> {
                        setAuthenticated(false)
                        RuntimeStatusStore.updateConnection(ConnectionStatus.CONNECTING)
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
                        adoptDiscoveredEndpointIfSafe()
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
        if (discoveredEndpoint != null && exhaustedRounds >= ISOLATION_HINT_ROUNDS) {
            RuntimeStatusStore.updateConnection(
                ConnectionStatus.DISCONNECTED,
                "Your Mac is on this network but the connection is being blocked — " +
                    "many routers block device-to-device traffic. Connect the phone by USB."
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
        // A different Mac may push different content; don't suppress its first write.
        ClipboardWriter.reset()
        if (settings.isPaired) discovery.start() else discovery.stop()
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
                deviceToken = settings.deviceToken
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
                adoptReportedHosts(msg)
                peerSupportsImages = msg.optJSONArray("capabilities")?.let { array ->
                    (0 until array.length()).any {
                        array.optString(it) == Proto.IMAGE_CLIPBOARD_CAPABILITY
                    }
                } == true
                RuntimeStatusStore.updatePeerCapabilities(peerSupportsImages)
                exhaustedRounds = 0
                socket?.sessionAuthenticated()
                setAuthenticated(true)
                RuntimeStatusStore.updateConnection(ConnectionStatus.CONNECTED)
                // Populate the Mac and rebuild action mappings only after authentication.
                activeNotifications?.forEach { handlePosted(it, resync = true) }
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
                sendReply(key, actionId, text)
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
                if (body.isNotEmpty()) {
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
                    pendingImage != null) {
                    RuntimeStatusStore.transfer("Image rejected", "Invalid image metadata")
                    pendingImage = null
                } else {
                    pendingImage = header
                }
            }
        }
    }

    private fun handleBinary(bytes: ByteArray) {
        val header = pendingImage
        pendingImage = null
        if (!authenticated || header == null || bytes.size != header.bytes ||
            ImageTransfer.sha256(bytes) != header.sha256) {
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

    // MARK: - Notifications out

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        handlePosted(sbn, resync = false)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        actionMap.remove(sbn.key)
        if (authenticated) socket?.send(Messages.notifRemoved(sbn.key))
    }

    private fun handlePosted(sbn: StatusBarNotification, resync: Boolean) {
        if (!authenticated) return
        if (!shouldMirror(sbn)) return

        val n = sbn.notification
        val extras: Bundle = n.extras

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val body = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()
            ?: extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
                ?.joinToString("\n")

        val appLabel = appLabel(sbn.packageName)
        val iconHash = cacheIcon(sbn.packageName)
        val messaging = messagingStyle(n)

        val actions = mutableListOf<NotifAction>()
        n.actions?.forEachIndexed { index, action ->
            val isReply = action.remoteInputs?.isNotEmpty() == true
            actions.add(NotifAction(index, action.title?.toString() ?: "Action", isReply))
        }
        n.actions?.let { actionMap[sbn.key] = it.toList() }

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

    private fun messagingStyle(n: Notification): NotificationCompat.MessagingStyle? =
        runCatching {
            NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)
        }.getOrNull()

    private fun lastSender(style: NotificationCompat.MessagingStyle): String? =
        style.messages.lastOrNull()?.person?.name?.toString()?.takeIf { it.isNotBlank() }

    /**
     * Filters that keep the Mac quiet and duplicate-free.
     * Group summaries are the single biggest source of duplicates.
     */
    private fun shouldMirror(sbn: StatusBarNotification): Boolean {
        val n = sbn.notification
        if (sbn.packageName == packageName) return false
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return false
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return false
        if (sbn.packageName in settings.mutedPackages) return false

        val extras = n.extras
        val hasText = extras.getCharSequence(Notification.EXTRA_TEXT) != null ||
                extras.getCharSequence(Notification.EXTRA_BIG_TEXT) != null ||
                extras.getCharSequence(Notification.EXTRA_TITLE) != null
        return hasText
    }

    // MARK: - Replies

    private fun sendReply(key: String, actionId: Int, text: String) {
        val action = actionMap[key]?.getOrNull(actionId) ?: run {
            Log.w(TAG, "no action $actionId for $key")
            return
        }
        val remoteInputs = action.remoteInputs ?: run {
            Log.w(TAG, "action $actionId on $key has no RemoteInput")
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

        try {
            action.actionIntent.send(this, 0, intent)
            Log.i(TAG, "reply sent for $key")
        } catch (e: PendingIntent.CanceledException) {
            Log.w(TAG, "reply PendingIntent was cancelled: ${e.message}")
        }
    }

    private fun invokeAction(key: String, actionId: Int) {
        val action = actionMap[key]?.getOrNull(actionId) ?: return
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
            pendingImage = null
            imageJob.incrementAndGet()
            RuntimeStatusStore.updatePeerCapabilities(false)
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

        val reported = PairingPayload.hostList(msg.optJSONArray("hosts"))
        if (reported.isEmpty()) return
        val port = msg.optInt("port", settings.port)
        if (port in 1..65535 && port != settings.port) settings.port = port
        settings.replaceHosts(reported)
        Log.i(TAG, "Mac reachable at ${reported.joinToString(", ")}")
    }

    /** NSD updates only the LAN endpoint; the optional USB loopback endpoint is independent. */
    private fun adoptDiscoveredEndpointIfSafe() {
        val (host, port) = discoveredEndpoint ?: return
        val current = settings.host ?: return
        if (!settings.isPaired || authenticated) return
        // Bonjour keeps resolving while a session is alive. Switching endpoints under a
        // live socket means cancelling it, and the phone would then rediscover and do it
        // all over again — so only move while genuinely offline.
        if (socket?.isConnected == true) return
        if (current == host && settings.port == port) return
        Log.i(TAG, "paired Mac rediscovered at $host:$port")
        // Remembered, not substituted: mDNS finds the Mac on one interface, and the
        // others in the list may be the ones that actually work.
        settings.port = port
        settings.promoteHost(host)
        socket?.retryNow()
    }

    companion object {
        private const val TAG = "TennaNova"
        private const val ICON_PX = 128
        /** Contact photos are the card's thumbnail, so they earn Retina pixels. */
        private const val AVATAR_PX = 256
        private const val MAX_ASSETS = 128
        /** One failed round is just a roaming Mac; a run of them is the network. */
        private const val ISOLATION_HINT_ROUNDS = 3
    }
}
