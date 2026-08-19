package com.tennanova.ui

import android.app.Application
import android.content.ComponentName
import android.provider.Settings as AndroidSettings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.tennanova.clipboard.ClipboardAccessStatus
import com.tennanova.clipboard.TennaAccessibilityService
import com.tennanova.core.ConnectionStatus
import com.tennanova.core.PairingPayload
import com.tennanova.core.RuntimeStatusStore
import com.tennanova.core.Settings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.delay
import com.tennanova.net.ConnectionTransport
import kotlinx.coroutines.launch

data class MainUiState(
    val paired: Boolean = false,
    val transport: ConnectionTransport = ConnectionTransport.NONE,
    val connectionServiceRunning: Boolean = false,
    val pairingConfirmed: Boolean = false,
    val macName: String? = null,
    val host: String? = null,
    val listenerEnabled: Boolean = false,
    val accessibilityEnabled: Boolean = false,
    val connection: ConnectionStatus = ConnectionStatus.UNPAIRED,
    val clipboard: ClipboardAccessStatus = ClipboardAccessStatus.NEEDS_ACCESSIBILITY,
    val peerSupportsImages: Boolean = false,
    val lastTransfer: String? = null,
    val message: String? = null,
    val error: String? = null,
    val clipboardError: String? = null
)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val settings = Settings(application)
    private val pairing = MutableStateFlow(pairingState())
    private val listenerEnabled = MutableStateFlow(false)
    private val accessibilityEnabled = MutableStateFlow(false)
    private val message = MutableStateFlow<Banner?>(null)

    /**
     * A one-off line under the connection hero.
     *
     * [transient] marks a line that belongs to an attempt still in flight, so it is wrong
     * the moment the connection settles *however* it settles — not only on success.
     *
     * This used to be a bare string cleared by testing `startsWith("Pairing saved")` while
     * connected. Two things went wrong with that. The onboarding variant did not match the
     * prefix and so never cleared at all, and neither variant cleared on failure — leaving
     * "Connecting securely…" pinned under a hero that said "Mac offline". The hero owns
     * connection status; a banner that restates it can only ever contradict it, so these
     * no longer try.
     */
    private data class Banner(val text: String, val transient: Boolean = false)

    /**
     * Shows a banner, and makes sure a transient one cannot outlive its attempt.
     *
     * Clearing on a settled connection is not enough on its own. DISCONNECTED is
     * deliberately not "settled" — it is also the state a paired phone sits in before its
     * first attempt begins, so treating it as settled would clear the banner in the same
     * breath it was set. But that leaves the case this exists for: a phone that never
     * reaches the Mac at all stays DISCONNECTED forever, and "Setup complete." sat under
     * "Mac offline" indefinitely. A timer covers every outcome without the race.
     */
    private fun show(banner: Banner?) {
        message.value = banner
        if (banner?.transient != true) return
        viewModelScope.launch {
            delay(TRANSIENT_BANNER_MS)
            // Identity, not equality: a newer banner must not be cleared by an older timer.
            if (message.value === banner) message.value = null
        }
    }

    val uiState = combine(
        pairing, listenerEnabled, accessibilityEnabled, RuntimeStatusStore.state, message
    ) { pair, listener, accessibility, runtime, localMessage ->
        MainUiState(
            paired = pair.paired,
            transport = runtime.transport,
            connectionServiceRunning = runtime.connectionServiceRunning,
            pairingConfirmed = pair.confirmed || runtime.pairingConfirmed,
            macName = runtime.macName ?: pair.macName,
            host = pair.host,
            listenerEnabled = listener,
            accessibilityEnabled = accessibility,
            connection = when {
                !pair.paired -> ConnectionStatus.UNPAIRED
                runtime.connection == ConnectionStatus.UNPAIRED -> ConnectionStatus.DISCONNECTED
                else -> runtime.connection
            },
            clipboard = if (accessibility) runtime.clipboard
                else ClipboardAccessStatus.NEEDS_ACCESSIBILITY,
            peerSupportsImages = runtime.peerSupportsImages,
            lastTransfer = runtime.lastTransfer,
            message = localMessage
                ?.takeUnless { it.transient && runtime.connection.isSettled }
                ?.text,
            error = runtime.connectionError ?: runtime.transferError,
            clipboardError = runtime.clipboardError
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), MainUiState())

    fun refreshAccessState() {
        val context = getApplication<Application>()
        val flat = AndroidSettings.Secure.getString(
            context.contentResolver, "enabled_notification_listeners"
        ).orEmpty()
        val expected = ComponentName(
            context, com.tennanova.notifications.TennaNotificationListener::class.java
        )
        listenerEnabled.value = flat.split(':').any {
            ComponentName.unflattenFromString(it) == expected
        }
        accessibilityEnabled.value = TennaAccessibilityService.isEnabled(context)
        if (!accessibilityEnabled.value) {
            RuntimeStatusStore.updateClipboard(ClipboardAccessStatus.NEEDS_ACCESSIBILITY)
        } else if (RuntimeStatusStore.state.value.clipboard != ClipboardAccessStatus.ERROR) {
            RuntimeStatusStore.updateClipboard(ClipboardAccessStatus.READY)
        }
    }

    fun hasNotificationAccess(): Boolean {
        refreshAccessState()
        return listenerEnabled.value
    }

    fun hasAccessibilityAccess(): Boolean {
        refreshAccessState()
        return accessibilityEnabled.value
    }

    fun pair(raw: String): Boolean {
        val payload = PairingPayload.parse(raw.trim())
        if (payload == null) {
            show(Banner("That pairing code is invalid or incomplete."))
            return false
        }
        settings.savePairing(payload)
        RuntimeStatusStore.updatePairing(false, null)
        pairing.value = pairingState()
        show(Banner("Pairing saved.", transient = true))
        RuntimeStatusStore.pairingChanged()
        return true
    }

    fun unpair() {
        settings.clearPairing()
        RuntimeStatusStore.updatePairing(false, null)
        pairing.value = pairingState()
        show(Banner("Mac unpaired"))
        RuntimeStatusStore.pairingChanged()
    }

    fun setMessage(value: String?, transient: Boolean = false) {
        show(value?.let { Banner(it, transient) })
    }

    private fun pairingState() = PairState(
        settings.isPaired,
        settings.isPairingConfirmed,
        settings.macName,
        settings.host
    )
    private data class PairState(
        val paired: Boolean,
        val confirmed: Boolean,
        val macName: String?,
        val host: String?
    )

    private companion object {
        /** Long enough to read, short enough never to look like live status. */
        const val TRANSIENT_BANNER_MS = 12_000L
    }
}
