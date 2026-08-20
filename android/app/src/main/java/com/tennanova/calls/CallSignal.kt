package com.tennanova.calls

import com.tennanova.core.NotifAction

/**
 * Where a call is in its life. `ENDED` is emitted once, when the phone withdraws the
 * notification, and is the last thing the Mac hears about that call.
 */
enum class CallState {
    RINGING,
    ACTIVE,
    ENDED;

    val wire: String get() = name.lowercase()
}

/**
 * Which way the call went.
 *
 * Android does not say. A call first seen *ringing* is one arriving; a call first seen
 * already in progress is one this phone placed. That inference is only ever used to label
 * a row in the Mac's recents, so being wrong about a call answered on the phone before
 * Tennanova saw it costs a word, not a feature.
 */
enum class CallDirection {
    INCOMING,
    OUTGOING;

    val wire: String get() = name.lowercase()
}

/**
 * What the Mac asked for. `DECLINE` and `HANGUP` both end a call and are kept apart
 * because they are different buttons on different screens — one refuses a call that is
 * ringing, the other leaves one that is in progress — and because a `CallStyle`
 * notification carries a separate intent for each.
 */
enum class CallAction {
    ANSWER,
    DECLINE,
    HANGUP;

    val wire: String get() = name.lowercase()

    /** For the sentence the phone sends back when it could not do it. */
    val verb: String get() = when (this) {
        ANSWER -> "answer"
        DECLINE -> "decline"
        HANGUP -> "end"
    }

    companion object {
        fun parse(wire: String?): CallAction? =
            entries.firstOrNull { it.wire == wire?.trim()?.lowercase() }
    }
}

/**
 * Everything the Mac is told about one call.
 *
 * `canAnswer` / `canDecline` / `canHangUp` are per-call, not per-phone: whether this
 * particular notification carried the intents, or whether Telecom will take the call on
 * our behalf. A Mac that showed an Answer button resolving to nothing would be worse than
 * one that showed no button at all.
 */
data class CallSnapshot(
    val id: String,
    val state: CallState,
    val direction: CallDirection,
    val pkg: String,
    val appLabel: String,
    val displayName: String?,
    val number: String?,
    val isVideo: Boolean,
    val whenMs: Long,
    val canAnswer: Boolean,
    val canDecline: Boolean,
    val canHangUp: Boolean,
    val iconHash: String? = null,
    val avatarHash: String? = null,
    val actions: List<NotifAction> = emptyList()
)

/**
 * Reading a call out of a notification.
 *
 * Pure, and separate from [CallMonitor] for the same reason `MirrorDecision` is separate
 * from the listener: every rule here is a judgement about somebody else's notification and
 * each one is worth a test that needs no running service.
 *
 * Calls are taken from notifications rather than from a telephony API on purpose. It is
 * the only surface that covers WhatsApp, Signal and Telegram calls as well as cellular
 * ones, and it needs no permission the app does not already hold.
 */
object CallSignal {

    /** `Notification.CallStyle.CALL_TYPE_*`, repeated so this file needs no framework. */
    const val CALL_TYPE_INCOMING = 1
    const val CALL_TYPE_ONGOING = 2
    const val CALL_TYPE_SCREENING = 3

    /** `Notification.CATEGORY_CALL`. */
    const val CATEGORY_CALL = "call"

    /**
     * Whether this notification is a call, and what state it is in — or null when it is
     * an ordinary notification and belongs on the notification channel instead.
     *
     * [callType] is `Notification.EXTRA_CALL_TYPE` and is authoritative when present:
     * anything built with `CallStyle` says outright whether it is ringing or in progress.
     * Without it the ongoing flag is the best evidence there is — a call still ringing is
     * an alert, and a call in progress is a status.
     */
    fun classify(
        category: String?,
        callType: Int?,
        hasAnswerIntent: Boolean,
        hasHangUpIntent: Boolean,
        isOngoing: Boolean
    ): CallState? {
        if (category != CATEGORY_CALL && callType == null) return null
        when (callType) {
            CALL_TYPE_INCOMING, CALL_TYPE_SCREENING -> return CallState.RINGING
            CALL_TYPE_ONGOING -> return CallState.ACTIVE
        }
        if (hasAnswerIntent) return CallState.RINGING
        if (hasHangUpIntent || isOngoing) return CallState.ACTIVE
        return CallState.RINGING
    }

    /**
     * The number behind a `CallStyle` person, whose uri is a `tel:` for a phone call and
     * a `content://` contact lookup or nothing at all for a VoIP one.
     */
    fun numberFrom(personUri: String?): String? {
        val uri = personUri?.trim().orEmpty()
        if (!uri.startsWith(TEL_SCHEME, ignoreCase = true)) return null
        // `+` is escaped before decoding, not after. A tel: URI is not a form body, and
        // `URLDecoder` reads a bare `+` as a space — which silently eats the country-code
        // plus off the front of every international number it is handed.
        val escaped = uri.substring(TEL_SCHEME.length).replace("+", "%2B")
        val number = runCatching {
            java.net.URLDecoder.decode(escaped, "UTF-8")
        }.getOrDefault(uri.substring(TEL_SCHEME.length)).trim()
        return number.takeIf { it.isNotEmpty() }
    }

    /**
     * The name to show, in the order a person would want it: whoever the app named, then
     * the notification's own title, then the number. Never the app's name — the Mac draws
     * that separately, and "Phone is calling" helps nobody.
     */
    fun displayName(personName: String?, title: String?, number: String?): String? =
        listOf(personName, title, number)
            .firstOrNull { !it.isNullOrBlank() && it.trim() != "null" }
            ?.trim()

    private const val TEL_SCHEME = "tel:"
}
