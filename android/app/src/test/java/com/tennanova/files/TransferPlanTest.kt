package com.tennanova.files

import com.tennanova.core.FileOfferHeader
import com.tennanova.core.Proto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChunkWindowTest {

    @Test fun aWholeFileIsHandedOutInChunks() {
        val window = ChunkWindow(Proto.FILE_CHUNK_BYTES * 2L + 17)

        assertEquals(ChunkWindow.Chunk(0, Proto.FILE_CHUNK_BYTES), window.nextChunk())
        assertEquals(
            ChunkWindow.Chunk(Proto.FILE_CHUNK_BYTES.toLong(), Proto.FILE_CHUNK_BYTES),
            window.nextChunk()
        )
        assertEquals(ChunkWindow.Chunk(Proto.FILE_CHUNK_BYTES * 2L, 17), window.nextChunk())

        assertNull(window.nextChunk())
        assertTrue(window.everythingSent)
        assertFalse(window.isComplete)
    }

    /**
     * The whole point of the window: without it OkHttp accepts every chunk of a 2 GiB file
     * into its outbound queue and then closes the socket when that queue passes 16 MiB.
     */
    @Test fun theSenderStopsWhenTheReceiverStopsAcking() {
        val window = ChunkWindow(Proto.FILE_CHUNK_BYTES * 100L)

        var handed = 0
        while (window.nextChunk() != null) handed++
        assertEquals(Proto.FILE_WINDOW_CHUNKS, handed)

        window.acknowledge(Proto.FILE_CHUNK_BYTES * 4L)
        var more = 0
        while (window.nextChunk() != null) more++
        assertEquals(4, more)
    }

    @Test fun resumingStartsAtTheOffsetAndNotAtZero() {
        val window = ChunkWindow(Proto.FILE_CHUNK_BYTES * 3L, from = Proto.FILE_CHUNK_BYTES.toLong())
        assertEquals(Proto.FILE_CHUNK_BYTES.toLong(), window.nextChunk()?.offset)
        while (window.nextChunk() != null) Unit
        window.acknowledge(Proto.FILE_CHUNK_BYTES * 3L)
        assertTrue(window.isComplete)
    }

    /**
     * An ack is the only thing the peer can say that reopens the window, so it is the one
     * number worth distrusting.
     */
    @Test fun anAckCannotRunBackwardsOrPastWhatWasSent() {
        val window = ChunkWindow(Proto.FILE_CHUNK_BYTES * 10L)
        window.nextChunk()
        window.nextChunk()

        window.acknowledge(Proto.FILE_CHUNK_BYTES.toLong())
        window.acknowledge(0)
        assertEquals(Proto.FILE_CHUNK_BYTES.toLong(), window.acked)

        window.acknowledge(Long.MAX_VALUE)
        assertEquals(Proto.FILE_CHUNK_BYTES * 2L, window.acked)
        assertFalse(window.isComplete)
    }

    @Test fun anEmptyFileIsAlreadyDone() {
        val window = ChunkWindow(0)
        assertNull(window.nextChunk())
        assertTrue(window.isComplete)
    }
}

class TransferVerdictTest {

    private val offer = FileOfferHeader(
        id = "a1b2c3d4", name = "notes.txt", bytes = 5000L, mime = "text/plain",
        sha256 = "b".repeat(64), modified = null
    )

    private fun known(
        bytes: Long = 5000L,
        sha256: String? = "b".repeat(64),
        state: TransferState = TransferState.PAUSED
    ) = TransferItem(
        id = "a1b2c3d4", direction = TransferDirection.FROM_MAC, name = "notes.txt",
        bytes = bytes, mime = "text/plain", sha256 = sha256, state = state
    )

    @Test fun aFreshOfferStartsAtZero() {
        val verdict = TransferPlan.verdict(offer, null, false, 0, 1_000_000)
        assertEquals(OfferVerdict.Begin(0), verdict)
    }

    @Test fun aFullCacheIsSaidOutLoudRatherThanFailedAt99Percent() {
        assertEquals(
            OfferVerdict.Refuse("disk"),
            TransferPlan.verdict(offer, null, false, 0, 4999)
        )
    }

    @Test fun anOversizedOfferIsRefusedBeforeAnyByteMoves() {
        val huge = offer.copy(bytes = Proto.MAX_FILE_BYTES + 1)
        assertEquals(
            OfferVerdict.Refuse("protocol"),
            TransferPlan.verdict(huge, null, false, 0, Long.MAX_VALUE)
        )
    }

    /**
     * The staged partial is only continued when the list still agrees it is the same file.
     * A digest or a length that has changed means the Mac is offering something else under
     * a reused id, and resuming would splice two files together.
     */
    @Test fun aPartialIsResumedOnlyWhenItIsProvablyTheSameFile() {
        assertEquals(
            OfferVerdict.Begin(2000),
            TransferPlan.verdict(offer, known(), false, 2000, 999_999)
        )
        assertEquals(
            OfferVerdict.Begin(0),
            TransferPlan.verdict(offer, known(sha256 = "d".repeat(64)), false, 2000, 999_999)
        )
        assertEquals(
            OfferVerdict.Begin(0),
            TransferPlan.verdict(offer, known(bytes = 4000), false, 2000, 999_999)
        )
        assertEquals(
            OfferVerdict.Begin(0),
            TransferPlan.verdict(offer, null, false, 2000, 999_999)
        )
    }

    @Test fun aPartialAsLongAsTheFileIsNotAResume() {
        assertEquals(
            OfferVerdict.Begin(0),
            TransferPlan.verdict(offer, known(), false, 5000, 999_999)
        )
    }

    @Test fun aSecondOfferForARunningTransferIsRejected() {
        assertEquals(
            OfferVerdict.Refuse("protocol"),
            TransferPlan.verdict(offer, known(state = TransferState.ACTIVE), false, 0, 999_999)
        )
    }

    @Test fun anOfferArrivingMidReceiveWaitsItsTurn() {
        assertEquals(
            OfferVerdict.Refuse("busy"),
            TransferPlan.verdict(offer, null, true, 0, 999_999)
        )
    }
}

class TransferNameTest {

    @Test fun aNameThatCouldNameAPathIsFlattened() {
        assertEquals("ssh_authorized_keys", TransferPlan.safeFilename("../../.ssh/authorized_keys"))
        assertEquals("a_b_c.txt", TransferPlan.safeFilename("a/b/c.txt"))
        assertEquals("win_path.txt", TransferPlan.safeFilename("win\\path.txt"))
    }

    /**
     * Nothing arrives hidden. A file the user cannot see in their file manager is a file
     * they did not know they received.
     */
    @Test fun aLeadingDotIsRemovedSoNothingArrivesHidden() {
        assertEquals("bashrc", TransferPlan.safeFilename(".bashrc"))
        assertEquals("notes.txt", TransferPlan.safeFilename("...notes.txt"))
        assertEquals("leading.txt", TransferPlan.safeFilename("_leading.txt"))
        // A dot in the middle is just a filename.
        assertEquals("my..notes.txt", TransferPlan.safeFilename("my..notes.txt"))
    }

    @Test fun anEmptyOrUnusableNameStillGetsAFile() {
        assertEquals("file", TransferPlan.safeFilename(""))
        assertEquals("file", TransferPlan.safeFilename("   "))
        assertEquals("file", TransferPlan.safeFilename(".."))
        assertEquals("file", TransferPlan.safeFilename("/"))
    }

    /** The extension decides which app opens the file, so it is the last thing to lose. */
    @Test fun aLongNameIsCappedWithoutLosingItsExtension() {
        val safe = TransferPlan.safeFilename("n".repeat(400) + ".mp4")
        assertTrue(safe.endsWith(".mp4"))
        assertEquals(124, safe.length)
    }

    @Test fun aControlCharacterCannotSurviveIntoAFilename() {
        assertEquals("no_nul.txt", TransferPlan.safeFilename("no\u0000nul.txt"))
        assertEquals("no_newline.txt", TransferPlan.safeFilename("no\nnewline.txt"))
    }

    /**
     * The two implementations of this rule have to agree, or a file crossing in one
     * direction is named differently from the same file crossing back.
     */
    @Test fun theSameRulesAsTheMacSide() {
        // Mirrors TransferNameTests in mac/Tests/TennaNovaTests/TransferLogTests.swift.
        assertEquals("Macintosh HD_file", TransferPlan.safeFilename("Macintosh HD:file"))
    }
}

class TransferAckTest {

    @Test fun theReceiverAcksOftenEnoughToKeepTheWindowFull() {
        assertFalse(TransferPlan.shouldAck(chunksSinceAck = 1, received = 10, total = 100))
        assertTrue(
            TransferPlan.shouldAck(
                chunksSinceAck = Proto.FILE_ACK_EVERY_CHUNKS, received = 10, total = 100
            )
        )
    }

    /** Without this the sender sits on a full window waiting for credit that never comes. */
    @Test fun theLastChunkIsAlwaysAcked() {
        assertTrue(TransferPlan.shouldAck(chunksSinceAck = 1, received = 100, total = 100))
    }
}
