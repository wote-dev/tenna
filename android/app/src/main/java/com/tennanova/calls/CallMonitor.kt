package com.tennanova.calls

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.telecom.TelecomManager
import android.util.Log

/** The three `CallStyle` intents, any of which a given notification may omit. */
data class CallIntents(
    val answer: PendingIntent? = null,
    val decline: PendingIntent? = null,
    val hangUp: PendingIntent? = null
)

/**
 * Every call this phone is currently showing, and the two ways of acting on one.
 *
 * Answering resolves in a fixed order, and the order is the whole design:
 *
 *  1. **The notification's own intent.** `Notification.CallStyle` puts answer, decline and
 *     hang-up `PendingIntent`s in the notification's extras, and firing one is exactly what
 *     pressing that button on the phone does. It needs no permission, and it works for
 *     WhatsApp and Signal calls as much as for cellular ones.
 *  2. **`TelecomManager`**, behind the optional `ANSWER_PHONE_CALLS` grant. This is the
 *     fallback for a dialer whose notification carries no intents — some OEM dialers build
 *     their incoming-call UI entirely out of a full-screen intent — and it only covers
 *     calls Telecom manages.
 *
 * What is deliberately absent is muting. Muting a call needs an `InCallService`, which
 * needs the default-dialer role, and shipping a button that silently does nothing is worse
 * than shipping no button.
 *
 * Audio is not part of this and cannot be: no third-party app may capture voice-call audio
 * on Android. The Mac is the control surface; the sound stays on the phone.
 */
class CallMonitor(private val context: Context) {

    private class Live(
        var snapshot: CallSnapshot,
        var intents: CallIntents,
        /** How this call was first seen, which is the only evidence of its direction. */
        val direction: CallDirection
    )

    private val calls = object : LinkedHashMap<String, Live>(0, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, Live>) = size > MAX_CALLS
    }

    /** Whether this phone may answer and end calls itself, rather than only pressing the
     *  notification's own buttons. Optional, and re-read every time: the user can revoke it
     *  in Settings without the app being restarted. */
    fun hasCallControl(): Boolean =
        context.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Records a call notification and returns what the Mac should be told about it.
     *
     * [snapshot] arrives without its capability flags or its direction: the caller reads
     * the notification, and this decides what can actually be done about it.
     */
    fun onPosted(snapshot: CallSnapshot, intents: CallIntents): CallSnapshot {
        val existing = calls[snapshot.id]
        val direction = existing?.direction
            ?: if (snapshot.state == CallState.RINGING) CallDirection.INCOMING
               else CallDirection.OUTGOING
        val control = hasCallControl()
        val resolved = snapshot.copy(
            direction = direction,
            canAnswer = snapshot.state == CallState.RINGING &&
                (intents.answer != null || control),
            canDecline = snapshot.state == CallState.RINGING &&
                (intents.decline != null || control),
            canHangUp = snapshot.state == CallState.ACTIVE &&
                (intents.hangUp != null || control)
        )
        if (existing == null) {
            calls[snapshot.id] = Live(resolved, intents, direction)
        } else {
            existing.snapshot = resolved
            // Merged, not replaced: an app that reposts its ongoing-call notification
            // usually drops the answer intent it no longer needs, and a repost must not
            // take away a hang-up we were relying on.
            existing.intents = CallIntents(
                answer = intents.answer ?: existing.intents.answer,
                decline = intents.decline ?: existing.intents.decline,
                hangUp = intents.hangUp ?: existing.intents.hangUp
            )
        }
        return resolved
    }

    /**
     * The phone withdrew the notification, which for a call means it is over. Returns the
     * final snapshot to send, or null when the key was never a call.
     */
    fun onRemoved(id: String): CallSnapshot? {
        val live = calls.remove(id) ?: return null
        return live.snapshot.copy(
            state = CallState.ENDED,
            canAnswer = false,
            canDecline = false,
            canHangUp = false
        )
    }

    /** Everything still live, for the replay a reconnecting Mac gets. */
    fun active(): List<CallSnapshot> = calls.values.map { it.snapshot }

    fun clear() = calls.clear()

    // MARK: - Acting on a call

    /**
     * Does the thing, and returns null when it worked. A non-null result is a sentence for
     * the user — it travels to the Mac and is shown there, so it says what to do about it.
     */
    fun perform(id: String, action: CallAction): String? {
        val live = calls[id] ?: return GONE
        if (action == CallAction.ANSWER && live.snapshot.state != CallState.RINGING) {
            return "That call is not ringing any more."
        }
        val intent = when (action) {
            CallAction.ANSWER -> live.intents.answer
            CallAction.DECLINE -> live.intents.decline
            CallAction.HANGUP -> live.intents.hangUp
        }
        if (intent != null) {
            try {
                intent.send()
                return null
            } catch (e: PendingIntent.CanceledException) {
                // The app withdrew its own button. Telecom may still manage this call, so
                // this is a reason to fall through rather than a reason to give up.
                Log.w(TAG, "${action.wire} intent was cancelled: ${e.message}")
            }
        }
        return viaTelecom(action)
    }

    /**
     * The fallback, for a dialer that builds its incoming-call UI entirely out of a
     * full-screen intent and leaves nothing in the notification to press.
     *
     * Telecom only knows about calls it manages — cellular ones, and VoIP apps that
     * register a `ConnectionService`. Everything else has already been handled above or
     * cannot be handled at all, and saying so is better than a button that does nothing.
     */
    private fun viaTelecom(action: CallAction): String? {
        if (!hasCallControl()) {
            return "Tennanova needs call access on the phone to " +
                "${action.verb} calls that the dialer does not offer a button for."
        }
        val telecom = context.getSystemService(TelecomManager::class.java)
            ?: return "This phone has no call service to ${action.verb} with."
        // Both are deprecated in favour of an `InCallService`, which is gated on the
        // default-dialer role. Taking that role would make Tennanova the phone's dialer —
        // a far larger thing than answering a call from the Mac, and not something to do
        // to someone's phone in passing. These still work, and this is the only path that
        // reaches a dialer whose notification carries no intents.
        @Suppress("DEPRECATION")
        return try {
            when (action) {
                CallAction.ANSWER -> {
                    telecom.acceptRingingCall()
                    null
                }
                else -> if (telecom.endCall()) null else "The phone would not end that call."
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "telecom refused ${action.wire}: ${e.message}")
            "Android refused the request. Check Tennanova's call permission in Settings."
        } catch (e: Exception) {
            Log.w(TAG, "telecom failed ${action.wire}: ${e.message}")
            e.message ?: "The phone could not ${action.verb} that call."
        }
    }

    private companion object {
        const val TAG = "TennaNova"
        const val MAX_CALLS = 8
        const val GONE = "That call is no longer on the phone."
    }
}
