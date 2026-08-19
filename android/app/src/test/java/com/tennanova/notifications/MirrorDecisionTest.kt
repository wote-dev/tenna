package com.tennanova.notifications

import android.app.Notification
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MirrorDecisionTest {

    private fun decide(
        pkg: String = "com.whatsapp",
        flags: Int = 0,
        hasText: Boolean = true,
        muted: Set<String> = emptySet(),
        smsActive: Boolean = false,
        defaultSms: String? = "com.samsung.android.messaging"
    ) = MirrorDecision.shouldMirror(
        packageName = pkg,
        ownPackage = "com.tennanova",
        flags = flags,
        hasText = hasText,
        mutedPackages = muted,
        smsActive = smsActive,
        defaultSmsPackage = defaultSms
    )

    @Test fun `an ordinary chat notification is mirrored`() {
        assertTrue(decide())
    }

    @Test fun `our own notifications are never mirrored`() {
        // Otherwise the mirror mirrors itself.
        assertFalse(decide(pkg = "com.tennanova"))
    }

    @Test fun `group summaries are dropped`() {
        assertFalse(decide(flags = Notification.FLAG_GROUP_SUMMARY))
    }

    @Test fun `ongoing and foreground-service notifications are dropped`() {
        assertFalse(decide(flags = Notification.FLAG_ONGOING_EVENT))
        assertFalse(decide(flags = Notification.FLAG_FOREGROUND_SERVICE))
    }

    @Test fun `muted packages are dropped`() {
        assertFalse(decide(muted = setOf("com.whatsapp")))
    }

    @Test fun `a notification with nothing to show is dropped`() {
        assertFalse(decide(hasText = false))
    }

    @Test fun `the messaging app is suppressed only while SMS is live`() {
        val messaging = "com.samsung.android.messaging"
        // Every incoming text raises a provider row *and* a notification. With the SMS
        // channel on, mirroring both would put every message on the Mac twice.
        assertFalse(decide(pkg = messaging, smsActive = true))
        // With SMS off, that notification is the only sighting the Mac gets.
        assertTrue(decide(pkg = messaging, smsActive = false))
    }

    @Test fun `SMS suppression does not touch other messaging apps`() {
        assertTrue(decide(pkg = "com.whatsapp", smsActive = true))
        assertTrue(decide(pkg = "org.thoughtcrime.securesms", smsActive = true))
    }

    @Test fun `a phone with no default SMS app suppresses nothing`() {
        // Nothing to compare against, and guessing would silence a real app.
        assertTrue(decide(pkg = "com.samsung.android.messaging",
                          smsActive = true, defaultSms = null))
    }
}
