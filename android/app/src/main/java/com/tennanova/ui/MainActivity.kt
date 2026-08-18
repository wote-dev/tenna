package com.tennanova.ui

import android.content.Intent
import android.content.ComponentName
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.provider.Settings as AndroidSettings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        onboardingStep = savedInstanceState?.getString(KEY_ONBOARDING_STEP)
            ?.let { runCatching { OnboardingStep.valueOf(it) }.getOrNull() }
        enableEdgeToEdge()
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
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshAccessState()
        if (onboardingStep != null) advanceOnboarding()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumePairingExtra(intent)
        consumeSharedContent(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        onboardingStep?.let { outState.putString(KEY_ONBOARDING_STEP, it.name) }
        super.onSaveInstanceState(outState)
    }

    private fun consumePairingExtra(intent: Intent?) {
        intent?.getStringExtra("pair")?.let {
            if (viewModel.pair(it)) beginOnboarding()
        }
    }

    private fun consumeSharedContent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val payload = when {
            intent.type?.startsWith("image/") == true -> {
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
                uri?.let { ClipboardPayload.ImageReference(it, intent.type!!, null) }
            }
            else -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                ?.takeIf { it.isNotEmpty() }?.let(ClipboardPayload::Text)
        }
        if (payload != null) {
            val sent = RuntimeStatusStore.clipboardChanged(payload)
            viewModel.setMessage(
                if (sent) "Shared clipboard item sent to your Mac."
                else "Connect to your Mac, then share this item again."
            )
        } else {
            viewModel.setMessage("That shared item is not supported.")
        }
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
                viewModel.setMessage("Setup complete. Connecting securely…")
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
    }
}
