package com.tennanova.net

import android.content.Context
import android.net.Network
import android.os.SystemClock
import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Last resort: probe the phone's directly-connected subnets for the Mac's listener.
 *
 * This is the only thing that finds a Mac which has just joined the phone's hotspot.
 * mDNS cannot — `NsdManager` runs on the phone's default network, which stays cellular
 * while tethering, and the tether interface has no [Network] to bind to. The Mac's
 * address there is one nobody has ever seen, so nothing remembered helps either.
 *
 * Probing proves nothing by itself, which is what makes it safe: a hit is an open TCP
 * port and no more. `PinnedTrustManager` still has to accept the certificate before a
 * single byte of session data moves.
 */
object SubnetScanner {

    private const val TAG = "TennaNova"
    private const val PROBE_TIMEOUT_MS = 400
    private const val THREADS = 64
    private const val MAX_ADDRESSES = 640
    /** /23 is 510 hosts. Anything wider is a corporate LAN, not a hotspot. */
    private const val MIN_PREFIX = 23
    private const val MIN_INTERVAL_MS = 30_000L

    /** Carrier interfaces: a probe there is wasted battery and someone else's subnet. */
    private val SKIPPED_INTERFACES =
        listOf("rmnet", "ccmni", "wwan", "pdp", "tun", "ppp", "dummy")

    private val running = AtomicBoolean(false)

    @Volatile
    private var lastRunAt = 0L

    /** At most one scan at a time, and no more often than every 30 seconds. */
    fun scan(context: Context, port: Int, onFound: (List<String>) -> Unit) {
        val now = SystemClock.elapsedRealtime()
        if (lastRunAt != 0L && now - lastRunAt < MIN_INTERVAL_MS) return
        if (!running.compareAndSet(false, true)) return
        lastRunAt = now

        val work = Runnable {
            try {
                val targets = targets(context)
                if (targets.isEmpty()) {
                    Log.i(TAG, "no probeable subnet on this phone")
                } else {
                    Log.i(TAG, "probing ${targets.size} addresses on port $port")
                    val found = probe(targets, port)
                    if (found.isEmpty()) {
                        Log.i(TAG, "no listener answered on port $port")
                    } else {
                        Log.i(TAG, "listener found at ${found.joinToString(", ")}")
                        onFound(found)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "subnet probe failed: ${e.message}")
            } finally {
                running.set(false)
            }
        }
        Thread(work, "tenna-subnet-scan").start()
    }

    private class ProbeTarget(val address: InetAddress, val network: Network?)

    private fun probe(targets: List<ProbeTarget>, port: Int): List<String> {
        val pool = Executors.newFixedThreadPool(minOf(THREADS, targets.size))
        return try {
            val pending = targets.map { target ->
                pool.submit<String?> {
                    val socket = Socket()
                    try {
                        target.network?.bindSocket(socket)
                        socket.connect(
                            InetSocketAddress(target.address, port), PROBE_TIMEOUT_MS
                        )
                        target.address.hostAddress
                    } catch (_: Exception) {
                        null
                    } finally {
                        runCatching { socket.close() }
                    }
                }
            }
            pool.shutdown()
            pool.awaitTermination(30, TimeUnit.SECONDS)
            pending.mapNotNull { runCatching { it.get() }.getOrNull() }
        } finally {
            pool.shutdownNow()
        }
    }

    /**
     * Every address on every subnet this phone is directly attached to. Read from
     * [NetworkInterface] rather than ConnectivityManager because that is the only place
     * the tethering interface shows up at all.
     */
    private fun targets(context: Context): List<ProbeTarget> {
        val result = LinkedHashMap<String, ProbeTarget>()
        val interfaces = runCatching { NetworkInterface.getNetworkInterfaces()?.toList() }
            .getOrNull().orEmpty()

        for (iface in interfaces) {
            val usable = runCatching { iface.isUp && !iface.isLoopback }.getOrDefault(false)
            if (!usable) continue
            if (SKIPPED_INTERFACES.any { iface.name.startsWith(it) }) continue

            for (entry in iface.interfaceAddresses) {
                val local = entry.address
                if (local !is Inet4Address) continue
                val prefix = entry.networkPrefixLength.toInt()
                if (prefix < MIN_PREFIX || prefix > 30) continue

                val ownAddress = local.hostAddress ?: continue
                val network = NetworkRoutes.networkFor(context, ownAddress)
                val base = maskedBase(local.address, prefix)
                val hostCount = (1 shl (32 - prefix)) - 2

                for (offset in 1..hostCount) {
                    if (result.size >= MAX_ADDRESSES) return result.values.toList()
                    val bytes = addOffset(base, offset)
                    val text = bytes.joinToString(".") { (it.toInt() and 0xFF).toString() }
                    if (text == ownAddress) continue
                    result.getOrPut(text) {
                        ProbeTarget(InetAddress.getByAddress(bytes), network)
                    }
                }
            }
        }
        return result.values.toList()
    }

    internal fun maskedBase(address: ByteArray, prefix: Int): ByteArray {
        val out = address.copyOf()
        var remaining = prefix
        for (index in 0 until 4) {
            val bits = minOf(8, maxOf(0, remaining))
            val mask = if (bits == 0) 0 else (0xFF shl (8 - bits)) and 0xFF
            out[index] = (out[index].toInt() and mask).toByte()
            remaining -= 8
        }
        return out
    }

    internal fun addOffset(base: ByteArray, offset: Int): ByteArray {
        val value = ((base[0].toInt() and 0xFF) shl 24) or
            ((base[1].toInt() and 0xFF) shl 16) or
            ((base[2].toInt() and 0xFF) shl 8) or
            (base[3].toInt() and 0xFF)
        val sum = value + offset
        return byteArrayOf(
            (sum ushr 24).toByte(),
            (sum ushr 16).toByte(),
            (sum ushr 8).toByte(),
            sum.toByte()
        )
    }
}
