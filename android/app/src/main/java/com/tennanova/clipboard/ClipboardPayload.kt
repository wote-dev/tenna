package com.tennanova.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.net.Uri

enum class ClipboardAccessStatus {
    NEEDS_ACCESSIBILITY,
    READY,
    ERROR
}

sealed interface ClipboardPayload {
    val fingerprint: String

    data class Text(val value: String) : ClipboardPayload {
        override val fingerprint: String = "text:$value"
    }

    data class ImageReference(
        val uri: Uri,
        val mime: String,
        val name: String?
    ) : ClipboardPayload {
        override val fingerprint: String = "uri:$uri"
    }

    companion object {
        fun fromClip(context: Context, clip: ClipData?): ClipboardPayload? {
            if (clip == null || clip.itemCount == 0) return null
            val item = clip.getItemAt(0) ?: return null
            val imageMime = (0 until clip.description.mimeTypeCount)
                .map { clip.description.getMimeType(it) }
                .firstOrNull { ClipDescription.compareMimeTypes(it, "image/*") }
            val uri = item.uri
            if (uri != null && uri.scheme == "content" && imageMime != null) {
                return ImageReference(
                    uri = uri,
                    mime = imageMime,
                    name = clip.description.label?.toString()?.takeIf { it.isNotBlank() }
                )
            }
            val text = item.text?.toString()
                ?: item.coerceToText(context)?.toString()
            return text?.takeIf { it.isNotEmpty() }?.let(::Text)
        }
    }
}

data class PreparedImage(
    val bytes: ByteArray,
    val mime: String,
    val sha256: String,
    val name: String?
)
