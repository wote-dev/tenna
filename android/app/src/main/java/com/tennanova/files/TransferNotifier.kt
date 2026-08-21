package com.tennanova.files

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.ContextCompat

/**
 * Says a file arrived.
 *
 * The socket lives in a bound service with no UI, so a file pushed from the Mac while the
 * phone is in a pocket lands in Downloads with nothing to show for it. This is the only
 * thing that tells anyone it happened.
 *
 * `POST_NOTIFICATIONS` is a runtime permission from API 33, and this build's minSdk is 33 —
 * so it is always a question, never a given. Everything degrades to the dashboard's own
 * list when it is denied, which is why nothing here throws or nags.
 */
class TransferNotifier(private val context: Context) {

    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        runCatching {
            manager?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "Received files",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "Files sent from your Mac."
                }
            )
        }
    }

    fun arrived(item: TransferItem, uri: Uri) {
        if (!allowed()) return

        // A read grant on the notification's own intent, so tapping it opens the file in
        // whatever app handles the type without this app holding any storage permission.
        val open = PendingIntent.getActivity(
            context,
            item.id.hashCode(),
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, item.mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(item.name)
            .setContentText("Saved to Downloads")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()

        runCatching { manager?.notify(item.id.hashCode(), notification) }
    }

    private fun allowed(): Boolean =
        ContextCompat.checkSelfPermission(
            context, android.Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED

    private companion object {
        const val CHANNEL = "tenna_files"
    }
}
