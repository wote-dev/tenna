package com.tennanova.notifications

/**
 * Whether the newest thing in a chat notification is something the phone's owner just
 * said, rather than something worth putting on the Mac.
 *
 * Messaging apps do not withdraw a conversation's notification when you answer it — they
 * re-post it with your own reply as the latest line, so the shade shows "You: …" where
 * the incoming message used to be. Mirrored naively, every reply came back to the Mac a
 * second after it left: a fresh alert, and — because the repost renames the chat to the
 * speaker — a phantom conversation called "You" holding replies to several different
 * people. That is the bug this exists to stop, for replies typed on the phone and replies
 * typed on the Mac alike.
 *
 * Pure and parameterised for the same reason [MirrorDecision] is: each rule below exists
 * because one app expressed "the user said this" differently, and each is worth a test
 * that does not need a running service.
 */
object SelfMessage {

    /**
     * How long a reply this app fired keeps suppressing reposts carrying that same text.
     *
     * Generous on purpose. The cost of being wrong is one message the Mac shows a little
     * late — the *incoming* message that follows it is unaffected — while the cost of a
     * window too short is exactly the bug, since an app under a poor connection can take
     * many seconds to settle its notification.
     */
    const val OWN_REPLY_WINDOW_MS = 5 * 60 * 1000L

    /** One reply this phone has fired into a conversation on the Mac's behalf. */
    data class SentReply(val text: String, val whenMs: Long)

    /**
     * Everything about one posted notification that bears on the question, lifted out of
     * `Notification` so the rules can be tested without one.
     *
     * [lastSenderName] and [lastSenderKey] are null when there is no MessagingStyle at
     * all, and also when the style marks its newest message as the user's own — which is
     * what a null `Person` means to both `MessagingStyle` and its androidx twin.
     */
    data class Post(
        val hasMessages: Boolean = false,
        val lastSenderName: String? = null,
        val lastSenderKey: String? = null,
        val selfName: String? = null,
        val selfKey: String? = null,
        val title: String? = null,
        val conversationTitle: String? = null,
        val body: String? = null,
        /** `EXTRA_REMOTE_INPUT_HISTORY`, newest first, as the framework orders it. */
        val remoteInputHistory: List<String> = emptyList()
    )

    fun isOurOwn(post: Post, ourReply: SentReply?, now: Long): Boolean {
        // 1. The style says so outright. A null `Person` on the newest message is the
        //    documented way to say "the user wrote this", and an app that names the user
        //    instead says it by reusing the very Person it opened the style with.
        if (post.hasMessages) {
            if (post.lastSenderName == null && post.lastSenderKey == null) return true
            if (matches(post.lastSenderKey, post.selfKey)) return true
            if (matches(post.lastSenderName, post.selfName)) return true
        }

        // 2. The collapsed line names the speaker rather than the chat, and the speaker is
        //    the user. This is what made WhatsApp's reposts arrive titled "You": with the
        //    chat name replaced there is nothing left in the post that still points at the
        //    conversation it belongs to, so mirroring it could only ever invent a thread.
        if (matches(post.title, post.selfName)) return true
        if (matches(post.conversationTitle, post.selfName)) return true

        // 3. The system's own record of a reply typed into the shade. Only when it is what
        //    the notification is *showing*: an app that leaves its history in place while a
        //    genuinely new message arrives must not be silenced by it.
        val body = post.body?.trim()
        if (!body.isNullOrEmpty() && post.remoteInputHistory.any { it.trim() == body }) {
            return true
        }

        // 4. A reply this phone fired for the Mac, coming back. The catch-all: it needs no
        //    MessagingStyle and no cooperation from the app, which is what makes it the
        //    rule that covers whatever the next messaging app does differently.
        if (ourReply != null && !body.isNullOrEmpty() &&
            ourReply.text.trim() == body &&
            now - ourReply.whenMs in 0..OWN_REPLY_WINDOW_MS
        ) {
            return true
        }

        return false
    }

    /** Equal, and actually saying something — two blanks are not a match. */
    private fun matches(a: String?, b: String?): Boolean =
        !a.isNullOrBlank() && a.trim() == b?.trim()
}
