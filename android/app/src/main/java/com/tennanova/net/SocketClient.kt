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
import javax.net.ssl.SSLHandshakeException

internal data class ConnectionEndpoint(val host: String, val port: Int, val isUsb: Boolean)

/**
 * USB first, then every address the Mac has told us about, best-known first. The list
 * exists because the Mac moves between networks — LAN, its own Internet Sharing, the far
 * side of a phone hotspot — and only the phone can find out which one is live today.
 */
internal fun buildEndpointCandidates(
    lanHosts: List<String>,
    lanPort: Int,
    usbPort: Int?
): List<ConnectionEndpoint> = buildList {
    if (usbPort != null) add(ConnectionEndpoint("127.0.0.1", usbPort, true))
    lanHosts.forEach { add(ConnectionEndpoint(it, lanPort, false)) }
}.distinctBy { it.host to it.port }

/** TLS-pinned, single-flight WebSocket client. */
class SocketClient(
    private val context: Context,
    private val settings: Settings,
    private val onMessage: (JSONObject) -> Unit,
    private val onBinary: (ByteArray) -> Unit,
    private val onStateChange: (State) -> Unit,
    /**
     * Every known address failed without a single connection this round. The caller uses
     * this to fall back to probing the subnet — the Mac may be somewhere new entirely.
     */
    private val onEndpointsExhausted: () -> Unit = {}
) {
    enum class State { DISCONNECTED, CONNECTING, CONNECTED, PIN_MISMATCH, UNPAIRED }

    private val shouldRun = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lifecycleLock = Any()
    private val sendLock = Any()
    private var ws: WebSocket? = null
    private var client: OkHttpClient? = null
    private var reconnect: Runnable? = null
    private var generation = 0L
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
        synchronized(lifecycleLock) {
            generation++
            reconnect?.let(mainHandler::removeCallbacks)
            reconnect = null
            old = ws
            ws = null
        }
        old?.close(1000, "stopping")
        client?.dispatcher?.executorService?.shutdown()
        client = null
        setState(State.DISCONNECTED)
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
        val endpoints =
            buildEndpointCandidates(settings.hosts, settings.port, settings.usbPort)
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
                NetworkRoutes.networkFor(context, endpoint.host)?.let { network ->
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

            val socket = http.newWebSocket(request, object : WebSocketListener() {
                private var opened = false

                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (!isCurrent(id, webSocket)) return
                    opened = true
                    Log.i(TAG, "connected over ${if (endpoint.isUsb) "USB" else "LAN"} " +
                        "to ${endpoint.host}:${endpoint.port}")
                    synchronized(lifecycleLock) { backoffMs = 1_000L }
                    // The address that just worked leads the list next time, so a phone
                    // that stays on one hotspot stops paying for the stale entries.
                    if (!endpoint.isUsb) settings.promoteHost(endpoint.host)
                    setState(State.CONNECTED)
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (!isCurrent(id, webSocket)) return
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
                    if (isCurrent(id, webSocket)) onBinary(bytes.toByteArray())
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (!isCurrent(id, webSocket)) return
                    val mismatch = generateSequence(t as Throwable?) { it.cause }
                        .any { it is PinnedTrustManager.PinMismatch }
                    if (!opened && index + 1 < endpoints.size) {
                        Log.i(TAG, "${if (endpoint.isUsb) "USB" else "LAN"} endpoint failed; " +
                            "trying ${if (endpoints[index + 1].isUsb) "USB" else "LAN"}")
                        synchronized(lifecycleLock) {
                            if (generation == id && ws === webSocket) ws = null
                        }
                        webSocket.cancel()
                        http.dispatcher.executorService.shutdown()
                        http.connectionPool.evictAll()
                        connectEndpoint(id, endpoints, index + 1, spki, pinMismatchSeen || mismatch)
                        return
                    }
                    if (mismatch || pinMismatchSeen || t is SSLHandshakeException && mismatch) {
                        Log.e(TAG, "TLS pin mismatch on every available endpoint — re-pair required")
                        synchronized(lifecycleLock) { fatal = true }
                        setState(State.PIN_MISMATCH)
                        return
                    }
                    Log.w(TAG, "connection failed: ${t.message}")
                    setState(State.DISCONNECTED)
                    // Nothing answered anywhere we know about. The Mac may have moved to
                    // an address that was never in the list.
                    if (!opened) onEndpointsExhausted()
                    scheduleReconnect(id)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    if (!isCurrent(id, webSocket)) return
                    Log.i(TAG, "closed: $code $reason")
                    setState(State.DISCONNECTED)
                    scheduleReconnect(id)
                }
            })
            synchronized(lifecycleLock) {
                if (generation == id && shouldRun.get()) ws = socket else socket.cancel()
            }
        } catch (e: Exception) {
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
        synchronized(lifecycleLock) {
            if (fatal) return
            backoffMs = 1_000L
            generation++
            reconnect?.let(mainHandler::removeCallbacks)
            reconnect = null
            old = ws
            ws = null
        }
        old?.cancel()
        connect()
    }

    private fun isCurrent(id: Long, socket: WebSocket): Boolean =
        synchronized(lifecycleLock) { generation == id && ws === socket && shouldRun.get() }

    private fun setState(value: State) {
        if (state == value) return
        state = value
        onStateChange(value)
    }

    private companion object {
        const val TAG = "TennaNova"
        const val LAN_CONNECT_TIMEOUT_MS = 3_000L
        const val USB_CONNECT_TIMEOUT_MS = 1_000L
    }
}
