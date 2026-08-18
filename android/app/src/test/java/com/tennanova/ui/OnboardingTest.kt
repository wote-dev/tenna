package com.tennanova.ui

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
}
