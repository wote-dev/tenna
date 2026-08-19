package com.tennanova.clipboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class ClipboardFingerprintTest {
    @Test fun equalTextProducesEqualFingerprint() {
        assertEquals(
            ClipboardPayload.Text("one-time code: 123456").fingerprint,
            ClipboardPayload.Text("one-time code: 123456").fingerprint
        )
    }

    /**
     * `ClipboardWriter` builds its echo guard from the same string. If these two ever drift,
     * a clip the phone sent would come back from the Mac looking new and raise a second
     * system "Copied" panel — silently, and only on a reconnect.
     */
    @Test fun textFingerprintMatchesTheClipboardWriterFormat() {
        assertEquals("text:tenna", ClipboardPayload.Text("tenna").fingerprint)
    }

    @Test fun textChangesProduceDifferentFingerprints() {
        assertNotEquals(
            ClipboardPayload.Text("https://example.com/one").fingerprint,
            ClipboardPayload.Text("https://example.com/two").fingerprint
        )
    }
}
