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

    @Test fun textChangesProduceDifferentFingerprints() {
        assertNotEquals(
            ClipboardPayload.Text("https://example.com/one").fingerprint,
            ClipboardPayload.Text("https://example.com/two").fingerprint
        )
    }
}
