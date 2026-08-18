package com.tennanova.clipboard

import android.content.ClipDescription
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.tennanova.core.ClipImageHeader
import com.tennanova.notifications.ClipboardWriteResult
import com.tennanova.notifications.ClipboardWriter
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ClipboardProviderTest {
    @Test fun incomingTextUsesPlainTextMime() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        ClipboardWriter.reset()
        assertTrue(ClipboardWriter.writeText(context, "TennaNova text")
            is ClipboardWriteResult.Written)
        assertTrue(ClipDescription.MIMETYPE_TEXT_PLAIN in ClipboardWriter.lastWrittenMimeTypes)
        // The Mac re-pushes on every reconnect; the second write must not touch the clipboard.
        assertTrue(ClipboardWriter.writeText(context, "TennaNova text")
            === ClipboardWriteResult.Unchanged)
    }

    @Test fun incomingPngIsPublishedThroughReadableContentUri() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val png = Base64.decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
            Base64.DEFAULT
        )
        val hash = ImageTransfer.sha256(png)
        val header = ClipImageHeader("mac", 1, "image/png", png.size, hash, "pixel.png")
        ClipboardWriter.reset()
        val written = ClipboardWriter.writeImage(context, header, png)
        assertTrue(written is ClipboardWriteResult.Written)
        val uri = (written as ClipboardWriteResult.Written).uri!!
        assertTrue(ClipboardWriter.writeImage(context, header, png)
            === ClipboardWriteResult.Unchanged)
        val readBack = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
        assertTrue(uri.scheme == "content")
        assertTrue(context.contentResolver.getType(uri) == "image/png")
        assertTrue("image/png" in ClipboardWriter.lastWrittenMimeTypes)
        assertArrayEquals(png, readBack)
    }
}
