package com.tennanova.files

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import com.tennanova.core.FileChunkHeader
import com.tennanova.core.FileOfferHeader
import com.tennanova.core.Messages
import com.tennanova.core.Proto
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlin.random.Random

/** How the engine reaches the Mac. The notification listener owns the socket and conforms. */
interface FileTransport {
    fun sendJson(message: JSONObject): Boolean

    /**
     * Header and body as one indivisible pair. `SocketClient.sendBinary` holds one lock
     * across both frames, which is what lets the Mac attribute a binary frame to the
     * header before it without any id inside the frame itself.
     */
    fun sendChunk(header: JSONObject, body: ByteArray): Boolean
}

/**
 * Moves files, both ways.
 *
 * Everything runs on one serial executor of its own, the same arrangement `ImageTransfer`
 * uses and for the same reason: this is disk work, and the socket's reader thread is what
 * delivers the acks the pump is waiting for.
 *
 * Whole-file hashing is the one thing that runs elsewhere. It is unbounded work, and
 * holding the state thread for the length of a 2 GiB digest would stall every other
 * transfer and every progress update behind it.
 */
class FileTransfers(
    private val context: Context,
    private val transport: FileTransport,
    private val onChanged: (List<TransferItem>) -> Unit,
    private val onArrived: (TransferItem, Uri) -> Unit = { _, _ -> },
    private val onSummary: (String, String?) -> Unit = { _, _ -> }
) {
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tenna-file-transfers").apply { isDaemon = true }
    }
    private val hashExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tenna-file-hash").apply { isDaemon = true }
    }

    private val staging: File by lazy {
        File(context.cacheDir, "transfers").apply { mkdirs() }
    }

    private val items = LinkedHashMap<String, TransferItem>()
    private var connected = false
    private var peerSupportsFiles = false

    private var outgoing: Outgoing? = null
    private var incoming: Incoming? = null
    private var lastPublish = 0L

    private class Outgoing(
        val id: String,
        /** The staged copy. A shared `content://` grant does not outlive the share. */
        val source: File,
        val handle: RandomAccessFile,
        val window: ChunkWindow
    )

    private class Incoming(
        val id: String,
        val offer: FileOfferHeader,
        val part: File,
        val handle: RandomAccessFile,
        /**
         * Where the next chunk must start. One that does not is a protocol error, not
         * something to write at whatever offset it claims.
         */
        var expected: Long,
        var chunksSinceAck: Int = 0
    )

    // --- Session -----------------------------------------------------------------

    fun sessionReady(peerSupportsFiles: Boolean) = executor.execute {
        this.peerSupportsFiles = peerSupportsFiles
        this.connected = true
        // Everything paused by the last disconnect goes back in the queue and is
        // re-offered under the same id, so the Mac can resume it rather than restart it.
        items.values.filter { it.state == TransferState.PAUSED }.forEach { item ->
            put(
                if (peerSupportsFiles) item.copy(state = TransferState.QUEUED)
                else item.copy(
                    state = TransferState.FAILED,
                    detail = "This Mac's build cannot transfer files"
                )
            )
        }
        publish(force = true)
        startNextSend()
    }

    fun sessionLost() = executor.execute {
        connected = false
        peerSupportsFiles = false
        closeOutgoing()
        closeIncoming(deletePartial = false)
        // Not a failure: the partials are on disk and the next connection continues them.
        items.values.filter { !it.state.isFinished && it.state != TransferState.QUEUED }
            .forEach { put(it.copy(state = TransferState.PAUSED, detail = "Waiting for the Mac")) }
        publish(force = true)
    }

    // --- Sending -----------------------------------------------------------------

    /** Queues documents the user shared into this app. */
    fun enqueue(uris: List<Uri>) = executor.execute {
        Log.i(TAG, "queueing ${uris.size} file(s); connected=$connected files=$peerSupportsFiles")
        for (uri in uris) {
            val described = describe(uri)
            if (described == null) {
                onSummary("Couldn't read that file", "The app that shared it withdrew access")
                continue
            }
            put(described)
        }
        publish(force = true)
        startNextSend()
    }

    fun cancel(id: String) = executor.execute {
        if (outgoing?.id == id) closeOutgoing()
        if (incoming?.id == id) closeIncoming(deletePartial = true)
        items[id]?.let { put(it.copy(state = TransferState.CANCELLED, detail = "Cancelled")) }
        transport.sendJson(Messages.fileCancel(id, "user"))
        publish(force = true)
        startNextSend()
    }

    fun clearFinished() = executor.execute {
        items.entries.removeAll { it.value.state.isFinished }
        publish(force = true)
    }

    /**
     * Copies the shared document into this app's cache before anything else touches it.
     *
     * A `content://` grant from a share sheet lasts as long as the activity that received
     * it, and a queued transfer outlives that by design — the phone may not even be
     * connected yet.
     */
    private fun describe(uri: Uri): TransferItem? = runCatching {
        Log.i(TAG, "staging shared document $uri")
        var name = "file"
        var size = -1L
        context.contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    .takeIf { it >= 0 }?.let { name = cursor.getString(it) ?: name }
                cursor.getColumnIndex(OpenableColumns.SIZE)
                    .takeIf { it >= 0 && !cursor.isNull(it) }?.let { size = cursor.getLong(it) }
            }
        }

        val id = freshId()
        val staged = File(staging, "$id.src")
        var copied = 0L
        context.contentResolver.openInputStream(uri)?.use { input ->
            staged.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    copied += read
                    // Checked while copying, not after: the point is to stop reading, not
                    // to discover afterwards that the cache is full.
                    if (copied > Proto.MAX_FILE_BYTES) {
                        staged.delete()
                        return@runCatching null
                    }
                    output.write(buffer, 0, read)
                }
            }
        } ?: return@runCatching null

        if (copied <= 0) {
            staged.delete()
            return@runCatching null
        }
        if (size < 0) size = copied

        TransferItem(
            id = id,
            direction = TransferDirection.TO_MAC,
            name = name,
            bytes = copied,
            mime = context.contentResolver.getType(uri) ?: "application/octet-stream",
            startedAt = System.currentTimeMillis()
        )
    }.onFailure { Log.w(TAG, "could not stage the shared document", it) }.getOrNull()

    private fun startNextSend() {
        if (!connected || !peerSupportsFiles || outgoing != null) {
            val waiting = items.values.any {
                it.direction == TransferDirection.TO_MAC && it.state == TransferState.QUEUED
            }
            if (waiting) {
                Log.i(
                    TAG,
                    "holding the queue: connected=$connected files=$peerSupportsFiles " +
                        "busy=${outgoing != null}"
                )
            }
            return
        }
        val next = items.values.firstOrNull {
            it.direction == TransferDirection.TO_MAC && it.state == TransferState.QUEUED
        } ?: return

        put(next.copy(state = TransferState.PREPARING))
        publish(force = true)

        // The digest covers the whole file and travels in the offer, which is what lets a
        // resumed transfer be verified rather than assumed. One read pass, off this thread.
        hashExecutor.execute {
            val source = File(staging, "${next.id}.src")
            val digest = digestOf(source)
            executor.execute {
                val current = items[next.id] ?: return@execute
                if (current.state != TransferState.PREPARING || !connected) return@execute
                if (digest == null) {
                    put(current.copy(state = TransferState.FAILED, detail = "The file could not be read"))
                    publish(force = true)
                    startNextSend()
                    return@execute
                }
                val offered = current.copy(state = TransferState.OFFERED, sha256 = digest)
                put(offered)
                val header = FileOfferHeader(
                    id = offered.id, name = offered.name, bytes = offered.bytes,
                    mime = offered.mime, sha256 = digest, modified = offered.startedAt
                )
                if (!transport.sendJson(Messages.fileOffer(header))) {
                    put(offered.copy(state = TransferState.PAUSED, detail = "Waiting for the Mac"))
                }
                publish(force = true)
            }
        }
    }

    fun onBegin(msg: JSONObject) = executor.execute {
        val id = msg.optString("id")
        val offset = msg.optLong("offset")
        val item = items[id] ?: return@execute
        if (item.direction != TransferDirection.TO_MAC ||
            item.state != TransferState.OFFERED ||
            offset < 0 || offset >= item.bytes
        ) return@execute

        val source = File(staging, "$id.src")
        val handle = runCatching { RandomAccessFile(source, "r") }.getOrNull()
        if (handle == null) {
            put(item.copy(state = TransferState.FAILED, detail = "The file was no longer there"))
            transport.sendJson(Messages.fileCancel(id, "gone"))
            publish(force = true)
            startNextSend()
            return@execute
        }

        outgoing = Outgoing(id, source, handle, ChunkWindow(item.bytes, offset))
        put(item.copy(state = TransferState.ACTIVE, transferred = offset))
        publish(force = true)
        pump()
    }

    fun onAck(msg: JSONObject) = executor.execute {
        val id = msg.optString("id")
        val current = outgoing ?: return@execute
        if (current.id != id) return@execute
        current.window.acknowledge(msg.optLong("received"))
        items[id]?.let { put(it.copy(transferred = current.window.acked)) }
        publish()
        pump()
    }

    fun onResult(msg: JSONObject) = executor.execute {
        val id = msg.optString("id")
        val item = items[id] ?: return@execute
        if (item.direction != TransferDirection.TO_MAC) return@execute
        closeOutgoing()
        File(staging, "$id.src").delete()

        if (msg.optBoolean("ok")) {
            put(item.copy(state = TransferState.COMPLETED, transferred = item.bytes))
            onSummary("Sent ${item.name} to the Mac", null)
        } else {
            val error = msg.optString("error").ifEmpty { "The Mac refused it" }
            put(item.copy(state = TransferState.FAILED, detail = error))
            onSummary("${item.name} was not sent", error)
        }
        publish(force = true)
        startNextSend()
    }

    /**
     * Hands chunks to the socket until the window is full.
     *
     * No completion callback is needed the way the Mac side needs one: OkHttp's `send`
     * returns immediately and the ack window already caps what is in flight at 4 MiB, far
     * inside the 16 MiB outbound queue that would otherwise close the socket.
     */
    private fun pump() {
        val current = outgoing ?: return
        while (true) {
            val chunk = current.window.nextChunk() ?: break
            val body = ByteArray(chunk.bytes)
            val read = runCatching {
                current.handle.seek(chunk.offset)
                current.handle.readFully(body)
                chunk.bytes
            }.getOrNull()

            if (read == null) {
                val item = items[current.id]
                closeOutgoing()
                item?.let {
                    put(it.copy(
                        state = TransferState.FAILED,
                        detail = "The file changed while it was being sent"
                    ))
                }
                transport.sendJson(Messages.fileCancel(current.id, "gone"))
                publish(force = true)
                startNextSend()
                return
            }

            if (!transport.sendChunk(Messages.fileChunk(current.id, chunk.offset, chunk.bytes), body)) {
                items[current.id]?.let {
                    put(it.copy(state = TransferState.PAUSED, detail = "Waiting for the Mac"))
                }
                closeOutgoing()
                publish(force = true)
                return
            }
        }
        if (current.window.everythingSent) transport.sendJson(Messages.fileDone(current.id))
    }

    private fun closeOutgoing() {
        runCatching { outgoing?.handle?.close() }
        outgoing = null
    }

    // --- Receiving ---------------------------------------------------------------

    fun onOffer(msg: JSONObject) = executor.execute {
        val offer = FileOfferHeader.parse(msg)
        if (offer == null) {
            transport.sendJson(Messages.fileCancel(msg.optString("id"), "protocol"))
            return@execute
        }

        val part = partFile(offer.id)
        val staged = if (part.exists()) part.length() else 0L

        when (val verdict = TransferPlan.verdict(
            offer = offer,
            known = items[offer.id],
            incomingBusy = incoming != null,
            stagedBytes = staged,
            freeBytes = staging.usableSpace
        )) {
            is OfferVerdict.Refuse -> {
                transport.sendJson(Messages.fileCancel(offer.id, verdict.reason))
                items[offer.id]?.let {
                    put(it.copy(state = TransferState.FAILED, detail = explain(verdict.reason)))
                    publish(force = true)
                }
            }

            is OfferVerdict.Begin -> {
                Log.i(
                    TAG,
                    if (verdict.offset > 0) "resuming ${offer.name} at ${verdict.offset} of ${offer.bytes}"
                    else "receiving ${offer.name}, ${offer.bytes} bytes"
                )
                if (verdict.offset == 0L) part.delete()
                val handle = runCatching {
                    RandomAccessFile(part, "rw").apply { setLength(verdict.offset) }
                }.getOrNull()
                if (handle == null) {
                    transport.sendJson(Messages.fileCancel(offer.id, "disk"))
                    return@execute
                }
                handle.seek(verdict.offset)

                incoming = Incoming(offer.id, offer, part, handle, verdict.offset)
                put(
                    (items[offer.id] ?: TransferItem(
                        id = offer.id, direction = TransferDirection.FROM_MAC,
                        name = offer.name, bytes = offer.bytes, mime = offer.mime,
                        sha256 = offer.sha256, startedAt = System.currentTimeMillis()
                    )).copy(
                        state = TransferState.ACTIVE,
                        transferred = verdict.offset,
                        sha256 = offer.sha256,
                        bytes = offer.bytes,
                        detail = null
                    )
                )
                transport.sendJson(Messages.fileBegin(offer.id, verdict.offset))
                publish(force = true)
            }
        }
    }

    /**
     * The body frame belonging to the last `file.chunk` header. Anything that does not
     * line up exactly with what was promised is a protocol error rather than something to
     * write at face value.
     */
    fun onChunk(header: FileChunkHeader, body: ByteArray) = executor.execute {
        val current = incoming
        if (current == null || current.id != header.id ||
            header.offset != current.expected || body.size != header.bytes ||
            current.expected + body.size > current.offer.bytes
        ) {
            abortIncoming(header.id, "protocol", "The Mac sent a chunk out of order")
            return@execute
        }

        val written = runCatching { current.handle.write(body) }.isSuccess
        if (!written) {
            abortIncoming(header.id, "disk", "The file could not be written")
            return@execute
        }

        current.expected += body.size
        current.chunksSinceAck++
        if (TransferPlan.shouldAck(current.chunksSinceAck, current.expected, current.offer.bytes)) {
            current.chunksSinceAck = 0
            transport.sendJson(Messages.fileAck(header.id, current.expected))
        }
        items[header.id]?.let { put(it.copy(transferred = current.expected)) }
        publish()
    }

    fun onDone(msg: JSONObject) = executor.execute {
        val id = msg.optString("id")
        val current = incoming ?: return@execute
        if (current.id != id) return@execute
        runCatching { current.handle.close() }
        incoming = null

        if (current.expected != current.offer.bytes) {
            items[id]?.let {
                put(it.copy(state = TransferState.FAILED, detail = "The Mac stopped part-way through"))
            }
            transport.sendJson(Messages.fileResult(id, false, "short file"))
            publish(force = true)
            return@execute
        }

        items[id]?.let { put(it.copy(state = TransferState.VERIFYING)) }
        publish(force = true)

        hashExecutor.execute {
            val digest = digestOf(current.part)
            executor.execute { settle(current.offer, current.part, digest) }
        }
    }

    private fun settle(offer: FileOfferHeader, part: File, digest: String?) {
        val item = items[offer.id] ?: return
        if (digest != offer.sha256) {
            part.delete()
            put(item.copy(
                state = TransferState.FAILED,
                detail = "Checksum mismatch — the file was not saved"
            ))
            transport.sendJson(Messages.fileResult(offer.id, false, "checksum mismatch"))
            publish(force = true)
            return
        }

        val uri = publishToDownloads(TransferPlan.safeFilename(offer.name), offer.mime, part)
        if (uri == null) {
            put(item.copy(state = TransferState.FAILED, detail = "Could not save it to Downloads"))
            transport.sendJson(Messages.fileResult(offer.id, false, "disk"))
            publish(force = true)
            return
        }

        part.delete()
        val done = item.copy(
            state = TransferState.COMPLETED,
            transferred = item.bytes,
            detail = "Saved to Downloads"
        )
        put(done)
        transport.sendJson(Messages.fileResult(offer.id, true, null))
        onArrived(done, uri)
        onSummary("Saved ${done.name} to Downloads", null)
        publish(force = true)
    }

    fun onCancel(msg: JSONObject) = executor.execute {
        val id = msg.optString("id")
        if (outgoing?.id == id) {
            closeOutgoing()
            File(staging, "$id.src").delete()
        }
        if (incoming?.id == id) closeIncoming(deletePartial = true)
        items[id]?.let {
            put(it.copy(
                state = TransferState.FAILED,
                detail = explain(msg.optString("reason"))
            ))
        }
        publish(force = true)
        startNextSend()
    }

    private fun abortIncoming(id: String, reason: String, message: String) {
        closeIncoming(deletePartial = true)
        items[id]?.let { put(it.copy(state = TransferState.FAILED, detail = message)) }
        transport.sendJson(Messages.fileCancel(id, reason))
        publish(force = true)
    }

    private fun closeIncoming(deletePartial: Boolean) {
        val current = incoming ?: return
        runCatching { current.handle.close() }
        // A pause must leave the partial exactly where it is, or there is nothing to resume.
        if (deletePartial) current.part.delete()
        incoming = null
    }

    /**
     * Into the public Downloads collection, which on API 33+ needs no storage permission
     * at all. `IS_PENDING` keeps a half-written file invisible to every other app until it
     * is whole, and MediaStore numbers a colliding display name itself.
     */
    private fun publishToDownloads(name: String, mime: String, source: File): Uri? =
        runCatching {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return@runCatching null
            resolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { it.copyTo(output, 256 * 1024) }
            } ?: run {
                resolver.delete(uri, null, null)
                return@runCatching null
            }
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
                null, null
            )
            uri
        }.onFailure { Log.w(TAG, "could not publish to Downloads", it) }.getOrNull()

    // --- Plumbing ----------------------------------------------------------------

    private fun partFile(id: String): File {
        // Ids come off the wire — hex only, so they cannot escape the directory.
        val safe = id.filter { it in '0'..'9' || it in 'a'..'f' }
        return File(staging, "$safe.part")
    }

    private fun put(item: TransferItem) {
        items[item.id] = item
    }

    private fun publish(force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && now - lastPublish < 100) return
        lastPublish = now
        onChanged(TransferPlan.presentable(items.values.reversed()))
    }

    /**
     * Partials from a session that never came back. Kept for a week, because a Mac left at
     * the office over the weekend should still resume on Monday.
     */
    fun sweepStaleStaging() = executor.execute {
        val cutoff = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000
        staging.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
    }

    private fun explain(reason: String): String = when (reason) {
        "too_large" -> "Too large — the limit is 2 GB"
        "disk" -> "Not enough room to save it"
        "unsupported" -> "This Mac's build cannot transfer files"
        "busy" -> "Another transfer was already running"
        "gone" -> "The file was no longer there"
        "user" -> "Cancelled"
        else -> "The transfer was refused"
    }

    private fun freshId(): String =
        (0 until 8).joinToString("") { "%02x".format(Random.nextInt(256)) }

    companion object {
        private const val TAG = "TennaFiles"

        /**
         * Streamed rather than hashing a whole `ByteArray`: the point of this feature is
         * files that do not fit comfortably in memory.
         */
        fun digestOf(file: File): String? = runCatching {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1 shl 20)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        }.getOrNull()
    }
}
