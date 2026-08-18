package com.tennanova.core

import com.tennanova.clipboard.ClipboardAccessStatus
import com.tennanova.clipboard.ClipboardPayload
import com.tennanova.notifications.TennaNotificationListener
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.lang.ref.WeakReference

enum class ConnectionStatus {
    UNPAIRED,
    DISCONNECTED,
    CONNECTING,
    AUTHENTICATING,
    CONNECTED,
    PIN_MISMATCH,
    AUTH_FAILED;

    /**
     * The connection attempt has resolved, one way or the other.
     *
     * DISCONNECTED is deliberately excluded. It is also the state a paired phone sits in
     * before its first attempt starts, so treating it as settled would clear a banner in
     * the same breath it was set.
     */
    val isSettled: Boolean
        get() = this == CONNECTED || this == AUTH_FAILED || this == PIN_MISMATCH
}

data class RuntimeSnapshot(
    val connection: ConnectionStatus = ConnectionStatus.UNPAIRED,
    val clipboard: ClipboardAccessStatus = ClipboardAccessStatus.NEEDS_ACCESSIBILITY,
    val peerSupportsImages: Boolean = false,
    val lastTransfer: String? = null,
    val connectionError: String? = null,
    val clipboardError: String? = null,
    val transferError: String? = null
)

/** Process-wide, observable status only. The service reference is weak and cleared on destroy. */
object RuntimeStatusStore {
    private val mutable = MutableStateFlow(RuntimeSnapshot())
    val state: StateFlow<RuntimeSnapshot> = mutable.asStateFlow()

    @Volatile
    private var serviceRef = WeakReference<TennaNotificationListener>(null)

    fun attach(service: TennaNotificationListener) {
        serviceRef = WeakReference(service)
    }

    fun detach(service: TennaNotificationListener) {
        if (serviceRef.get() === service) serviceRef.clear()
    }

    fun updateConnection(status: ConnectionStatus, error: String? = null) {
        mutable.value = mutable.value.copy(connection = status, connectionError = error)
    }

    fun updateClipboard(status: ClipboardAccessStatus, error: String? = null) {
        mutable.value = mutable.value.copy(clipboard = status, clipboardError = error)
    }

    fun updatePeerCapabilities(supportsImages: Boolean) {
        mutable.value = mutable.value.copy(peerSupportsImages = supportsImages)
    }

    fun transfer(message: String, error: String? = null) {
        mutable.value = mutable.value.copy(lastTransfer = message, transferError = error)
    }

    fun clipboardChanged(payload: ClipboardPayload): Boolean = serviceRef.get()?.let {
        it.onClipboardChanged(payload)
        true
    } ?: false
    fun pairingChanged() = serviceRef.get()?.onPairingChanged()
}
