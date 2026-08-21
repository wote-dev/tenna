package com.tennanova.ui

import android.Manifest
import android.content.Intent
import android.graphics.Color.TRANSPARENT
import android.content.ComponentName
import android.net.Uri
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.provider.Settings as AndroidSettings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import android.content.pm.PackageManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.tennanova.clipboard.ClipboardPayload
import com.tennanova.core.RuntimeStatusStore
import com.tennanova.notifications.TennaNotificationListener

internal enum class OnboardingStep { NOTIFICATIONS, ACCESSIBILITY, COMPLETE }

internal fun requiredOnboardingStep(
    notificationAccess: Boolean,
    accessibilityAccess: Boolean
): OnboardingStep = when {
    !notificationAccess -> OnboardingStep.NOTIFICATIONS
    !accessibilityAccess -> OnboardingStep.ACCESSIBILITY
    else -> OnboardingStep.COMPLETE
}

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<MainViewModel>()
    private var onboardingStep: OnboardingStep? = null

    /**
     * A share is consumed once, not once per Activity instance. `onCreate` runs again on every
     * rotation or fold with the same `ACTION_SEND` intent still attached, and sending the item
     * twice makes the Mac — and then the phone's own clipboard panel — repeat itself.
     */
    private var shareConsumed = false

    /**
     * The first runtime permission request in this app. Everything before it was a deep
     * link to a Settings screen re-checked on resume, and the QR scanner was even chosen
     * to avoid a CAMERA prompt — but SMS has no Settings-screen equivalent.
     *
     * A denial is not an error state: the toggle simply goes back off, because the user
     * saying no to reading their texts is an answer, not a failure to configure something.
     */
    private val smsPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        val essential = granted[Manifest.permission.READ_SMS] == true &&
            granted[Manifest.permission.SEND_SMS] == true
        viewModel.setSmsEnabled(essential)
        if (!essential) {
            // "Don't ask again" makes the system dialog stop appearing, and a switch that
            // does nothing when tapped is indistinguishable from a broken one.
            if (!shouldShowRequestPermissionRationale(Manifest.permission.READ_SMS)) {
                openAppSettings()
            }
        }
    }

    /**
     * A shared image, waiting on the user to say what they meant by it. Held in state
     * rather than shown from here so it survives a rotation like every other dialog.
     */
    private var pendingImageShare by mutableStateOf<Pair<Uri, String>?>(null)

    /**
     * Denial is an answer, not a failure: the transfer still runs and the dashboard still
     * lists it, so there is nothing to send anyone to Settings for.
     */
    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    private fun setSmsEnabled(enabled: Boolean) {
        if (!enabled) {
            viewModel.setSmsEnabled(false)
            return
        }
        if (viewModel.smsPermissionsGranted()) {
            viewModel.setSmsEnabled(true)
            return
        }
        smsPermissions.launch(
            arrayOf(
                Manifest.permission.READ_SMS,
                Manifest.permission.SEND_SMS,
                // Optional: without it the Mac shows numbers instead of names, which is
                // worse but perfectly usable, so a denial here does not fail the toggle.
                Manifest.permission.READ_CONTACTS
            )
        )
    }

    /**
     * Call control, which is an *upgrade* and not a gate.
     *
     * Unlike SMS, a denial here does not turn the feature off: calls still reach the Mac,
     * and most dialers put answer and decline intents in their notification, so refusing
     * this leaves a working feature slightly narrower rather than a broken one.
     */
    private val callPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        viewModel.refreshAccessState()
        if (granted[Manifest.permission.ANSWER_PHONE_CALLS] == true) {
            viewModel.setMessage("Tennanova can now answer calls from your Mac.", transient = true)
        } else {
            viewModel.setMessage(
                "Calls will still ring on your Mac, using your dialer's own buttons.",
                transient = true
            )
        }
    }

    private fun setCallsEnabled(enabled: Boolean) {
        viewModel.setCallsEnabled(enabled)
        if (enabled && !viewModel.callControlGranted()) requestCallControl()
    }

    private fun requestCallControl() {
        if (viewModel.callControlGranted()) return
        // "Don't ask again" makes the system dialog stop appearing, and a button that does
        // nothing when tapped is indistinguishable from a broken one.
        if (!shouldShowRequestPermissionRationale(Manifest.permission.ANSWER_PHONE_CALLS) &&
            !shouldShowRequestPermissionRationale(Manifest.permission.READ_PHONE_STATE) &&
            viewModel.callControlAsked()) {
            openAppSettings()
            return
        }
        viewModel.noteCallControlAsked()
        callPermissions.launch(
            arrayOf(
                Manifest.permission.ANSWER_PHONE_CALLS,
                Manifest.permission.READ_PHONE_STATE
            )
        )
    }

    private fun openAppSettings() {
        startActivity(
            Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", packageName, null))
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        onboardingStep = savedInstanceState?.getString(KEY_ONBOARDING_STEP)
            ?.let { runCatching { OnboardingStep.valueOf(it) }.getOrNull() }
        shareConsumed = savedInstanceState?.getBoolean(KEY_SHARE_CONSUMED) == true
        // Explicit transparent styles rather than the defaults: the app is light-only, and
        // the auto styles would flip the bar icons with the system's dark-mode setting even
        // though the backdrop stays pale. isNavigationBarContrastEnforced is what stops
        // Android painting a translucent grey band over the bottom of the gradient.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.light(TRANSPARENT, TRANSPARENT),
            navigationBarStyle = SystemBarStyle.light(TRANSPARENT, TRANSPARENT)
        )
        window.isNavigationBarContrastEnforced = false
        consumePairingExtra(intent)
        consumeSharedContent(intent)
        setContent {
            TennaTheme {
                val state by viewModel.uiState.collectAsStateWithLifecycle()
                DashboardScreen(
                    state = state,
                    onOpenNotificationAccess = {
                        onboardingStep = OnboardingStep.NOTIFICATIONS
                        openNotificationAccess()
                    },
                    onOpenAccessibility = {
                        onboardingStep = OnboardingStep.ACCESSIBILITY
                        openAccessibilityAccess()
                    },
                    onScanQr = ::scanQr,
                    onPair = { value ->
                        viewModel.pair(value).also { if (it) beginOnboarding() }
                    },
                    onUnpair = viewModel::unpair,
                    onSetSmsEnabled = ::setSmsEnabled,
                    onSetCallsEnabled = ::setCallsEnabled,
                    onGrantCallControl = ::requestCallControl,
                    onCancelTransfer = RuntimeStatusStore::cancelTransfer,
                    onClearTransfers = RuntimeStatusStore::clearFinishedTransfers,
                )

                pendingImageShare?.let { (uri, mime) ->
                    SharedImageChoice(
                        onClipboard = {
                            pendingImageShare = null
                            deliverToClipboard(ClipboardPayload.ImageReference(uri, mime, null))
                        },
                        onFile = {
                            pendingImageShare = null
                            deliverAsFiles(listOf(uri))
                        },
                        onDismiss = { pendingImageShare = null }
                    )
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshAccessState()
        // Updating or force-stopping the APK can leave an enabled notification listener
        // unbound. Pairing cannot progress until Android recreates it, so request that on
        // every foreground resume rather than only during first-run onboarding.
        if (viewModel.hasNotificationAccess() &&
            !RuntimeStatusStore.state.value.connectionServiceRunning) {
            requestNotificationRebind()
        }
        if (onboardingStep != null) advanceOnboarding()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // A genuinely new intent carries a genuinely new share.
        shareConsumed = false
        consumePairingExtra(intent)
        consumeSharedContent(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        onboardingStep?.let { outState.putString(KEY_ONBOARDING_STEP, it.name) }
        outState.putBoolean(KEY_SHARE_CONSUMED, shareConsumed)
        super.onSaveInstanceState(outState)
    }

    private fun consumePairingExtra(intent: Intent?) {
        intent?.getStringExtra("pair")?.let {
            if (viewModel.pair(it)) beginOnboarding()
        }
    }

    /**
     * Everything shared into this app, routed by what it is.
     *
     * Text goes to the clipboard, which is what Share → Tennanova has always meant and
     * what `PROTOCOL.md` documents as the fallback for apps whose copy action exposes no
     * signal. Anything that is not text or an image is a file for the Mac.
     *
     * An image is the one genuinely ambiguous case — a screenshot shared to paste on the
     * Mac and a photo shared to keep there are the same intent — so it asks. Guessing
     * either way would silently take one of the two away.
     */
    private fun consumeSharedContent(intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        if (shareConsumed) return
        shareConsumed = true

        val uris = sharedUris(intent)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?.takeIf { it.isNotEmpty() }
        val isImage = intent.type?.startsWith("image/") == true

        when {
            uris.isEmpty() && text != null -> deliverToClipboard(ClipboardPayload.Text(text))

            uris.isEmpty() -> viewModel.setMessage("That shared item is not supported.")

            isImage && uris.size == 1 ->
                pendingImageShare = uris.first() to (intent.type ?: "image/*")

            else -> deliverAsFiles(uris)
        }
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> =
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        } else {
            listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        }

    private fun deliverToClipboard(payload: ClipboardPayload) {
        val sent = RuntimeStatusStore.clipboardChanged(payload)
        viewModel.setMessage(
            if (sent) "Shared clipboard item sent to your Mac."
            else "Connect to your Mac, then share this item again."
        )
    }

    private fun deliverAsFiles(uris: List<Uri>) {
        val sent = RuntimeStatusStore.sendFiles(uris)
        viewModel.setMessage(
            if (sent && uris.size == 1) "Sending that file to your Mac."
            else if (sent) "Sending ${uris.size} files to your Mac."
            else "Connect to your Mac, then share this again."
        )
        if (sent) askForNotificationPermissionOnce()
    }

    /**
     * Asked the first time a transfer is started rather than during onboarding: until
     * someone has actually moved a file, a prompt about file notifications is a question
     * about a feature they have not used.
     */
    private fun askForNotificationPermissionOnce() {
        if (viewModel.hasAskedAboutFileNotifications) return
        viewModel.hasAskedAboutFileNotifications = true
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) return
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun scanQr() {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { barcode ->
                val raw = barcode.rawValue
                if (raw == null) {
                    viewModel.setMessage("The QR code did not contain pairing data.")
                } else if (viewModel.pair(raw)) {
                    beginOnboarding()
                }
            }
            .addOnFailureListener { error ->
                viewModel.setMessage(error.localizedMessage ?: "QR scanner could not start.")
            }
    }

    private fun beginOnboarding() {
        onboardingStep = null
        advanceOnboarding()
    }

    private fun advanceOnboarding() {
        val required = requiredOnboardingStep(
            notificationAccess = viewModel.hasNotificationAccess(),
            accessibilityAccess = viewModel.hasAccessibilityAccess()
        )
        when (required) {
            OnboardingStep.NOTIFICATIONS -> {
                if (onboardingStep == OnboardingStep.NOTIFICATIONS) {
                    onboardingStep = null
                    viewModel.setMessage("Notification access is still needed to finish setup.")
                } else {
                    onboardingStep = OnboardingStep.NOTIFICATIONS
                    openNotificationAccess()
                }
            }
            OnboardingStep.ACCESSIBILITY -> {
                requestNotificationRebind()
                if (onboardingStep == OnboardingStep.ACCESSIBILITY) {
                    onboardingStep = null
                    viewModel.setMessage(
                        "Accessibility access is still needed for phone → Mac clipboard sync."
                    )
                } else {
                    onboardingStep = OnboardingStep.ACCESSIBILITY
                    openAccessibilityAccess()
                }
            }
            OnboardingStep.COMPLETE -> {
                requestNotificationRebind()
                onboardingStep = null
                RuntimeStatusStore.pairingChanged()
                // Transient: the hero owns connection status from here, and this line
                // must not outlive the attempt it describes.
                viewModel.setMessage("Setup complete.", transient = true)
            }
        }
    }

    private fun openNotificationAccess() {
        val component = ComponentName(this, TennaNotificationListener::class.java)
        val detail = Intent(AndroidSettings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
            .putExtra(Intent.EXTRA_COMPONENT_NAME, component)
        runCatching { startActivity(detail) }
            .onFailure { startActivity(Intent(AndroidSettings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
    }

    private fun openAccessibilityAccess() {
        // Android 16 protects ACTION_ACCESSIBILITY_DETAILS_SETTINGS with the signature-only
        // OPEN_ACCESSIBILITY_DETAILS_SETTINGS permission. Third-party apps must use this
        // public service list; returning from it resumes the next onboarding step.
        startActivity(Intent(AndroidSettings.ACTION_ACCESSIBILITY_SETTINGS))
    }

    private fun requestNotificationRebind() {
        NotificationListenerService.requestRebind(
            ComponentName(this, TennaNotificationListener::class.java)
        )
    }

    private companion object {
        const val KEY_ONBOARDING_STEP = "onboardingStep"
        const val KEY_SHARE_CONSUMED = "shareConsumed"
    }
}
