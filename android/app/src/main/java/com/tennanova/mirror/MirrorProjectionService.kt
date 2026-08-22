package com.tennanova.mirror

import android.app.Activity
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.tennanova.R
import com.tennanova.core.Settings
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

class MirrorProjectionService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val stopping = AtomicBoolean(false)
    private lateinit var settings: Settings
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: MirrorH264Encoder? = null
    private var video: MirrorVideoClient? = null
    private var config: MirrorCodecConfig? = null
    private var sessionId: String? = null
    private var generation = 0
    private var rotation = -1
    private var bitrate: MirrorBitrateController? = null
    private var recovering = false
    private var authenticated = false
    private var disconnectDeadline: Long? = null

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            stopSession(if (isScreenOn()) "projection_stopped" else "phone_locked")
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) stopSession("phone_locked")
        }
    }

    private val maintenance = object : Runnable {
        override fun run() {
            if (stopping.get()) return
            val now = SystemClock.elapsedRealtime()
            updateRotationIfNeeded()
            val queued = video?.queuedBytes ?: 0
            bitrate?.sample(queued, now)?.let { encoder?.setBitrate(it) }
            if (queued > MirrorBitrateController.RECOVERY_QUEUE && !recovering) {
                recovering = true
                encoder?.requestKeyFrame()
            }
            disconnectDeadline?.let { if (now >= it) stopSession("transport_lost") }
            handler.postDelayed(this, 500)
        }
    }

    override fun onCreate() {
        super.onCreate()
        active = WeakReference(this)
        settings = Settings(this)
        MirrorNotifications.createChannel(this)
        registerReceiver(screenReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSession(intent.getStringExtra(EXTRA_REASON) ?: "user")
                return START_NOT_STICKY
            }
            ACTION_START -> startCapture(intent)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        handler.removeCallbacks(maintenance)
        runCatching { unregisterReceiver(screenReceiver) }
        if (stopping.compareAndSet(false, true)) {
            val id = sessionId
            MirrorSessionCoordinator.stopping(id)
            releaseResources()
            MirrorSessionCoordinator.stopped("projection_stopped", id)
        } else {
            releaseResources()
        }
        if (active.get() === this) active.clear()
        super.onDestroy()
    }

    private fun startCapture(intent: Intent) {
        if (projection != null || stopping.get()) return
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return stopSession("encoder_failed")
        val expectedSession = intent.getStringExtra(EXTRA_SESSION_ID) ?: return stopSession("encoder_failed")
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val resultData = intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
            ?: return stopSession("permission_denied")
        if (resultCode != Activity.RESULT_OK || MirrorSessionCoordinator.current().sessionId != expectedSession) {
            return stopSession("permission_denied")
        }
        sessionId = expectedSession

        val notification = activeNotification(settings.macName ?: "your Mac")
        ServiceCompat.startForeground(
            this,
            MirrorNotifications.ACTIVE_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        )

        try {
            val manager = getSystemService(MediaProjectionManager::class.java)
            projection = manager.getMediaProjection(resultCode, resultData).also {
                it.registerCallback(projectionCallback, handler)
            }
            configureEncoder(createDisplay = true)
            startVideo(expectedSession)
            handler.post(maintenance)
            Log.i(TAG, "screen projection approved request=$requestId session=$expectedSession")
        } catch (error: Throwable) {
            Log.e(TAG, "screen projection failed", error)
            stopSession("encoder_failed")
        }
    }

    private fun startVideo(id: String) {
        video = MirrorVideoClient(
            context = this,
            settings = settings,
            sessionId = id,
            onAuthenticated = {
                authenticated = true
                disconnectDeadline = null
                config?.let { current ->
                    if (video?.sendConfig(current, generation) == true) {
                        encoder?.requestKeyFrame()
                        MirrorSessionCoordinator.streaming(id)
                    }
                }
            },
            onAvailability = { available ->
                authenticated = available
                if (available) {
                    disconnectDeadline = null
                } else if (!stopping.get()) {
                    if (disconnectDeadline == null) {
                        disconnectDeadline = SystemClock.elapsedRealtime() + DISCONNECT_GRACE_MS
                    }
                }
            },
            onFailure = {
                Log.w(TAG, "video stream failure: $it")
                stopSession("transport_lost")
            }
        ).also { it.start() }
    }

    private fun configureEncoder(createDisplay: Boolean) {
        val metrics = captureMetrics()
        val size = MirrorSize.fit(metrics.bounds.width(), metrics.bounds.height())
        rotation = metrics.rotation
        generation = (generation + 1) and 0xffff
        val currentGeneration = generation
        var nextSequence = 0L
        config = null
        recovering = false
        val initialBitrate = MirrorSize.initialBitrate(size.width, size.height)
        bitrate = MirrorBitrateController(initialBitrate)

        val next = MirrorH264Encoder(
            size = size,
            initialBitrate = initialBitrate,
            rotation = rotation,
            onConfig = { nextConfig ->
                if (generation == currentGeneration) {
                    config = nextConfig
                    if (authenticated && video?.sendConfig(nextConfig, currentGeneration) == true) {
                        handler.post {
                            if (generation == currentGeneration) encoder?.requestKeyFrame()
                        }
                        sessionId?.let(MirrorSessionCoordinator::streaming)
                    }
                }
            },
            onFrame = { bytes, ptsUs, keyframe ->
                sendFrame(
                    bytes,
                    ptsUs,
                    keyframe,
                    currentGeneration,
                    nextSequence++ and 0xffff_ffffL
                )
            },
            onError = {
                Log.e(TAG, "encoder failed", it)
                handler.post { stopSession("encoder_failed") }
            }
        )
        next.start()

        val currentProjection = projection ?: error("Projection missing")
        if (createDisplay) {
            virtualDisplay = currentProjection.createVirtualDisplay(
                "Tennanova mirror",
                size.width,
                size.height,
                metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                next.surface,
                null,
                handler
            )
        } else {
            virtualDisplay?.setSurface(null)
            encoder?.stop()
            virtualDisplay?.resize(size.width, size.height, metrics.densityDpi)
            virtualDisplay?.setSurface(next.surface)
        }
        encoder = next
    }

    private fun sendFrame(
        bytes: ByteArray,
        ptsUs: Long,
        keyframe: Boolean,
        frameGeneration: Int,
        frameSequence: Long
    ) {
        if (frameGeneration != generation) return
        if (!authenticated) return
        if (recovering && !keyframe) return
        if (keyframe) recovering = false
        val packet = MirrorVideoPacket.encode(
            generation = frameGeneration,
            sequence = frameSequence,
            presentationTimeUs = ptsUs,
            keyframe = keyframe,
            accessUnit = bytes
        )
        if (video?.sendFrame(packet) != true) {
            authenticated = false
        }
    }

    private fun updateRotationIfNeeded() {
        if (projection == null || stopping.get()) return
        if (captureMetrics().rotation == rotation) return
        runCatching { configureEncoder(createDisplay = false) }
            .onFailure {
                Log.e(TAG, "could not reconfigure after rotation", it)
                stopSession("encoder_failed")
            }
    }

    private data class CaptureMetrics(val bounds: Rect, val densityDpi: Int, val rotation: Int)

    private fun captureMetrics(): CaptureMetrics {
        val bounds = getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
        val display = getSystemService(DisplayManager::class.java)
            .getDisplay(Display.DEFAULT_DISPLAY)
        return CaptureMetrics(
            Rect(bounds),
            resources.displayMetrics.densityDpi,
            display?.rotation ?: 0
        )
    }

    private fun activeNotification(macName: String): Notification {
        val stop = PendingIntent.getService(
            this,
            0,
            Intent(this, MirrorProjectionService::class.java)
                .setAction(ACTION_STOP)
                .putExtra(EXTRA_REASON, "user"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, MirrorNotifications.CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Sharing screen with $macName")
            .setContentText("Your phone stays unlocked while mirroring is active.")
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(0, "Stop", stop)
            .build()
    }

    private fun stopSession(reason: String) {
        if (!stopping.compareAndSet(false, true)) return
        val id = sessionId
        handler.removeCallbacks(maintenance)
        MirrorSessionCoordinator.stopping(id)
        releaseResources()
        MirrorSessionCoordinator.stopped(reason, id)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun releaseResources() {
        authenticated = false
        video?.stop()
        video = null
        virtualDisplay?.release()
        virtualDisplay = null
        encoder?.stop()
        encoder = null
        projection?.unregisterCallback(projectionCallback)
        projection?.stop()
        projection = null
    }

    private fun isScreenOn(): Boolean =
        getSystemService(android.os.PowerManager::class.java).isInteractive

    companion object {
        const val ACTION_START = "com.tennanova.mirror.START"
        const val ACTION_STOP = "com.tennanova.mirror.STOP"
        const val EXTRA_REQUEST_ID = "requestId"
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_REASON = "reason"
        private const val DISCONNECT_GRACE_MS = 10_000L
        private const val TAG = "TennaMirror"
        private var active = WeakReference<MirrorProjectionService>(null)

        fun requestKeyFrame(sessionId: String) {
            active.get()?.takeIf { it.sessionId == sessionId }?.encoder?.requestKeyFrame()
        }
    }
}
