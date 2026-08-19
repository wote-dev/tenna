package com.tennanova.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.junit.Before
import com.tennanova.clipboard.ClipboardAccessStatus
import com.tennanova.core.ConnectionStatus
import org.junit.Rule
import org.junit.Test

class DashboardScreenTest {
    @get:Rule val compose = createComposeRule()

    @Before fun wakeDevice() {
        UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).apply {
            wakeUp()
            executeShellCommand("wm dismiss-keyguard")
        }
    }

    @Test fun unpairedDashboardShowsQrSetup() {
        render(MainUiState(connection = ConnectionStatus.UNPAIRED))
        compose.onNodeWithText("Tennanova").assertIsDisplayed()
        compose.onNodeWithText("Pair your Mac").assertIsDisplayed()
        compose.onNodeWithText("Scan pairing code").assertIsDisplayed()
        compose.onNodeWithText("Notification mirroring").assertIsDisplayed()
    }

    @Test fun connectingStateExplainsPendingPairing() {
        render(MainUiState(paired = true, host = "mac.local", listenerEnabled = true,
            connectionServiceRunning = true,
            connection = ConnectionStatus.CONNECTING))
        compose.onNodeWithText("Finishing pairing…").assertIsDisplayed()
        compose.onNodeWithText("Pairing pending").assertIsDisplayed()
    }

    @Test fun connectedStateIncludesImageCapability() {
        render(MainUiState(paired = true, host = "mac.local", listenerEnabled = true,
            connection = ConnectionStatus.CONNECTED,
            accessibilityEnabled = true,
            clipboard = ClipboardAccessStatus.READY,
            peerSupportsImages = true))
        compose.onNodeWithText("Connected").assertIsDisplayed()
        // What is syncing is now stated on the hero as chips, rather than buried in a
        // permission card's body copy.
        compose.onNodeWithText("Notifications").assertIsDisplayed()
        compose.onNodeWithText("Text").assertIsDisplayed()
        compose.onNodeWithText("Images").assertIsDisplayed()
    }

    @Test fun grantedPermissionsCollapseInsteadOfShoutingForAttention() {
        render(MainUiState(paired = true, host = "mac.local", listenerEnabled = true,
            connection = ConnectionStatus.CONNECTED,
            accessibilityEnabled = true,
            clipboard = ClipboardAccessStatus.READY))
        compose.onNodeWithText("Notifications and clipboard ready").assertDoesNotExist()
        compose.onAllNodesWithText("Enable").assertCountEquals(0)
    }

    @Test fun deniedClipboardStateShowsGrantAction() {
        render(MainUiState(paired = true, connection = ConnectionStatus.DISCONNECTED,
            clipboard = ClipboardAccessStatus.NEEDS_ACCESSIBILITY))
        compose.onAllNodesWithText("Enable").assertCountEquals(2)
    }

    @Test fun accessibilityStateExplainsOneTimeSetup() {
        render(MainUiState(paired = true, connection = ConnectionStatus.DISCONNECTED,
            clipboard = ClipboardAccessStatus.NEEDS_ACCESSIBILITY))
        compose.onAllNodesWithText("Needs access").assertCountEquals(2)
        compose.onNodeWithText(
            "Enable Tennanova clipboard sync once in Accessibility settings. No Shizuku or reboot setup is needed."
        ).performScrollTo().assertIsDisplayed()
    }

    @Test fun errorsDarkModeAndLargeFontsRemainReadable() {
        render(MainUiState(paired = true, connection = ConnectionStatus.PIN_MISMATCH,
            clipboard = ClipboardAccessStatus.ERROR,
            error = "The Mac identity changed."), dark = true, fontScale = 1.6f)
        compose.onNodeWithText("Mac identity changed").assertIsDisplayed()
        compose.onNodeWithText("The Mac identity changed.").assertIsDisplayed()
        compose.onNodeWithText("Needs attention").performScrollTo().assertIsDisplayed()
    }

    private fun render(state: MainUiState, dark: Boolean = false, fontScale: Float = 1f) {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale)
            ) {
                TennaTheme(darkTheme = dark) {
                    DashboardScreen(
                        state = state,
                        onOpenNotificationAccess = {}, onOpenAccessibility = {},
                        onScanQr = {}, onPair = { true }, onUnpair = {},
                        onSetSmsEnabled = {}
                    )
                }
            }
        }
    }
}
