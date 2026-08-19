package com.tennanova.clipboard

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import com.tennanova.core.ConnectionStatus
import com.tennanova.core.RuntimeStatusStore

/**
 * Detects copy-related UI events and briefly owns a non-touchable accessibility window.
 * Android allows the focused UID to read the clipboard; the window exists only long enough
 * to perform that single read and is removed immediately afterwards.
 *
 * The service never retrieves the accessibility node tree. It receives only event metadata,
 * reads the system clipboard after an explicit user copy action, fingerprints the result, and
 * forwards new text or image references to the already-authenticated local Mac session.
 */
class TennaAccessibilityService : AccessibilityService() {

    private val handler = Handler(Looper.getMainLooper())
    private val copySignals = CopySignalDetector()
    private var overlay: View? = null
    private var captureScheduled = false
    private var lastCaptureAt = 0L
    private var lastClipStamp = UNKNOWN_CLIP_STAMP
    private var lastSeenFingerprint: String? = null
    private val clipboardRead = Runnable(::readClipboardAndRemoveOverlay)
    private val captureRequest = Runnable {
        captureScheduled = false
        requestClipboardFocus()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        // Adopt whatever is already on the clipboard as the baseline, so connecting doesn't
        // look like a fresh copy.
        lastClipStamp = currentClipStamp() ?: UNKNOWN_CLIP_STAMP
        RuntimeStatusStore.updateClipboard(ClipboardAccessStatus.READY)
        Log.i(TAG, "accessibility clipboard service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val copySignal = isLikelyCopySignal(event)
        if (RuntimeStatusStore.state.value.connection != ConnectionStatus.CONNECTED) {
            // Worth a line: "I copied something and nothing happened" is otherwise invisible.
            if (copySignal) Log.i(TAG, "copy ignored — no Mac session")
            return
        }
        // A moved clip timestamp is proof a copy happened, whatever gesture produced it. The
        // gesture heuristics stay as the fallback for when the platform withholds it.
        val proof = clipboardStampMoved()
        if (!proof && !copySignal) return
        Log.i(
            TAG,
            "copy signal type=${AccessibilityEvent.eventTypeToString(event.eventType)} " +
                "package=${event.packageName} clipStampMoved=$proof"
        )
        scheduleCapture()
    }

    override fun onInterrupt() {
        removeOverlay()
        Log.w(TAG, "accessibility clipboard service interrupted")
    }

    override fun onDestroy() {
        removeOverlay()
        super.onDestroy()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        removeOverlay()
        RuntimeStatusStore.updateClipboard(ClipboardAccessStatus.NEEDS_ACCESSIBILITY)
        return super.onUnbind(intent)
    }

    private fun isLikelyCopySignal(event: AccessibilityEvent): Boolean =
        copySignals.isCopySignal(event.copyFacts(), android.os.SystemClock.elapsedRealtime())

    /**
     * The clip's metadata timestamp, which moves on every real copy.
     *
     * `getPrimaryClipDescription` reads metadata rather than content, so where the platform
     * allows it in the background it costs neither focus nor a "pasted from" toast. Returns
     * null when it is withheld, and detection falls back to the gesture heuristics.
     */
    private fun currentClipStamp(): Long? = runCatching {
        getSystemService(ClipboardManager::class.java).primaryClipDescription?.timestamp
    }.getOrNull()

    private fun clipboardStampMoved(): Boolean {
        val stamp = currentClipStamp() ?: return false
        if (stamp == lastClipStamp || lastClipStamp == UNKNOWN_CLIP_STAMP) {
            lastClipStamp = stamp
            return false
        }
        lastClipStamp = stamp
        return true
    }

    private fun scheduleCapture() {
        val now = android.os.SystemClock.elapsedRealtime()
        if (captureScheduled || now - lastCaptureAt < CAPTURE_COOLDOWN_MS) return
        captureScheduled = true
        handler.postDelayed(captureRequest, EVENT_SETTLE_MS)
    }

    private fun requestClipboardFocus() {
        if (overlay != null || RuntimeStatusStore.state.value.connection != ConnectionStatus.CONNECTED) {
            return
        }
        if (getSystemService(KeyguardManager::class.java).isDeviceLocked) return
        val windowManager = getSystemService(WindowManager::class.java)
        val view = View(this).apply {
            alpha = 0f
            isFocusable = true
            isFocusableInTouchMode = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        val params = WindowManager.LayoutParams(
            1,
            1,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                // The window has to take focus — that is the whole reason it exists — but it
                // must not become the *input method's* target while it does. Without this the
                // IME unbinds from whatever the user was typing in and the keyboard drops,
                // in every app on the phone, every time a copy is read.
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = 0
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_UNCHANGED
            title = "Tennanova clipboard read"
        }

        runCatching {
            overlay = view
            windowManager.addView(view, params)
            view.requestFocus()
            handler.postDelayed(clipboardRead, FOCUS_SETTLE_MS)
        }.onFailure { error ->
            overlay = null
            RuntimeStatusStore.updateClipboard(
                ClipboardAccessStatus.ERROR,
                "Clipboard focus window failed: ${error.message}"
            )
            Log.e(TAG, "could not create clipboard focus window", error)
        }
    }

    private fun readClipboardAndRemoveOverlay() {
        try {
            if (getSystemService(KeyguardManager::class.java).isDeviceLocked) return
            lastCaptureAt = android.os.SystemClock.elapsedRealtime()
            val manager = getSystemService(ClipboardManager::class.java)
            val payload = ClipboardPayload.fromClip(this, manager.primaryClip)
            RuntimeStatusStore.updateClipboard(ClipboardAccessStatus.READY)
            if (payload == null) {
                Log.w(TAG, "focused clipboard read returned no supported content")
                return
            }
            if (payload.fingerprint == lastSeenFingerprint ||
                payload.fingerprint == com.tennanova.notifications.ClipboardWriter.lastWrittenFingerprint) {
                lastSeenFingerprint = payload.fingerprint
                return
            }
            lastSeenFingerprint = payload.fingerprint
            RuntimeStatusStore.clipboardChanged(payload)
            Log.i(TAG, "captured ${if (payload is ClipboardPayload.Text) "text" else "image"} clipboard")
        } catch (error: Throwable) {
            RuntimeStatusStore.updateClipboard(
                ClipboardAccessStatus.ERROR,
                "Clipboard read failed: ${error.message}"
            )
            Log.w(TAG, "clipboard read failed", error)
        } finally {
            removeOverlay()
        }
    }

    private fun removeOverlay() {
        handler.removeCallbacks(captureRequest)
        handler.removeCallbacks(clipboardRead)
        captureScheduled = false
        val view = overlay ?: return
        overlay = null
        runCatching { getSystemService(WindowManager::class.java).removeViewImmediate(view) }
    }

    companion object {
        private const val TAG = "TennaClipboard"
        private const val EVENT_SETTLE_MS = 80L
        private const val FOCUS_SETTLE_MS = 32L
        private const val CAPTURE_COOLDOWN_MS = 250L
        private const val UNKNOWN_CLIP_STAMP = -1L

        fun isEnabled(context: Context): Boolean {
            val expected = ComponentName(context, TennaAccessibilityService::class.java)
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ).orEmpty()
            return enabled.split(':').any { ComponentName.unflattenFromString(it) == expected }
        }
    }
}
