package com.tennanova.files

import com.tennanova.core.FileOfferHeader
import com.tennanova.core.Proto

/**
 * Which way a file is going, from this phone's point of view.
 */
enum class TransferDirection { TO_MAC, FROM_MAC }

/**
 * Where a transfer has got to.
 *
 * `PAUSED` is deliberately separate from `FAILED`: a socket dropping mid-file is the normal
 * condition on a phone, not an error, and the staged partial is kept so the next connection
 * continues rather than restarts. Only something that cannot be retried — a checksum
 * mismatch, a vanished source, a refusal — becomes `FAILED`.
 */
enum class TransferState {
    QUEUED,

    /** Hashing the source before offering it. Visible on a large file and nowhere else. */
    PREPARING,

    /** The offer is on the wire; waiting for the Mac to say where to start. */
    OFFERED,
    ACTIVE,
    PAUSED,

    /** Every byte is in; hashing what landed. */
    VERIFYING,
    COMPLETED,
    FAILED,
    CANCELLED;

    val isFinished: Boolean
        get() = this == COMPLETED || this == FAILED || this == CANCELLED

    /** Whether this transfer is occupying its direction's single active slot. */
    val isRunning: Boolean
        get() = this == PREPARING || this == OFFERED || this == ACTIVE || this == VERIFYING
}

/** One file, in one direction, as this phone knows it. */
data class TransferItem(
    /** The wire id. Hex, so it can also name the staging file without escaping its dir. */
    val id: String,
    val direction: TransferDirection,
    /**
     * The name as the Mac sent it, or as the shared document is called. Never used as a
     * path — [TransferPlan.safeFilename] decides what is actually written.
     */
    val name: String,
    val bytes: Long,
    val mime: String,
    /** Known from the start when receiving; known after `PREPARING` when sending. */
    val sha256: String? = null,
    /**
     * Bytes the *receiver* has confirmed. On a send that is what `file.ack` reported and
     * not what has been handed to the socket, so the percentage never runs ahead of reality.
     */
    val transferred: Long = 0,
    val state: TransferState = TransferState.QUEUED,
    val detail: String? = null,
    val startedAt: Long = 0
) {
    val fraction: Float
        get() = if (bytes <= 0) 0f else (transferred.toFloat() / bytes.toFloat()).coerceIn(0f, 1f)
}

/**
 * Decides which chunk goes next, and stops the sender running arbitrarily far ahead of the
 * receiver.
 *
 * The window exists because nothing else bounds a send. OkHttp will accept every chunk of a
 * 2 GiB file into its own outbound queue — and then close the socket when that queue passes
 * 16 MiB. `file.ack` is what returns credit.
 */
class ChunkWindow(val total: Long, from: Long = 0) {
    /** One past the last byte handed to the socket. */
    var sent: Long = from.coerceIn(0, maxOf(total, 0))
        private set

    /** One past the last byte the receiver has confirmed. */
    var acked: Long = sent
        private set

    val isComplete: Boolean get() = acked >= total
    val everythingSent: Boolean get() = sent >= total
    val inFlight: Long get() = sent - acked

    /**
     * The next chunk, or null when there is nothing to send right now — either the file is
     * fully on the wire, or the window is full and the sender must wait for an ack.
     */
    fun nextChunk(): Chunk? {
        if (sent >= total) return null
        if (inFlight >= Proto.FILE_WINDOW_CHUNKS.toLong() * Proto.FILE_CHUNK_BYTES) return null
        val offset = sent
        val count = minOf(Proto.FILE_CHUNK_BYTES.toLong(), total - offset).toInt()
        sent += count
        return Chunk(offset, count)
    }

    /**
     * An ack can only ever move forwards, and never past what was actually sent. A peer
     * claiming otherwise is not trusted into a state where the window would reopen.
     */
    fun acknowledge(received: Long) {
        acked = minOf(maxOf(acked, received), sent)
    }

    data class Chunk(val offset: Long, val bytes: Int)
}

/** What a receiver should do about an offer. */
sealed interface OfferVerdict {
    /** Take it, starting here. Non-zero means a matching partial is already staged. */
    data class Begin(val offset: Long) : OfferVerdict

    data class Refuse(val reason: String) : OfferVerdict
}

/**
 * Every decision the transfer engine makes, with none of the machinery that makes them
 * happen.
 *
 * Split out for the reason `buildEndpointCandidates` is: `SocketClient` and the listener
 * service cannot be instantiated in a JVM unit test, so anything worth asserting on has to
 * live somewhere that needs neither Android nor a socket.
 */
object TransferPlan {

    /** Finished rows are a convenience, not a record. The files themselves are the record. */
    const val MAX_FINISHED = 30

    /**
     * What to answer a `file.offer` with.
     *
     * Everything outside the list that the decision needs is passed in, so the whole thing
     * stays testable: how much of this exact file is already staged, and how much room the
     * cache directory has.
     */
    fun verdict(
        offer: FileOfferHeader,
        known: TransferItem?,
        incomingBusy: Boolean,
        stagedBytes: Long,
        freeBytes: Long
    ): OfferVerdict {
        if (!offer.isValid) return OfferVerdict.Refuse("protocol")

        // A re-offer of something already running is the same transfer arriving twice.
        if (known != null && known.state.isRunning) return OfferVerdict.Refuse("protocol")
        if (incomingBusy && known == null) return OfferVerdict.Refuse("busy")

        // Only resume a partial that is unambiguously this file: same id, and the list
        // still remembers the same length and digest. Anything else starts over.
        val resumable = stagedBytes in 1 until offer.bytes &&
            known != null && known.bytes == offer.bytes && known.sha256 == offer.sha256
        val offset = if (resumable) stagedBytes else 0L

        if (freeBytes < offer.bytes - offset) return OfferVerdict.Refuse("disk")
        return OfferVerdict.Begin(offset)
    }

    /**
     * Turns a name off the wire into something safe to write.
     *
     * [Proto.isValidTransferName] has already refused the outright hostile cases and the
     * offer never got this far if it failed; this is the second layer and it assumes nothing
     * about the first. Separators and control characters go, leading dots and underscores go
     * — a dot would arrive hidden, and a leading underscore is only ever the corpse of a
     * separator replaced here — and the length is capped while keeping the extension, which
     * is what decides which app opens the file.
     */
    fun safeFilename(raw: String): String {
        var cleaned = raw
            .map { if (it == '/' || it == '\\' || it == ':' || it.isISOControl()) '_' else it }
            .joinToString("")
            .trim()
        cleaned = cleaned.dropWhile { it == '.' || it == '_' }
        if (cleaned.isEmpty()) return "file"

        val dot = cleaned.lastIndexOf('.')
        val stem = if (dot > 0) cleaned.substring(0, dot) else cleaned
        val ext = if (dot > 0) cleaned.substring(dot + 1) else ""
        val cappedStem = stem.take(120).ifEmpty { "file" }
        val cappedExt = ext.take(20)
        return if (cappedExt.isEmpty()) cappedStem else "$cappedStem.$cappedExt"
    }

    /**
     * Whether the receiver should ack now. Often enough to keep the sender's window full,
     * rarely enough that acks are not a meaningful share of the traffic — and always after
     * the last chunk, or the sender would sit on a full window waiting for credit that
     * never comes.
     */
    fun shouldAck(chunksSinceAck: Int, received: Long, total: Long): Boolean =
        received >= total || chunksSinceAck >= Proto.FILE_ACK_EVERY_CHUNKS

    /**
     * The list as the dashboard should show it: everything unfinished, newest first, then
     * the most recent finished rows.
     */
    fun presentable(items: List<TransferItem>): List<TransferItem> {
        val (finished, running) = items.partition { it.state.isFinished }
        return running + finished.take(MAX_FINISHED)
    }
}
