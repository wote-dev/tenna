package com.tennanova.notifications

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.core.content.FileProvider
import com.tennanova.core.ClipImageHeader
import com.tennanova.core.Proto
import java.io.File

/**
 * Outcome of a clipboard write requested by the Mac.
 *
 * `Unchanged` is the one that matters: Android 13+ shows its own "Copied" panel on every
 * `setPrimaryClip`, so re-applying content the clipboard already holds is loud and
 * pointless. The Mac pushes its clipboard on every `hello`, which makes a repeat the
 * normal case rather than an edge one.
 */
sealed interface ClipboardWriteResult {
    data class Written(val uri: Uri?) : ClipboardWriteResult
    data object Unchanged : ClipboardWriteResult
    data class Failed(val error: Throwable) : ClipboardWriteResult
}

/** Writes text or one image received from the Mac to Android's system clipboard. */
object ClipboardWriter {

    private const val TAG = "TennaNova"
    private const val AUTHORITY = "com.tennanova.clipboard"

    @Volatile
    var lastWrittenFingerprint: String? = null
        private set

    /** Exact MIME set most recently handed to ClipboardManager; useful for status/tests. */
    @Volatile
    var lastWrittenMimeTypes: List<String> = emptyList()
        private set

    /**
     * Content hash of the image most recently written. Tracked separately because the
     * repeat has to be recognised before the file — and therefore the URI the
     * fingerprint is built from — exists.
     */
    @Volatile
    private var lastWrittenImageSha256: String? = null

    /**
     * Records what the *phone* just put on its own clipboard and sent to the Mac.
     *
     * Without this the guard only knows about content it wrote itself, so the Mac re-pushing
     * a clip that started on the phone — which it does on every reconnect — lands as a fresh
     * write, and Android raises its "Copied" panel a second time for something the user
     * copied once. The image hash travels separately because outbound images are identified
     * by a `content://` URI and inbound ones by their SHA-256; neither ever matches the other.
     */
    fun noteLocalClip(fingerprint: String, imageSha256: String? = null) {
        lastWrittenFingerprint = fingerprint
        lastWrittenImageSha256 = imageSha256
    }

    /**
     * Forgets the echo-suppression state. Called when the peer changes, so a freshly
     * paired Mac can always push its clipboard through once.
     */
    fun reset() {
        lastWrittenFingerprint = null
        lastWrittenMimeTypes = emptyList()
        lastWrittenImageSha256 = null
    }

    fun writeText(context: Context, text: String): ClipboardWriteResult {
        val fingerprint = "text:$text"
        // Reading primaryClip here to compare would trigger Android's "pasted from"
        // toast, trading one kind of spam for another — what we last wrote is enough.
        if (lastWrittenFingerprint == fingerprint) return ClipboardWriteResult.Unchanged
        return try {
            val cm = context.getSystemService(ClipboardManager::class.java)
            val clip = ClipData.newPlainText("Tennanova", text)
            lastWrittenFingerprint = fingerprint
            lastWrittenMimeTypes = clip.mimeTypes()
            lastWrittenImageSha256 = null
            cm.setPrimaryClip(clip)
            clearImageCache(context)
            Log.i(TAG, "clipboard from Mac applied (${text.length} chars)")
            ClipboardWriteResult.Written(null)
        } catch (e: Exception) {
            Log.e(TAG, "failed to write clipboard", e)
            ClipboardWriteResult.Failed(e)
        }
    }

    fun writeImage(
        context: Context,
        header: ClipImageHeader,
        bytes: ByteArray
    ): ClipboardWriteResult {
        if (lastWrittenImageSha256 == header.sha256) return ClipboardWriteResult.Unchanged
        return runCatching {
            require(header.isValid && bytes.size == header.bytes &&
                bytes.size <= Proto.MAX_IMAGE_BYTES) { "invalid image payload" }
            val actualHash = com.tennanova.clipboard.ImageTransfer.sha256(bytes)
            require(actualHash == header.sha256) { "image hash mismatch" }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            require(bounds.outWidth > 0 && bounds.outHeight > 0 &&
                bounds.outMimeType?.startsWith("image/") == true &&
                bounds.outWidth <= MAX_IMAGE_EDGE && bounds.outHeight <= MAX_IMAGE_EDGE &&
                bounds.outWidth.toLong() * bounds.outHeight <= MAX_IMAGE_PIXELS
            ) { "unsupported or unsafe image data" }

            val dir = File(context.cacheDir, "clipboard").apply { mkdirs() }
            dir.listFiles()?.forEach { it.delete() }
            val extension = when (header.mime.lowercase()) {
                "image/png" -> "png"
                "image/jpeg", "image/jpg" -> "jpg"
                "image/webp" -> "webp"
                "image/gif" -> "gif"
                "image/heic", "image/heif" -> "heic"
                "image/avif" -> "avif"
                "image/bmp", "image/x-ms-bmp" -> "bmp"
                "image/tiff" -> "tiff"
                else -> "img"
            }
            val file = File(dir, "${header.sha256}.$extension")
            file.outputStream().use { it.write(bytes) }

            val uri = FileProvider.getUriForFile(context, AUTHORITY, file)
            val label = header.name ?: "Tennanova image"
            val clip = ClipData.newUri(context.contentResolver, label, uri)
            lastWrittenFingerprint = "uri:$uri"
            lastWrittenMimeTypes = clip.mimeTypes()
            lastWrittenImageSha256 = header.sha256
            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
            Log.i(TAG, "clipboard image from Mac applied (${bytes.size} bytes)")
            uri
        }.fold(
            onSuccess = { ClipboardWriteResult.Written(it) },
            onFailure = {
                Log.e(TAG, "failed to write clipboard image", it)
                ClipboardWriteResult.Failed(it)
            }
        )
    }

    private fun clearImageCache(context: Context) {
        File(context.cacheDir, "clipboard").listFiles()?.forEach { it.delete() }
    }

    private fun ClipData.mimeTypes(): List<String> =
        (0 until description.mimeTypeCount).map(description::getMimeType)

    private const val MAX_IMAGE_EDGE = 32_768
    private const val MAX_IMAGE_PIXELS = 100_000_000L
}
