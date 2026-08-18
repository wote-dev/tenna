package com.tennanova.net

import android.content.Context
import android.net.Network
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tennanova.core.Proto
import java.net.Inet4Address
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean

/** A resolved Mac address together with the Android route on which it was discovered. */
internal data class DiscoveredEndpoint(
    val host: String,
    val port: Int,
    val network: Network?
)

/**
 * Finds the paired Mac on every Android [Network], not only the default route.
 *
 * That distinction matters whenever Wi-Fi has no internet, the phone still prefers
 * cellular, or a VPN is present. Android's legacy three-argument NSD call only browses
 * the default network; the NetworkRequest overload follows every matching network and
 * also starts browsing automatically when another one appears.
 */
@Suppress("DEPRECATION")
internal class MacDiscovery(
    context: Context,
    private val expectedSpki: () -> String?,
    private val onChanged: (List<DiscoveredEndpoint>) -> Unit
) {
    private data class ServiceKey(
        val name: String,
        val type: String,
        val networkHandle: Long?
    )

    private val manager = context.getSystemService(NsdManager::class.java)
    private val executor = context.mainExecutor
    private val handler = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)
    private val lock = Any()
    private val services = LinkedHashMap<ServiceKey, NsdServiceInfo>()
    private val resolving = HashSet<ServiceKey>()
    private val endpoints = LinkedHashMap<ServiceKey, List<DiscoveredEndpoint>>()

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {
            Log.i(TAG, "discovering Macs on every available network")
        }

        override fun onDiscoveryStopped(serviceType: String) = Unit

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            running.set(false)
            Log.w(TAG, "Mac discovery could not start: $errorCode")
            clearResolvedEndpoints()
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            running.set(false)
            Log.w(TAG, "Mac discovery could not stop: $errorCode")
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            val key = serviceKey(serviceInfo)
            val changed = synchronized(lock) {
                services.remove(key)
                resolving.remove(key)
                endpoints.remove(key) != null
            }
            if (changed) publish()
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            if (!serviceInfo.serviceType.startsWith(Proto.BONJOUR_TYPE)) return
            val key = serviceKey(serviceInfo)
            synchronized(lock) { services[key] = serviceInfo }
            resolve(key)
        }
    }

    fun start() {
        if (!running.compareAndSet(false, true)) return
        runCatching {
            // clearCapabilities includes local-only Wi-Fi networks. In particular, do not
            // require INTERNET: a shared LAN is useful even when it has no upstream route.
            val networks = NetworkRequest.Builder().clearCapabilities().build()
            manager.discoverServices(
                "${Proto.BONJOUR_TYPE}.",
                NsdManager.PROTOCOL_DNS_SD,
                networks,
                executor,
                discoveryListener
            )
        }.onFailure {
            running.set(false)
            Log.w(TAG, "Mac discovery could not start: ${it.message}")
            clearResolvedEndpoints()
        }
    }

    fun stop() {
        val wasRunning = running.getAndSet(false)
        if (wasRunning) runCatching { manager.stopServiceDiscovery(discoveryListener) }
        clearResolvedEndpoints()
    }

    private fun clearResolvedEndpoints() {
        synchronized(lock) {
            services.clear()
            resolving.clear()
            endpoints.clear()
        }
        onChanged(emptyList())
    }

    private fun resolve(key: ServiceKey) {
        val service = synchronized(lock) {
            if (!running.get() || !resolving.add(key)) return
            services[key]
        } ?: run {
            synchronized(lock) { resolving.remove(key) }
            return
        }

        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                synchronized(lock) { resolving.remove(key) }
                Log.w(TAG, "Mac service resolve failed: $errorCode")
                // Resolution can race an interface finishing configuration. Retry the
                // same still-present service without restarting discovery or waiting for
                // another onServiceFound that may never arrive.
                handler.postDelayed({ resolve(key) }, RESOLVE_RETRY_MS)
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                synchronized(lock) { resolving.remove(key) }

                // New Mac builds publish their identity in Bonjour. It is only a routing
                // filter — TLS pinning remains the trust decision — but it prevents a
                // second Tennanova Mac on the LAN from being mistaken for the paired one.
                val advertisedSpki = serviceInfo.attributes[SPKI_ATTRIBUTE]
                    ?.toString(StandardCharsets.UTF_8)
                val expected = expectedSpki()
                if (!advertisedSpki.isNullOrBlank() && expected != null &&
                    advertisedSpki != expected) {
                    Log.i(TAG, "ignoring a different Tennanova Mac on this network")
                    val changed = synchronized(lock) { endpoints.remove(key) != null }
                    if (changed) publish()
                    return
                }

                val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    serviceInfo.hostAddresses
                } else {
                    listOfNotNull(serviceInfo.host)
                }
                val resolved = addresses
                    .filterNot { it.isAnyLocalAddress || it.isLoopbackAddress }
                    .sortedBy { if (it is Inet4Address) 0 else 1 }
                    .mapNotNull { address ->
                        val host = address.hostAddress?.substringBefore('%') ?: return@mapNotNull null
                        serviceInfo.port.takeIf { it in 1..65535 }?.let {
                            DiscoveredEndpoint(host, it, serviceInfo.network)
                        }
                    }
                    .distinctBy { Triple(it.host, it.port, it.network?.networkHandle) }

                val changed = synchronized(lock) {
                    // A resolve can finish after onServiceLost or stop(). Never publish
                    // that stale route back into a new connection attempt.
                    if (!running.get() || key !in services) return@synchronized false
                    endpoints.put(key, resolved) != resolved
                }
                if (changed) publish()
            }
        }

        runCatching { manager.resolveService(service, executor, listener) }
            .onFailure {
                synchronized(lock) { resolving.remove(key) }
                Log.w(TAG, "Mac service resolve could not start: ${it.message}")
                handler.postDelayed({ resolve(key) }, RESOLVE_RETRY_MS)
            }
    }

    private fun publish() {
        val snapshot = synchronized(lock) {
            endpoints.values.flatten().distinctBy {
                Triple(it.host, it.port, it.network?.networkHandle)
            }
        }
        onChanged(snapshot)
    }

    private fun serviceKey(info: NsdServiceInfo) = ServiceKey(
        info.serviceName,
        info.serviceType,
        info.network?.networkHandle
    )

    private companion object {
        const val TAG = "TennaNova"
        const val SPKI_ATTRIBUTE = "spki"
        const val RESOLVE_RETRY_MS = 1_500L
    }
}
