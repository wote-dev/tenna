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

data class MainUiState(
    val paired: Boolean = false,
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
    private val message = MutableStateFlow<String?>(null)

    val uiState = combine(
        pairing, listenerEnabled, accessibilityEnabled, RuntimeStatusStore.state, message
    ) { pair, listener, accessibility, runtime, localMessage ->
        MainUiState(
            paired = pair.paired,
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
            message = localMessage?.takeUnless {
                runtime.connection == ConnectionStatus.CONNECTED &&
                    it.startsWith("Pairing saved")
            },
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
            message.value = "That pairing code is invalid or incomplete."
            return false
        }
        settings.savePairing(payload)
        pairing.value = pairingState()
        message.value = "Pairing saved. Connecting securely…"
        RuntimeStatusStore.pairingChanged()
        return true
    }

    fun unpair() {
        settings.clearPairing()
        pairing.value = pairingState()
        message.value = "Mac unpaired"
        RuntimeStatusStore.pairingChanged()
    }

    fun setMessage(value: String?) {
        message.value = value
    }

    private fun pairingState() = PairState(settings.isPaired, settings.host)
    private data class PairState(val paired: Boolean, val host: String?)
}
