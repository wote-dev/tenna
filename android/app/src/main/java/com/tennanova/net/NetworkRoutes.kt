package com.tennanova.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import java.net.Inet4Address

/**
 * Picks the [Network] that can actually carry traffic to a given address.
 *
 * Android routes an unbound socket over the *default* network. When the Mac shares its
 * connection over Wi-Fi the phone joins a network with no internet, Android keeps
 * cellular as the default, and everything aimed at the Mac leaves by the wrong door.
 * Binding the socket to the network whose own subnet contains the target fixes that.
 *
 * A null result is not a failure. The phone's own tethering interface has no [Network]
 * at all, and unbound is exactly right there — the tether subnet is directly connected.
 */
object NetworkRoutes {

    @Suppress("DEPRECATION") // allNetworks has no non-deprecated equivalent.
    fun networkFor(context: Context, host: String): Network? {
        val target = parseIPv4(host) ?: return null
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return null
        return runCatching {
            manager.allNetworks.firstOrNull { network ->
                manager.getLinkProperties(network)?.linkAddresses.orEmpty().any { link ->
                    val local = link.address
                    local is Inet4Address &&
                        sameSubnet(local.address, link.prefixLength, target)
                }
            }
        }.getOrNull()
    }

    /**
     * Literal dotted quads only. A hostname here would mean a DNS lookup, and the
     * callers run on the main thread.
     */
    internal fun parseIPv4(host: String): ByteArray? {
        val parts = host.split('.')
        if (parts.size != 4) return null
        val bytes = ByteArray(4)
        for (index in 0 until 4) {
            val part = parts[index]
            if (part.isEmpty() || part.length > 3) return null
            val value = part.toIntOrNull() ?: return null
            if (value !in 0..255) return null
            bytes[index] = value.toByte()
        }
        return bytes
    }

    internal fun sameSubnet(local: ByteArray, prefixLength: Int, target: ByteArray): Boolean {
        if (local.size != 4 || target.size != 4 || prefixLength !in 1..32) return false
        var remaining = prefixLength
        for (index in 0 until 4) {
            if (remaining <= 0) break
            val bits = minOf(8, remaining)
            val mask = (0xFF shl (8 - bits)) and 0xFF
            if ((local[index].toInt() and mask) != (target[index].toInt() and mask)) {
                return false
            }
            remaining -= bits
        }
        return true
    }
}
