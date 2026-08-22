package com.tennanova.core

import com.tennanova.clipboard.ClipboardAccessStatus
import com.tennanova.clipboard.ClipboardPayload
import com.tennanova.files.TransferItem
import com.tennanova.net.ConnectionTransport
import com.tennanova.notifications.TennaNotificationListener
import com.tennanova.mirror.MirrorSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
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

/**
 * How far SMS mirroring has got, in the same shape as `ClipboardAccessStatus`.
 *
 * `OFF` and `NEEDS_PERMISSION` are deliberately distinct: one is a choice and the other is
 * an unfinished setup, and a dashboard that conflates them tells the user to fix something
 * they switched off on purpose.
 */
enum class SmsAccessStatus {
    OFF,
    NEEDS_PERMISSION,
    READY,
    ERROR
}

/**
 * How far call mirroring has got.
 *
 * `LIMITED` is the state that matters and the reason this is not a boolean. Calls reach
 * the Mac with no permission at all, and most dialers put answer and decline intents in
 * their notification, so the feature is genuinely working — but a dialer that does not
 * will have no button to press, and only the optional `ANSWER_PHONE_CALLS` grant can
 * rescue that. Saying "on" would overpromise and "needs access" would nag about something
 * already doing its job.
 */
enum class CallAccessStatus {
    OFF,
    LIMITED,
    READY
}

data class RuntimeSnapshot(
    val connection: ConnectionStatus = ConnectionStatus.UNPAIRED,
    val transport: ConnectionTransport = ConnectionTransport.NONE,
    val connectionServiceRunning: Boolean = false,
    val pairingConfirmed: Boolean = false,
    val macName: String? = null,
    val clipboard: ClipboardAccessStatus = ClipboardAccessStatus.NEEDS_ACCESSIBILITY,
    val sms: SmsAccessStatus = SmsAccessStatus.OFF,
    val smsThreadCount: Int = 0,
    val calls: CallAccessStatus = CallAccessStatus.OFF,
    val peerSupportsImages: Boolean = false,
    val peerSupportsFiles: Boolean = false,
    val peerSupportsMirror: Boolean = false,
    val mirror: MirrorSnapshot = MirrorSnapshot(),
    /**
     * Files going each way. Carried inside the snapshot rather than as a flow of its own:
     * `MainViewModel.combine` is already at its five-argument overload, and a sixth forces
     * the vararg form for the sake of one list.
     */
    val transfers: List<TransferItem> = emptyList(),
    val lastTransfer: String? = null,
    val connectionError: String? = null,
    val clipboardError: String? = null,
    val transferError: String? = null
)

/** Process-wide, observable status only. The service reference is weak and cleared on destroy. */
object RuntimeStatusStore {
    lateinit var context: android.content.Context
        private set

    fun initialize(context: android.content.Context) {
        this.context = context.applicationContext
    }
    private val mutable = MutableStateFlow(RuntimeSnapshot())
    val state: StateFlow<RuntimeSnapshot> = mutable.asStateFlow()

    @Volatile
    private var serviceRef = WeakReference<TennaNotificationListener>(null)

    fun attach(service: TennaNotificationListener) {
        initialize(service)
        serviceRef = WeakReference(service)
    }

    fun detach(service: TennaNotificationListener) {
        if (serviceRef.get() === service) {
            serviceRef.clear()
            updateConnectionService(false)
        }
    }

    fun updateTransport(transport: ConnectionTransport) {
        mutable.update { it.copy(transport = transport) }
    }

    fun updateConnectionService(running: Boolean) {
        mutable.update { it.copy(connectionServiceRunning = running) }
    }

    fun updateSms(status: SmsAccessStatus, threadCount: Int? = null) {
        mutable.update {
            it.copy(sms = status, smsThreadCount = threadCount ?: it.smsThreadCount)
        }
    }

    fun updateCalls(status: CallAccessStatus) {
        mutable.update { it.copy(calls = status) }
    }

    fun updateConnection(status: ConnectionStatus, error: String? = null) {
        mutable.update { it.copy(connection = status, connectionError = error) }
    }

    fun updatePairing(confirmed: Boolean, macName: String?) {
        mutable.update { it.copy(pairingConfirmed = confirmed, macName = macName) }
    }

    fun updateClipboard(status: ClipboardAccessStatus, error: String? = null) {
        mutable.update { it.copy(clipboard = status, clipboardError = error) }
    }

    fun updatePeerCapabilities(
        supportsImages: Boolean,
        supportsFiles: Boolean = false,
        supportsMirror: Boolean = false
    ) {
        mutable.update {
            it.copy(
                peerSupportsImages = supportsImages,
                peerSupportsFiles = supportsFiles,
                peerSupportsMirror = supportsMirror
            )
        }
    }

    fun updateMirror(mirror: MirrorSnapshot) {
        mutable.update { it.copy(mirror = mirror) }
    }

    fun updateTransfers(transfers: List<TransferItem>) {
        mutable.update { it.copy(transfers = transfers) }
    }

    fun transfer(message: String, error: String? = null) {
        mutable.update { it.copy(lastTransfer = message, transferError = error) }
    }

    fun clipboardChanged(payload: ClipboardPayload): Boolean = serviceRef.get()?.let {
        it.onClipboardChanged(payload)
        true
    } ?: false
    fun pairingChanged() = serviceRef.get()?.onPairingChanged()

    /** The UI's way to hand shared documents to the service that owns the socket. */
    fun sendFiles(uris: List<android.net.Uri>): Boolean = serviceRef.get()?.let {
        it.onFilesShared(uris)
        true
    } ?: false

    fun cancelTransfer(id: String) = serviceRef.get()?.onCancelTransfer(id)

    fun clearFinishedTransfers() = serviceRef.get()?.onClearFinishedTransfers()
}
