package com.tennanova.clipboard

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.ParcelFileDescriptor
import com.tennanova.core.Proto
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

object ImageTransfer {
    const val MAX_SOURCE_BYTES = 100 * 1024 * 1024
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tenna-image-transfer").apply { isDaemon = true }
    }

    fun prepare(
        context: Context,
        descriptor: ParcelFileDescriptor,
        suggestedMime: String,
        name: String?,
        callback: (Result<PreparedImage>) -> Unit
    ) {
        executor.execute {
            callback(runCatching {
                val temp = File.createTempFile("clipboard-source-", ".img", context.cacheDir)
                try {
                    copyBounded(descriptor, temp)
                    prepareFile(temp, suggestedMime, sanitizeName(name))
                } finally {
                    temp.delete()
                }
            })
        }
    }

    fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    private fun copyBounded(descriptor: ParcelFileDescriptor, destination: File) {
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            FileOutputStream(destination).use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    require(total <= MAX_SOURCE_BYTES) { "Image is larger than 100 MB" }
                    output.write(buffer, 0, count)
                }
            }
        }
    }

    private fun prepareFile(file: File, suggestedMime: String, name: String?): PreparedImage {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0 &&
            bounds.outMimeType?.startsWith("image/") == true &&
            bounds.outWidth <= MAX_IMAGE_EDGE && bounds.outHeight <= MAX_IMAGE_EDGE &&
            bounds.outWidth.toLong() * bounds.outHeight <= MAX_IMAGE_PIXELS
        ) { "Unsupported or unsafe image data" }

        val actualMime = bounds.outMimeType ?: suggestedMime
        if (file.length() <= Proto.MAX_IMAGE_BYTES) {
            val raw = FileInputStream(file).use { it.readBytes() }
            return PreparedImage(raw, actualMime, sha256(raw), name)
        }

        for (edge in intArrayOf(4096, 3072, 2048, 1536, 1024)) {
            val sample = calculateSample(bounds.outWidth, bounds.outHeight, edge)
            val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply {
                inSampleSize = sample
            }) ?: continue
            try {
                val scaled = scaleToEdge(bitmap, edge)
                try {
                    val hasAlpha = scaled.hasAlpha()
                    val encoded = ByteArrayOutputStream().use { output ->
                        val format = if (hasAlpha) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
                        require(scaled.compress(format, if (hasAlpha) 100 else 90, output)) {
                            "Could not optimize image"
                        }
                        output.toByteArray()
                    }
                    if (encoded.size <= Proto.MAX_IMAGE_BYTES) {
                        val mime = if (hasAlpha) "image/png" else "image/jpeg"
                        return PreparedImage(encoded, mime, sha256(encoded), name)
                    }
                } finally {
                    if (scaled !== bitmap) scaled.recycle()
                }
            } finally {
                bitmap.recycle()
            }
        }
        error("Image could not be reduced below 25 MB")
    }

    private fun calculateSample(width: Int, height: Int, edge: Int): Int {
        var sample = 1
        while (maxOf(width / sample, height / sample) > edge * 2) sample *= 2
        return sample
    }

    private fun scaleToEdge(bitmap: Bitmap, edge: Int): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= edge) return bitmap
        val scale = edge.toFloat() / longest
        return Bitmap.createScaledBitmap(
            bitmap,
            maxOf(1, (bitmap.width * scale).toInt()),
            maxOf(1, (bitmap.height * scale).toInt()),
            true
        )
    }

    private fun sanitizeName(name: String?): String? = name
        ?.substringAfterLast('/')
        ?.substringAfterLast('\\')
        ?.take(120)
        ?.takeIf { it.isNotBlank() }

    private const val MAX_IMAGE_EDGE = 32_768
    private const val MAX_IMAGE_PIXELS = 100_000_000L
}
