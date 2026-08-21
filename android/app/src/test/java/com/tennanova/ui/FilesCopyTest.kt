package com.tennanova.ui

import com.tennanova.files.TransferDirection
import com.tennanova.files.TransferItem
import com.tennanova.files.TransferState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The copy functions are `internal` and pure precisely so they can be asserted on here,
 * without Compose — the same arrangement `smsCopy` and `callsCopy` use in [OnboardingTest].
 */
class FilesCopyTest {

    private val item = TransferItem(
        id = "a1b2c3d4",
        direction = TransferDirection.FROM_MAC,
        name = "screen-20250817-005420.mp4",
        bytes = 13_800_000L,
        mime = "video/mp4"
    )

    @Test fun anActiveRowNamesBothNumbersAndThePercentage() {
        val line = transferStatusLine(
            item.copy(state = TransferState.ACTIVE, transferred = 6_900_000L)
        )
        assertEquals("6.9 MB of 13.8 MB · 50%", line)
    }

    /**
     * A paused transfer must not read like a failure. It is the normal outcome of walking
     * out of Wi-Fi range, and the file is still on disk waiting.
     */
    @Test fun aPausedRowSaysItWillContinue() {
        val line = transferStatusLine(item.copy(state = TransferState.PAUSED))
        assertTrue(line.contains("continue"))
    }

    @Test fun aFailedRowPrefersTheReasonOverTheWordFailed() {
        assertEquals(
            "Checksum mismatch — the file was not saved",
            transferStatusLine(
                item.copy(
                    state = TransferState.FAILED,
                    detail = "Checksum mismatch — the file was not saved"
                )
            )
        )
        assertEquals("Failed", transferStatusLine(item.copy(state = TransferState.FAILED)))
    }

    @Test fun aFinishedRowReadsDifferentlyEachWay() {
        assertEquals(
            "Sent · 13.8 MB",
            transferStatusLine(
                item.copy(direction = TransferDirection.TO_MAC, state = TransferState.COMPLETED)
            )
        )
        assertEquals(
            "Saved to Downloads",
            transferStatusLine(item.copy(state = TransferState.COMPLETED))
        )
    }

    @Test fun sizesAreWrittenTheWayAPersonWouldSayThem() {
        assertEquals("512 B", formatBytes(512))
        assertEquals("10.5 KB", formatBytes(10_500))
        assertEquals("5.1 MB", formatBytes(5_100_000))
        assertEquals("1.5 GB", formatBytes(1_500_000_000))
    }

    /** An older Mac is a thing to explain, not a thing to fail silently against. */
    @Test fun anOlderMacIsExplainedRatherThanLeftBlank() {
        val (_, detail) = filesCopy(MainUiState(peerSupportsFiles = false))
        assertTrue(detail.contains("Update the Mac app"))
    }
}
