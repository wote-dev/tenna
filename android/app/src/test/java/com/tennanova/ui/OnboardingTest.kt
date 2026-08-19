package com.tennanova.ui

import com.tennanova.core.ConnectionStatus
import com.tennanova.net.ConnectionTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingTest {
    @Test fun permissionsAreRequestedInOrderAndThenComplete() {
        assertEquals(
            OnboardingStep.NOTIFICATIONS,
            requiredOnboardingStep(notificationAccess = false, accessibilityAccess = false)
        )
        assertEquals(
            OnboardingStep.ACCESSIBILITY,
            requiredOnboardingStep(notificationAccess = true, accessibilityAccess = false)
        )
        assertEquals(
            OnboardingStep.COMPLETE,
            requiredOnboardingStep(notificationAccess = true, accessibilityAccess = true)
        )
    }

    @Test fun reconnectTransportPhasesHaveOneStableHeadline() {
        val phases = listOf(
            ConnectionStatus.DISCONNECTED,
            ConnectionStatus.CONNECTING,
            ConnectionStatus.AUTHENTICATING
        )

        assertEquals(
            listOf("Reconnecting…"),
            phases.map {
                connectionCopy(MainUiState(
                    paired = true,
                    listenerEnabled = true,
                    connectionServiceRunning = true,
                    pairingConfirmed = true,
                    connection = it
                )).first
            }.distinct()
        )
        assertEquals(
            listOf("Finishing pairing…"),
            phases.map {
                connectionCopy(MainUiState(
                    paired = true,
                    listenerEnabled = true,
                    connectionServiceRunning = true,
                    pairingConfirmed = false,
                    connection = it
                )).first
            }.distinct()
        )
    }

    @Test fun aStoppedConnectionServiceIsReportedInsteadOfPretendingToPair() {
        assertEquals(
            "Starting connection…",
            connectionCopy(MainUiState(
                paired = true,
                listenerEnabled = true,
                connectionServiceRunning = false,
                connection = ConnectionStatus.DISCONNECTED
            )).first
        )
    }

    @Test fun aRelayedSessionSaysSoRatherThanJustConnected() {
        // "Connected" alone would hide both that a blocked network is being worked
        // around and why sync feels slower than on a shared Wi-Fi.
        val (title, detail) = connectionCopy(MainUiState(
            paired = true,
            listenerEnabled = true,
            connectionServiceRunning = true,
            pairingConfirmed = true,
            connection = ConnectionStatus.CONNECTED,
            transport = ConnectionTransport.RELAY
        ))
        assertEquals("Connected over the internet", title)
        assertTrue(detail.contains("relaying"))
    }

    @Test fun aDirectSessionIsStillJustConnected() {
        assertEquals(
            "Connected",
            connectionCopy(MainUiState(
                paired = true,
                listenerEnabled = true,
                connectionServiceRunning = true,
                pairingConfirmed = true,
                connection = ConnectionStatus.CONNECTED,
                transport = ConnectionTransport.LAN
            )).first
        )
    }
}
