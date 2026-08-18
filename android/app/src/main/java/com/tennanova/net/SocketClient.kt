package com.tennanova.net

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tennanova.core.Proto
import com.tennanova.core.Settings
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.net.InetAddress
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal data class ConnectionEndpoint(
    val host: String,
    val port: Int,
    val isUsb: Boolean,
    /** Exact route learned from all-network NSD; null for persisted and USB endpoints. */
    val network: android.net.Network? = null
)

/**
 * USB first, then every address the Mac has told us about, best-known first. The list
 * exists because the Mac moves between networks — LAN, its own Internet Sharing, the far
 * side of a phone hotspot — and only the phone can find out which one is live today.
 */
internal fun buildEndpointCandidates(
    lanHosts: List<String>,
    lanPort: Int,
    usbPort: Int?,
    discovered: List<ConnectionEndpoint> = emptyList()
): List<ConnectionEndpoint> = buildList {
    if (usbPort != null) add(ConnectionEndpoint("127.0.0.1", usbPort, true))
    // A just-resolved address is both current and tied to the exact Android Network that
    // heard it, so it precedes addresses remembered from earlier networks.
    addAll(discovered.filterNot { it.isUsb })
    lanHosts.forEach { add(ConnectionEndpoint(it, lanPort, false)) }
    // Unknown-USB fallback, deliberately *last*.
    //
    // `usbPort` is only ever taught by the Mac, and the Mac only advertises it while the
    // tunnel is genuinely up — so a phone paired while unplugged knows nothing about USB
    // and, on a network with AP client isolation, has no reachable endpoint at all. It
    // cannot be told either: `mac.hosts` needs a session that can never be established.
    // Trying loopback costs one 1s timeout after every real address has already failed,
    // which is the only situation where it matters.
    if (usbPort == null && (lanHosts.isNotEmpty() || discovered.isNotEmpty())) {
        add(ConnectionEndpoint("127.0.0.1", lanPort, true))
    }
}.distinctBy { Triple(it.host, it.port, it.network?.networkHandle) }

/** TLS-pinned, single-flight WebSocket client. */
internal class SocketClient(
    private val context: Context,
    private val settings: Settings,
    private val onMessage: (JSONObject) -> Unit,
    private val onBinary: (ByteArray) -> Unit,
    private val onStateChange: (State) -> Unit,
    /** Fresh NSD results, including the exact route on which each Mac was found. */
    private val discoveredEndpoints: () -> List<ConnectionEndpoint> = { emptyList() },
    /**
     * Every known address failed without a single connection this round. The caller uses
     * this to fall back to probing the subnet — the Mac may be somewhere new entirely.
     */
    private val onEndpointsExhausted: () -> Unit = {}
) {
    enum class State { DISCONNECTED, CONNECTING, CONNECTED, PIN_MISMATCH, AUTH_FAILED, UNPAIRED }

    private val shouldRun = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lifecycleLock = Any()
    private val sendLock = Any()
    private var ws: WebSocket? = null
    private var client: OkHttpClient? = null
    private var reconnect: Runnable? = null
    private var generation = 0L
    /**
     * Index of the endpoint currently being attempted within [generation].
     *
     * Currency is tracked by (generation, index) rather than by WebSocket identity because
     * okhttp can deliver `onFailure` before `newWebSocket` has even returned — which an
     * instantly-refused loopback endpoint does routinely. Identity matching then saw a
     * callback for a socket it had not recorded yet, discarded it, and left the client
     * wedged in CONNECTING with no reconnect pending and nothing to kick it.
     */
    private var attempt = 0
    /**
     * Fires when an attempt stops making progress without okhttp ever calling back.
     *
     * `connectTimeout` bounds only the TCP connect, and `readTimeout` is 0 because a live
     * session is meant to idle indefinitely. Between those two there is a gap: a peer that
     * accepts TCP and then stalls the TLS handshake or the HTTP-101 upgrade produces
     * neither `onOpen` nor `onFailure`, and the client sits in CONNECTING forever. A
     * half-alive `adb reverse` tunnel and a [SubnetScanner] hit — which only proves a port
     * is open — both do exactly that.
     *
     * okhttp's own `callTimeout` is not usable here: it bounds the whole call, and for a
     * WebSocket the call lasts as long as the session, so it would tear down healthy
     * connections.
     */
    private var watchdog: Runnable? = null
    private var backoffMs = 1_000L
    // Written from okhttp's callback threads, read from the main thread by retryNow and
    // by the listener before it moves endpoints.
    @Volatile
    private var state = State.DISCONNECTED
    private var fatal = false

    fun start() {
        if (shouldRun.getAndSet(true)) return
        synchronized(lifecycleLock) {
            fatal = false
            backoffMs = 1_000L
        }
        connect()
    }

    fun stop() {
        shouldRun.set(false)
        val old: WebSocket?
        val oldClient: OkHttpClient?
        synchronized(lifecycleLock) {
            generation++
            reconnect?.let(mainHandler::removeCallbacks)
            reconnect = null
            disarmWatchdogLocked()
            old = ws
            ws = null
            oldClient = client
            client = null
        }
        old?.close(1000, "stopping")
        dispose(oldClient)
        setState(State.DISCONNECTED)
    }

    /**
     * The session got past `hello`, so the endpoint is good for more than a TCP handshake.
     *
     * Resetting the backoff on open instead meant a Mac that accepts the socket and then
     * rejects the handshake was retried once a second forever: the open reset the delay,
     * the rejection closed the socket, and nothing ever grew it.
     */
    fun sessionAuthenticated() {
        synchronized(lifecycleLock) {
            backoffMs = 1_000L
            disarmWatchdogLocked()
        }
    }

    /**
     * The Mac refused our credentials. Terminal in the same way a pin mismatch is — the
     * token is wrong and reconnecting cannot make it right — so stop and let the UI say so.
     */
    fun failAuthentication() {
        val old: WebSocket?
        val oldClient: OkHttpClient?
        synchronized(lifecycleLock) {
            fatal = true
            generation++
            reconnect?.let(mainHandler::removeCallbacks)
            reconnect = null
            disarmWatchdogLocked()
            old = ws
            ws = null
            oldClient = client
            client = null
        }
        shouldRun.set(false)
        old?.close(1000, "authentication rejected")
        dispose(oldClient)
        // Deliberately not stop(), which would end on DISCONNECTED and bury the reason.
        setState(State.AUTH_FAILED)
    }

    fun send(json: JSONObject): Boolean = synchronized(sendLock) {
        ws?.send(json.toString()) ?: false
    }

    /** Queues a JSON header and binary body without allowing another pair to interleave. */
    fun sendBinary(header: JSONObject, bytes: ByteArray): Boolean = synchronized(sendLock) {
        val socket = ws ?: return@synchronized false
        socket.send(header.toString()) && socket.send(bytes.toByteString())
    }

    val isConnected: Boolean get() = state == State.CONNECTED

    private fun connect() {
        if (!shouldRun.get()) return
        val id: Long
        synchronized(lifecycleLock) {
            if (fatal) return
            reconnect?.let(mainHandler::removeCallbacks)
            reconnect = null
            id = ++generation
        }

        val spki = settings.spki
        val endpoints = buildEndpointCandidates(
            settings.hosts,
            settings.port,
            settings.usbPort,
            discoveredEndpoints()
        )
        if (endpoints.isEmpty() || spki == null) {
            setState(State.UNPAIRED)
            return
        }
        setState(State.CONNECTING)

        connectEndpoint(id, endpoints, 0, spki, pinMismatchSeen = false)
    }

    private fun connectEndpoint(
        id: Long,
        endpoints: List<ConnectionEndpoint>,
        index: Int,
        spki: String,
        pinMismatchSeen: Boolean
    ) {
        if (!shouldRun.get() || index !in endpoints.indices) return
        val endpoint = endpoints[index]
        synchronized(lifecycleLock) {
            if (generation != id || !shouldRun.get()) return
            attempt = index
        }

        try {
            val trustManager = PinnedTrustManager(spki)
            val builder = OkHttpClient.Builder()
                .sslSocketFactory(PinnedTrustManager.socketFactory(trustManager), trustManager)
                .hostnameVerifier { _, _ -> true }
                .pingInterval(20, TimeUnit.SECONDS)
                // Short on purpose: this list can be six addresses long and only one of
                // them is real. A 10s timeout each meant a minute before backoff started.
                .connectTimeout(
                    if (endpoint.isUsb) USB_CONNECT_TIMEOUT_MS else LAN_CONNECT_TIMEOUT_MS,
                    TimeUnit.MILLISECONDS
                )
                .readTimeout(0, TimeUnit.MILLISECONDS)

            // Without this, a Mac on its own Internet Sharing network is unreachable: the
            // phone's Wi-Fi has no internet, so Android keeps cellular as the default and
            // routes every unbound socket there.
            if (!endpoint.isUsb) {
                (endpoint.network ?: NetworkRoutes.networkFor(context, endpoint.host))?.let { network ->
                    builder.socketFactory(network.socketFactory)
                    builder.dns(object : Dns {
                        override fun lookup(hostname: String): List<InetAddress> =
                            network.getAllByName(hostname).toList()
                    })
                }
            }
            val http = builder.build()
            client = http
            val urlHost = if (':' in endpoint.host && !endpoint.host.startsWith('['))
                "[${endpoint.host}]" else endpoint.host
            val request = Request.Builder().url("wss://$urlHost:${endpoint.port}/").build()

            // Outside the listener because the stall watchdog reads it too.
            val opened = AtomicBoolean(false)

            /** The tail every abandoned attempt shares, whether okhttp reported it or not. */
            fun abandon(socket: WebSocket?) {
                socket?.cancel()
                dispose(http)
                if (!opened.get() && index + 1 < endpoints.size) {
                    connectEndpoint(id, endpoints, index + 1, spki, pinMismatchSeen)
                    return
                }
                setState(State.DISCONNECTED)
                if (!opened.get()) onEndpointsExhausted()
                scheduleReconnect(id)
            }

            val socket = http.newWebSocket(request, object : WebSocketListener() {

                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (!isCurrent(id, index)) return
                    opened.set(true)
                    Log.i(TAG, "connected over ${if (endpoint.isUsb) "USB" else "LAN"} " +
                        "to ${endpoint.host}:${endpoint.port}")
                    // The address that just worked leads the list next time, so a phone
                    // that stays on one hotspot stops paying for the stale entries.
                    if (!endpoint.isUsb) settings.promoteHost(endpoint.host)
                    setState(State.CONNECTED)
                    // A Mac that accepts the socket and then never acks `hello` leaves us
                    // in AUTHENTICATING with nothing to time it out. Cleared by
                    // sessionAuthenticated().
                    armWatchdog(id, index, AUTH_TIMEOUT_MS) {
                        Log.w(TAG, "no hello.ack from ${endpoint.host}:${endpoint.port}; giving up")
                        abandon(webSocket)
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (!isCurrent(id, index)) return
                    try {
                        val obj = JSONObject(text)
                        if (obj.optInt("v") != Proto.VERSION) {
                            Log.w(TAG, "ignoring message with version ${obj.optInt("v")}")
                            return
                        }
                        onMessage(obj)
                    } catch (e: Exception) {
                        Log.w(TAG, "bad message: ${e.message}")
                    }
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    if (isCurrent(id, index)) onBinary(bytes.toByteArray())
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    val mismatch = generateSequence(t as Throwable?) { it.cause }
                        .any { it is PinnedTrustManager.PinMismatch }
                    // Claiming retires this attempt, so the registration below stands down
                    // if it lost the race, and no second callback can act on it either.
                    if (!claimAttempt(id, index)) return
                    if (!opened.get() && index + 1 < endpoints.size) {
                        Log.i(TAG, "${if (endpoint.isUsb) "USB" else "LAN"} endpoint failed; " +
                            "trying ${if (endpoints[index + 1].isUsb) "USB" else "LAN"}")
                        webSocket.cancel()
                        dispose(http)
                        connectEndpoint(id, endpoints, index + 1, spki, pinMismatchSeen || mismatch)
                        return
                    }
                    webSocket.cancel()
                    dispose(http)
                    if (mismatch || pinMismatchSeen) {
                        Log.e(TAG, "TLS pin mismatch on every available endpoint — re-pair required")
                        synchronized(lifecycleLock) { fatal = true }
                        setState(State.PIN_MISMATCH)
                        return
                    }
                    Log.w(TAG, "connection failed: ${t.message}")
                    setState(State.DISCONNECTED)
                    // Nothing answered anywhere we know about. The Mac may have moved to
                    // an address that was never in the list.
                    if (!opened.get()) onEndpointsExhausted()
                    scheduleReconnect(id)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    if (!claimAttempt(id, index)) return
                    Log.i(TAG, "closed: $code $reason")
                    dispose(http)
                    setState(State.DISCONNECTED)
                    scheduleReconnect(id)
                }
            })
            synchronized(lifecycleLock) {
                if (generation == id && attempt == index && shouldRun.get()) ws = socket
                else socket.cancel()
            }
            // Only if okhttp has not already opened the socket — it can call back before
            // `newWebSocket` returns, and onOpen has armed the authentication timer by then.
            if (!opened.get()) {
                val connectBudget =
                    (if (endpoint.isUsb) USB_CONNECT_TIMEOUT_MS else LAN_CONNECT_TIMEOUT_MS) +
                        HANDSHAKE_GRACE_MS
                armWatchdog(id, index, connectBudget) {
                    Log.w(TAG, "${endpoint.host}:${endpoint.port} stalled before opening; moving on")
                    abandon(socket)
                }
            }
        } catch (e: Exception) {
            if (!claimAttempt(id, index)) return
            val failedClient = synchronized(lifecycleLock) {
                client.also { client = null }
            }
            dispose(failedClient)
            if (index + 1 < endpoints.size) {
                connectEndpoint(id, endpoints, index + 1, spki, pinMismatchSeen)
            } else {
                Log.e(TAG, "could not create socket: ${e.message}")
                setState(State.DISCONNECTED)
                onEndpointsExhausted()
                scheduleReconnect(id)
            }
        }
    }

    private fun scheduleReconnect(failedGeneration: Long) {
        if (!shouldRun.get()) return
        val task: Runnable
        synchronized(lifecycleLock) {
            if (fatal || failedGeneration != generation || reconnect != null) return
            val delay = backoffMs
            backoffMs = (backoffMs * 2).coerceAtMost(30_000L)
            task = Runnable {
                synchronized(lifecycleLock) { reconnect = null }
                connect()
            }
            reconnect = task
            mainHandler.postDelayed(task, delay)
        }
    }

    /**
     * Drops whatever is in flight and reconnects immediately.
     *
     * Deliberately refuses to disturb a live socket. This cancels rather than closes, which
     * the Mac sees as a connection reset — and with Bonjour resolving continuously, a
     * healthy session used to be torn down every few seconds. A socket that is connected but
     * secretly dead is caught by the 20s ping instead.
     */
    fun retryNow() {
        if (!shouldRun.get() || state == State.CONNECTED) return
        val old: WebSocket?
        val oldClient: OkHttpClient?
        synchronized(lifecycleLock) {
            if (fatal) return
            backoffMs = 1_000L
            generation++
            reconnect?.let(mainHandler::removeCallbacks)
            reconnect = null
            old = ws
            ws = null
            oldClient = client
            client = null
        }
        old?.cancel()
        dispose(oldClient)
        connect()
    }

    private fun isCurrent(id: Long, index: Int): Boolean =
        synchronized(lifecycleLock) { generation == id && attempt == index && shouldRun.get() }

    /**
     * Atomically retires endpoint [index] of [id] and moves past it, so exactly one
     * callback can decide what happens next even when several fire for the same attempt.
     */
    private fun claimAttempt(id: Long, index: Int): Boolean = synchronized(lifecycleLock) {
        if (generation != id || attempt != index || !shouldRun.get()) return false
        attempt = index + 1
        ws = null
        // Whatever happens next re-arms if it needs to. Disarming here means every exit
        // from an attempt — real callback or watchdog — leaves no timer behind.
        disarmWatchdogLocked()
        true
    }

    /** Caller must hold [lifecycleLock]. */
    private fun disarmWatchdogLocked() {
        watchdog?.let(mainHandler::removeCallbacks)
        watchdog = null
    }

    /**
     * Arms a stall timer for endpoint [index] of [id]. [onStall] runs on the main thread
     * and only if the attempt is still the current one.
     */
    private fun armWatchdog(id: Long, index: Int, delayMs: Long, onStall: () -> Unit) {
        val task = Runnable { if (claimAttempt(id, index)) onStall() }
        synchronized(lifecycleLock) {
            if (generation != id || attempt != index || !shouldRun.get()) return
            disarmWatchdogLocked()
            watchdog = task
        }
        mainHandler.postDelayed(task, delayMs)
    }

    private fun setState(value: State) {
        if (state == value) return
        state = value
        onStateChange(value)
    }

    private fun dispose(http: OkHttpClient?) {
        http ?: return
        http.connectionPool.evictAll()
        http.dispatcher.executorService.shutdown()
    }

    private companion object {
        const val TAG = "TennaNova"
        const val LAN_CONNECT_TIMEOUT_MS = 3_000L
        const val USB_CONNECT_TIMEOUT_MS = 1_000L
        /** Headroom over the TCP connect for the TLS handshake and the HTTP-101 upgrade. */
        const val HANDSHAKE_GRACE_MS = 5_000L
        /** From an open socket to `hello.ack`. Generous: the Mac replays notifications first. */
        const val AUTH_TIMEOUT_MS = 10_000L
    }
}
