package com.tennanova.mirror

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.tennanova.R
import com.tennanova.clipboard.TennaAccessibilityService
import com.tennanova.core.Messages
import com.tennanova.core.RuntimeStatusStore
import com.tennanova.net.ConnectionTransport
import com.tennanova.ui.MainActivity
import org.json.JSONObject
import java.util.UUID

enum class MirrorPhase(val wire: String) {
    IDLE("idle"),
    APPROVAL_REQUIRED("approval_required"),
    STARTING("starting"),
    STREAMING("streaming"),
    STOPPING("stopping"),
    STOPPED("stopped"),
    ERROR("error")
}

data class MirrorSnapshot(
    val phase: MirrorPhase = MirrorPhase.IDLE,
    val requestId: String? = null,
    val sessionId: String? = null,
    val reason: String? = null,
    val peerSupported: Boolean = false,
    val controlAvailable: Boolean = false
) {
    val isActive: Boolean
        get() = phase in setOf(
            MirrorPhase.APPROVAL_REQUIRED,
            MirrorPhase.STARTING,
            MirrorPhase.STREAMING,
            MirrorPhase.STOPPING
        )
}

/**
 * Process-wide handshake between the notification listener, Activity and projection service.
 * It owns no capture resources; [MirrorProjectionService] remains the single lifecycle owner.
 */
object MirrorSessionCoordinator {
    private val lock = Any()
    private var snapshot = MirrorSnapshot()
    private var sender: ((JSONObject) -> Boolean)? = null
    private var transport: ConnectionTransport = ConnectionTransport.NONE

    fun attachSender(block: ((JSONObject) -> Boolean)?) = synchronized(lock) {
        sender = block
    }

    fun updateConnection(peerSupported: Boolean, route: ConnectionTransport) {
        synchronized(lock) {
            transport = route
            snapshot = snapshot.copy(
                peerSupported = peerSupported,
                controlAvailable = TennaAccessibilityService.isReady
            )
            publishLocked(sendWire = snapshot.isActive)
        }
    }

    fun current(): MirrorSnapshot = synchronized(lock) { snapshot }

    /** Returns the request id when Android may launch the system approval UI. */
    fun beginFromPhone(): String? = synchronized(lock) {
        if (!canStartLocked()) return null
        val requestId = UUID.randomUUID().toString()
        snapshot = snapshot.copy(
            phase = MirrorPhase.APPROVAL_REQUIRED,
            requestId = requestId,
            sessionId = null,
            reason = null,
            controlAvailable = controlAvailableLocked()
        )
        publishLocked()
        requestId
    }

    fun requestFromMac(context: Context, requestId: String) = synchronized(lock) {
        if (!isSafeId(requestId)) {
            failLocked("encoder_failed", requestId)
            return
        }
        if (transport == ConnectionTransport.RELAY || transport == ConnectionTransport.NONE) {
            failLocked("not_local", requestId)
            return
        }
        if (!snapshot.peerSupported) {
            failLocked("control_unavailable", requestId)
            return
        }
        if (snapshot.isActive) {
            publishLocked()
            return
        }
        snapshot = snapshot.copy(
            phase = MirrorPhase.APPROVAL_REQUIRED,
            requestId = requestId,
            sessionId = null,
            reason = null,
            controlAvailable = controlAvailableLocked()
        )
        publishLocked()
        MirrorNotifications.showApproval(context, requestId)
    }

    /** Called only after Android returned RESULT_OK for the currently pending request. */
    fun approved(requestId: String): String? = synchronized(lock) {
        if (snapshot.phase != MirrorPhase.APPROVAL_REQUIRED || snapshot.requestId != requestId) {
            return null
        }
        val sessionId = UUID.randomUUID().toString()
        snapshot = snapshot.copy(
            phase = MirrorPhase.STARTING,
            sessionId = sessionId,
            reason = null,
            controlAvailable = controlAvailableLocked()
        )
        MirrorNotifications.cancelApproval(RuntimeStatusStore.context)
        publishLocked()
        sessionId
    }

    fun permissionDenied(requestId: String) = synchronized(lock) {
        if (snapshot.requestId != requestId) return
        failLocked("permission_denied", requestId)
    }

    fun streaming(sessionId: String) = synchronized(lock) {
        if (snapshot.sessionId != sessionId) return
        snapshot = snapshot.copy(
            phase = MirrorPhase.STREAMING,
            reason = null,
            controlAvailable = controlAvailableLocked()
        )
        publishLocked()
    }

    fun stopping(sessionId: String?) = synchronized(lock) {
        if (sessionId != null && snapshot.sessionId != sessionId) return
        if (!snapshot.isActive) return
        snapshot = snapshot.copy(phase = MirrorPhase.STOPPING)
        publishLocked()
    }

    fun stopped(reason: String, sessionId: String? = null) = synchronized(lock) {
        if (sessionId != null && snapshot.sessionId != sessionId) return
        MirrorNotifications.cancelApproval(RuntimeStatusStore.context)
        snapshot = snapshot.copy(phase = MirrorPhase.STOPPED, reason = reason)
        publishLocked()
        snapshot = snapshot.copy(
            phase = MirrorPhase.IDLE,
            requestId = null,
            sessionId = null
        )
        publishLocked(sendWire = false)
    }

    fun fail(reason: String, sessionId: String? = null) = synchronized(lock) {
        if (sessionId != null && snapshot.sessionId != sessionId) return
        failLocked(reason, snapshot.requestId)
    }

    fun cancel(context: Context, reason: String = "user", sessionId: String? = null) {
        synchronized(lock) {
            if (sessionId != null && snapshot.sessionId != sessionId) return
            val activeSession = snapshot.sessionId
            if (activeSession == null) {
                stopped(reason)
                return
            }
            snapshot = snapshot.copy(phase = MirrorPhase.STOPPING, reason = reason)
            publishLocked()
            ContextCompat.startForegroundService(
                context,
                Intent(context, MirrorProjectionService::class.java)
                    .setAction(MirrorProjectionService.ACTION_STOP)
                    .putExtra(MirrorProjectionService.EXTRA_REASON, reason)
            )
        }
    }

    fun refreshControlAvailability() = synchronized(lock) {
        val available = controlAvailableLocked()
        if (snapshot.controlAvailable == available) return
        snapshot = snapshot.copy(controlAvailable = available)
        publishLocked(sendWire = snapshot.isActive)
    }

    private fun canStartLocked(): Boolean =
        snapshot.peerSupported && !snapshot.isActive &&
            transport != ConnectionTransport.NONE && transport != ConnectionTransport.RELAY

    private fun controlAvailableLocked(): Boolean =
        TennaAccessibilityService.isReady

    private fun failLocked(reason: String, requestId: String?) {
        MirrorNotifications.cancelApproval(RuntimeStatusStore.context)
        snapshot = snapshot.copy(
            phase = MirrorPhase.ERROR,
            requestId = requestId,
            sessionId = null,
            reason = reason,
            controlAvailable = controlAvailableLocked()
        )
        publishLocked()
    }

    private fun publishLocked(sendWire: Boolean = true) {
        RuntimeStatusStore.updateMirror(snapshot)
        if (sendWire) {
            sender?.invoke(
                Messages.mirrorState(
                    state = snapshot.phase.wire,
                    requestId = snapshot.requestId,
                    sessionId = snapshot.sessionId,
                    controlAvailable = snapshot.controlAvailable,
                    reason = snapshot.reason
                )
            )
        }
    }

    private fun isSafeId(value: String): Boolean =
        value.length in 8..64 && value.all { it.isLetterOrDigit() || it == '-' }
}

object MirrorNotifications {
    const val CHANNEL = "screen_mirroring"
    const val APPROVAL_ID = 4101
    const val ACTIVE_ID = 4102

    fun createChannel(context: Context) {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Screen mirroring", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    fun showApproval(context: Context, requestId: String) {
        createChannel(context)
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        val open = PendingIntent.getActivity(
            context,
            requestId.hashCode(),
            Intent(context, MainActivity::class.java)
                .putExtra(MainActivity.EXTRA_MIRROR_REQUEST_ID, requestId)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Share your screen with your Mac?")
            .setContentText("Tap to review Android's screen-sharing prompt.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(APPROVAL_ID, notification)
    }

    fun cancelApproval(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(APPROVAL_ID)
    }
}
