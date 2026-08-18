package com.tennanova.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import com.tennanova.core.Proto
import java.net.Inet4Address
import java.util.concurrent.atomic.AtomicBoolean

/** Finds the Bonjour-advertised Mac so DHCP address changes do not require re-pairing. */
@Suppress("DEPRECATION")
class MacDiscovery(context: Context, private val onResolved: (String, Int) -> Unit) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val running = AtomicBoolean(false)
    private val resolving = AtomicBoolean(false)

    private val resolveListener = object : NsdManager.ResolveListener {
        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            resolving.set(false)
            Log.w(TAG, "Mac service resolve failed: $errorCode")
        }

        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
            resolving.set(false)
            val address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                serviceInfo.hostAddresses.firstOrNull { it is Inet4Address }
                    ?: serviceInfo.hostAddresses.firstOrNull()
            } else {
                serviceInfo.host
            }
            val host = address?.hostAddress ?: return
            if (serviceInfo.port in 1..65535) onResolved(host, serviceInfo.port)
        }
    }

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) = Unit
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            running.set(false)
            runCatching { manager.stopServiceDiscovery(this) }
        }
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            running.set(false)
            runCatching { manager.stopServiceDiscovery(this) }
        }
        override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            if (serviceInfo.serviceType.startsWith(Proto.BONJOUR_TYPE) &&
                resolving.compareAndSet(false, true)) {
                runCatching { manager.resolveService(serviceInfo, resolveListener) }
                    .onFailure { resolving.set(false) }
            }
        }
    }

    fun start() {
        if (!running.compareAndSet(false, true)) return
        runCatching {
            manager.discoverServices(
                "${Proto.BONJOUR_TYPE}.", NsdManager.PROTOCOL_DNS_SD, discoveryListener
            )
        }.onFailure {
            running.set(false)
            Log.w(TAG, "Mac discovery could not start: ${it.message}")
        }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        resolving.set(false)
        runCatching { manager.stopServiceDiscovery(discoveryListener) }
    }

    private companion object {
        const val TAG = "TennaNova"
    }
}
