package com.tennanova.ui

import com.tennanova.core.ConnectionStatus
import org.junit.Assert.assertEquals
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
                    pairingConfirmed = false,
                    connection = it
                )).first
            }.distinct()
        )
    }
}
