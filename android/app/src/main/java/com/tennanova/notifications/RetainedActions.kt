package com.tennanova.notifications

/**
 * Keeps a notification's action list usable after the notification itself has gone.
 *
 * The listener used to drop a key's actions inside `onNotificationRemoved`, which sounds
 * tidy and quietly removed the ability to reply to almost every chat. Messaging apps
 * cancel and repost their notification constantly — every time the user reads the chat on
 * the phone, and on many builds every time the conversation updates — so by the time
 * anyone looks at the Mac window, the actions for that conversation were already gone.
 *
 * They did not have to be. A notification's `PendingIntent` is not invalidated when the
 * notification is cancelled; it stays live until the posting app cancels the intent
 * itself, which WhatsApp and Signal do not do. Holding on to the action list is therefore
 * enough to keep replying to a conversation that is no longer on screen — and when an app
 * *has* withdrawn its intent, `PendingIntent.send` throws `CanceledException` and the Mac
 * is told, which is a far better answer than a composer that was never offered.
 *
 * Bounded, and least-recently-used first: each entry holds `PendingIntent`s, so this
 * cannot be allowed to grow for as long as the service is bound.
 *
 * Generic over the payload so it can be tested without an `android.app.Notification`.
 */
class RetainedActions<T>(private val limit: Int = DEFAULT_LIMIT) {

    // accessOrder = true: reading a key counts as using it, so the conversations someone
    // actually replies to are the last to be evicted.
    private val entries = LinkedHashMap<String, T>(16, 0.75f, true)

    val size: Int get() = entries.size

    fun put(key: String, value: T) {
        entries[key] = value
        while (entries.size > limit) {
            entries.remove(entries.keys.first())
        }
    }

    fun get(key: String): T? = entries[key]

    /** For a key that will never be replied to again — a different phone, or an unpair. */
    fun forget(key: String) {
        entries.remove(key)
    }

    fun clear() = entries.clear()

    companion object {
        const val DEFAULT_LIMIT = 200
    }
}
