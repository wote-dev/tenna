package com.tennanova.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Makes the Mac reachable from a network that drops traffic between its own clients.
 *
 * The shape mirrors the Mac's `RelayBridge`, and for the same reason: this file does not
 * speak the Tennanova protocol at all. It listens on loopback, and anything that
 * connects there is pumped over a WebSocket to the relay and out to the Mac's listener.
 * [SocketClient] then connects to that loopback port with the ordinary
 * [PinnedTrustManager], so the TLS session, the certificate pin and the pairing token
 * are negotiated end to end with the Mac, straight through a relay that sees ciphertext
 * and nothing else.
 *
 * That layering is the whole security argument for adding a server to a peer-to-peer
 * app: the relay is infrastructure, never a party to the session.
 */
internal class RelayBridge(
    private val context: Context,
    private val relayInfo: () -> RelayTarget?
) {

    data class RelayTarget(val host: String, val room: String)

    private val running = AtomicBoolean(false)
    private val lock = Any()
    private var server: ServerSocket? = null
    private var acceptor: Thread? = null

    /** Loopback port [SocketClient] should aim at, or null while the bridge is down. */
    @Volatile
    var localPort: Int? = null
        private set

    fun start() {
        if (relayInfo() == null) return
        if (!running.compareAndSet(false, true)) return
        val socket = runCatching {
            ServerSocket(0, BACKLOG, InetAddress.getLoopbackAddress())
        }.getOrElse {
            Log.w(TAG, "relay bridge could not bind loopback: ${it.message}")
            running.set(false)
            return
        }
        synchronized(lock) { server = socket }
        localPort = socket.localPort
        val thread = Thread({ acceptLoop(socket) }, "tenna-relay-accept")
        thread.isDaemon = true
        synchronized(lock) { acceptor = thread }
        thread.start()
        Log.i(TAG, "relay bridge listening on 127.0.0.1:${socket.localPort}")
    }

    fun stop() {
        if (!running.getAndSet(false)) return
        localPort = null
        val socket: ServerSocket?
        synchronized(lock) {
            socket = server
            server = null
            acceptor = null
        }
        runCatching { socket?.close() }
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (running.get() && !socket.isClosed) {
            val local = runCatching { socket.accept() }.getOrElse {
                if (running.get()) Log.w(TAG, "relay accept failed: ${it.message}")
                return
            }
            val target = relayInfo()
            if (target == null) {
                runCatching { local.close() }
                continue
            }
            Thread({ bridge(local, target) }, "tenna-relay-stream").apply {
                isDaemon = true
                start()
            }
        }
    }

    private fun bridge(local: Socket, target: RelayTarget) {
        val url = RelayConfig.joinUrl(target.host, target.room)
        if (url == null) {
            Log.w(TAG, "relay target is not usable: ${target.host}")
            runCatching { local.close() }
            return
        }

        // Deliberately the default trust manager: this outer hop authenticates the
        // *relay*, which holds an ordinary CA certificate. The Mac is authenticated by
        // the pinned session running inside this pipe, not here.
        val builder = OkHttpClient.Builder()
            .connectTimeout(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
        internetNetwork()?.let { builder.socketFactory(it.socketFactory) }
        val http = builder.build()

        val closed = AtomicBoolean(false)
        val output = runCatching { local.getOutputStream() }.getOrNull()
        if (output == null) {
            runCatching { local.close() }
            return
        }

        lateinit var socket: WebSocket

        fun shutdown(reason: String?) {
            if (!closed.compareAndSet(false, true)) return
            if (reason != null) Log.i(TAG, "relay stream ended: $reason")
            runCatching { socket.cancel() }
            runCatching { local.close() }
            http.connectionPool.evictAll()
            http.dispatcher.executorService.shutdown()
        }

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.i(TAG, "relay stream open to ${target.host}")
                // Pumping the local side from its own thread, because reading a socket
                // is blocking and okhttp's callback thread must stay free to deliver
                // what the Mac is sending back.
                Thread({ pumpToRelay(local.getInputStream(), webSocket, ::shutdown) },
                    "tenna-relay-up").apply { isDaemon = true }.start()
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                // Writing blocks this thread on purpose: that is the backpressure that
                // stops a fast Mac from queueing a whole clipboard image in memory
                // while the phone's loopback reader is behind.
                try {
                    output.write(bytes.toByteArray())
                    output.flush()
                } catch (e: IOException) {
                    shutdown("local write failed: ${e.message}")
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                shutdown("relay failure: ${t.message}")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                shutdown("relay closed: $code $reason")
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                shutdown("relay closing: $code $reason")
            }
        }

        socket = http.newWebSocket(Request.Builder().url(url).build(), listener)
    }

    private fun pumpToRelay(input: InputStream, socket: WebSocket, shutdown: (String?) -> Unit) {
        val buffer = ByteArray(CHUNK)
        try {
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                if (!socket.send(buffer.copyOf(read).toByteString())) break
                // okhttp queues sends without bound. On slow cellular an unthrottled
                // reader would turn a 25 MB image into 25 MB of heap.
                var waited = 0L
                while (socket.queueSize() > MAX_QUEUE_BYTES && waited < QUEUE_WAIT_LIMIT_MS) {
                    Thread.sleep(QUEUE_POLL_MS)
                    waited += QUEUE_POLL_MS
                }
            }
            shutdown(null)
        } catch (e: Exception) {
            shutdown("local read failed: ${e.message}")
        }
    }

    /**
     * The relay is on the internet, so this picks a network that actually has it —
     * which on a phone that is on Wi-Fi with no upstream is not the one carrying the
     * LAN attempts.
     */
    @Suppress("DEPRECATION") // allNetworks has no non-deprecated equivalent.
    private fun internetNetwork(): Network? {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return null
        return runCatching {
            fun usable(network: Network?): Boolean {
                val caps = network?.let { manager.getNetworkCapabilities(it) } ?: return false
                return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            }
            manager.activeNetwork?.takeIf { usable(it) }
                ?: manager.allNetworks.firstOrNull { usable(it) }
        }.getOrNull()
    }

    private companion object {
        const val TAG = "TennaNova"
        const val BACKLOG = 4
        const val CHUNK = 32 * 1024
        const val CONNECT_TIMEOUT_MS = 10_000L
        const val MAX_QUEUE_BYTES = 2L * 1024 * 1024
        const val QUEUE_POLL_MS = 20L
        const val QUEUE_WAIT_LIMIT_MS = 30_000L
    }
}
