package com.tennanova.ui

import android.app.Application
import android.content.ComponentName
import android.provider.Settings as AndroidSettings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.tennanova.clipboard.ClipboardAccessStatus
import com.tennanova.clipboard.TennaAccessibilityService
import android.Manifest
import android.content.pm.PackageManager
import com.tennanova.core.CallAccessStatus
import com.tennanova.core.ConnectionStatus
import com.tennanova.core.PairingPayload
import com.tennanova.core.RuntimeStatusStore
import com.tennanova.files.TransferItem
import com.tennanova.core.Settings
import com.tennanova.core.SmsAccessStatus
import com.tennanova.sms.SmsMirror
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.delay
import com.tennanova.net.ConnectionTransport
import com.tennanova.mirror.MirrorSnapshot
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
    val sms: SmsAccessStatus = SmsAccessStatus.OFF,
    val smsThreadCount: Int = 0,
    val calls: CallAccessStatus = CallAccessStatus.OFF,
    val peerSupportsImages: Boolean = false,
    val peerSupportsFiles: Boolean = false,
    val peerSupportsMirror: Boolean = false,
    val mirror: MirrorSnapshot = MirrorSnapshot(),
    val transfers: List<TransferItem> = emptyList(),
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
            // No extra flow: the SMS state already travels in the runtime snapshot, kept
            // current by `refreshAccessState`. `combine` is at its five-argument overload
            // here and adding a sixth would force the vararg form for no gain.
            sms = runtime.sms,
            smsThreadCount = runtime.smsThreadCount,
            calls = runtime.calls,
            peerSupportsImages = runtime.peerSupportsImages,
            peerSupportsFiles = runtime.peerSupportsFiles,
            peerSupportsMirror = runtime.peerSupportsMirror,
            mirror = runtime.mirror,
            transfers = runtime.transfers,
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
        RuntimeStatusStore.updateSms(
            when {
                !settings.smsEnabled -> SmsAccessStatus.OFF
                !smsPermissionsGranted() -> SmsAccessStatus.NEEDS_PERMISSION
                else -> SmsAccessStatus.READY
            }
        )
        RuntimeStatusStore.updateCalls(
            when {
                !settings.callsEnabled -> CallAccessStatus.OFF
                callControlGranted() -> CallAccessStatus.READY
                else -> CallAccessStatus.LIMITED
            }
        )
        if (!accessibilityEnabled.value) {
            RuntimeStatusStore.updateClipboard(ClipboardAccessStatus.NEEDS_ACCESSIBILITY)
        } else if (RuntimeStatusStore.state.value.clipboard != ClipboardAccessStatus.ERROR) {
            RuntimeStatusStore.updateClipboard(ClipboardAccessStatus.READY)
        }
    }

    /**
     * SMS is a toggle, never an onboarding step. The app has to stay wholly useful to
     * someone who never turns it on, so nothing here blocks or nags.
     */
    fun setSmsEnabled(enabled: Boolean) {
        settings.smsEnabled = enabled
        refreshAccessState()
        if (enabled && smsPermissionsGranted()) {
            show(Banner("SMS mirroring on. Your Mac will show your texts.", transient = true))
        } else if (!enabled) {
            show(Banner("SMS mirroring off.", transient = true))
        }
        // The listener holds the socket and does the mirroring, and it only learns about
        // this when it next says hello.
        RuntimeStatusStore.pairingChanged()
    }

    fun smsEnabled(): Boolean = settings.smsEnabled

    /**
     * Calls are the one feature here that is on by default, because turning it on asks
     * nothing of the user: a call is read out of a notification this app already receives,
     * and the notifications it reads are ones the mirror used to drop.
     */
    fun setCallsEnabled(enabled: Boolean) {
        settings.callsEnabled = enabled
        refreshAccessState()
        show(
            Banner(
                if (enabled) "Calls will ring on your Mac. The audio stays on this phone."
                else "Calls stay on this phone.",
                transient = true
            )
        )
        // The listener holds the socket and advertises the capability, and it only learns
        // about this when it next says hello.
        RuntimeStatusStore.pairingChanged()
    }

    fun callsEnabled(): Boolean = settings.callsEnabled

    /** See [Settings.callControlAsked] — false before the first ask *and* after a
     *  permanent refusal, which the caller has to tell apart. */
    fun callControlAsked(): Boolean = settings.callControlAsked

    fun noteCallControlAsked() {
        settings.callControlAsked = true
    }

    /** The optional grant that answers a call whose dialer offers no button to press. */
    fun callControlGranted(): Boolean =
        getApplication<Application>().checkSelfPermission(
            Manifest.permission.ANSWER_PHONE_CALLS
        ) == PackageManager.PERMISSION_GRANTED

    fun smsPermissionsGranted(): Boolean {
        val mirror = SmsMirror(getApplication())
        return mirror.hasReadAccess() && mirror.hasSendAccess()
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

    /**
     * Whether the POST_NOTIFICATIONS prompt has already been shown once. Deliberately not
     * persisted: it exists to stop one session asking twice, not to remember an answer
     * the system already remembers.
     */
    var hasAskedAboutFileNotifications = false

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
