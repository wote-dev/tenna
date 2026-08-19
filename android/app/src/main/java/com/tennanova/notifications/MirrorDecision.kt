package com.tennanova.notifications

import android.app.Notification

/**
 * Whether one notification is worth sending to the Mac.
 *
 * Extracted from the listener because every rule here exists to stop a specific kind of
 * duplicate or noise, and each is worth a test that does not need a running service —
 * the same reasoning that split `CopySignalDetector` out of the accessibility service.
 */
object MirrorDecision {

    fun shouldMirror(
        packageName: String,
        ownPackage: String,
        flags: Int,
        hasText: Boolean,
        mutedPackages: Set<String>,
        smsActive: Boolean,
        defaultSmsPackage: String?
    ): Boolean {
        // A feedback loop: our own mirror notification would mirror itself.
        if (packageName == ownPackage) return false
        // Group summaries are the single biggest source of duplicates.
        if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        if (flags and Notification.FLAG_ONGOING_EVENT != 0) return false
        if (flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return false
        if (packageName in mutedPackages) return false
        // Every incoming text raises a provider row *and* a notification. While the SMS
        // channel is live it owns those conversations, and mirroring both would put every
        // message on the Mac twice — once as a real thread, once as an alert.
        if (smsActive && defaultSmsPackage != null && packageName == defaultSmsPackage) {
            return false
        }
        // Nothing to show.
        return hasText
    }
}
