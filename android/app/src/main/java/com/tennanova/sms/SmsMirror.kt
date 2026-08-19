package com.tennanova.sms

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.app.Activity
import android.app.PendingIntent
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicLong

/**
 * Reads and writes the phone's real SMS store.
 *
 * This is the one messaging surface Android actually opens to a third-party app. WhatsApp,
 * Signal and the rest expose nothing but their notifications — no history, no way to start
 * a conversation — so a Mac-side chat for those can only ever be notification-shaped. The
 * SMS provider has no such limit: full thread history, and `SmsManager` sends to any
 * number without this app being the default SMS app. Only *writing* to the provider and
 * MMS need that role, and neither is done here.
 *
 * Text SMS only. MMS is deliberately out of scope rather than half-supported.
 */
class SmsMirror(private val context: Context) {

    private val resolver: ContentResolver get() = context.contentResolver
    private var observer: ContentObserver? = null
    private val highWaterMark = AtomicLong(-1)
    private val sentReceivers = mutableListOf<BroadcastReceiver>()

    fun hasReadAccess(): Boolean = granted(Manifest.permission.READ_SMS)
    fun hasSendAccess(): Boolean = granted(Manifest.permission.SEND_SMS)
    fun hasContactAccess(): Boolean = granted(Manifest.permission.READ_CONTACTS)

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    // MARK: - Reading

    /**
     * Conversations, most recent first.
     *
     * Built from the message table rather than `Telephony.Threads`, which is not a
     * reliably queryable public view across OEM builds — Samsung's in particular. One pass
     * over recent messages, newest first, keeping the first sighting of each thread, gives
     * the same answer from an API that is actually guaranteed.
     */
    fun threads(limit: Int = MAX_THREADS): List<SmsThreadSummary> {
        if (!hasReadAccess()) return emptyList()
        val summaries = LinkedHashMap<Long, SmsThreadSummary>()
        val unread = HashMap<Long, Int>()

        query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ
            ),
            null, null,
            "${Telephony.Sms.DATE} DESC LIMIT $THREAD_SCAN_ROWS"
        ) { cursor ->
            val threadId = cursor.getLong(1)
            val address = cursor.getString(2).orEmpty()
            val read = cursor.getInt(6) == 1
            val incoming = cursor.getInt(5) == Telephony.Sms.MESSAGE_TYPE_INBOX
            if (incoming && !read) unread[threadId] = (unread[threadId] ?: 0) + 1
            if (summaries.containsKey(threadId)) return@query
            if (summaries.size >= limit) return@query
            summaries[threadId] = SmsThreadSummary(
                id = threadId,
                address = address,
                displayName = SmsAddresses.display(contactName(address), address),
                snippet = cursor.getString(3).orEmpty(),
                whenMs = cursor.getLong(4),
                unread = 0
            )
        }

        return summaries.values.map { it.copy(unread = unread[it.id] ?: 0) }
    }

    /** One thread's messages, oldest first, paging backwards from [beforeId] when given. */
    fun messages(threadId: Long, beforeId: Long?, limit: Int = MAX_MESSAGES): List<SmsMessage> {
        if (!hasReadAccess()) return emptyList()
        val selection = StringBuilder("${Telephony.Sms.THREAD_ID} = ?")
        val args = mutableListOf(threadId.toString())
        if (beforeId != null) {
            selection.append(" AND ${Telephony.Sms._ID} < ?")
            args.add(beforeId.toString())
        }
        val out = ArrayList<SmsMessage>()
        // Newest-first so LIMIT keeps the *recent* end of a long thread, then reversed so
        // the Mac receives a transcript in reading order.
        query(
            Telephony.Sms.CONTENT_URI, MESSAGE_COLUMNS,
            selection.toString(), args.toTypedArray(),
            "${Telephony.Sms.DATE} DESC LIMIT $limit"
        ) { out.add(readMessage(it)) }
        return out.reversed()
    }

    /** Everything newer than the last row this mirror reported. */
    fun messagesSince(id: Long, limit: Int = MAX_MESSAGES): List<SmsMessage> {
        if (!hasReadAccess()) return emptyList()
        val out = ArrayList<SmsMessage>()
        query(
            Telephony.Sms.CONTENT_URI, MESSAGE_COLUMNS,
            "${Telephony.Sms._ID} > ?", arrayOf(id.toString()),
            "${Telephony.Sms._ID} ASC LIMIT $limit"
        ) { out.add(readMessage(it)) }
        return out
    }

    private fun readMessage(cursor: android.database.Cursor): SmsMessage {
        val address = cursor.getString(2).orEmpty()
        val type = cursor.getInt(5)
        return SmsMessage(
            id = cursor.getLong(0),
            threadId = cursor.getLong(1),
            address = address,
            displayName = contactName(address),
            body = cursor.getString(3).orEmpty(),
            whenMs = cursor.getLong(4),
            // Anything not sitting in the inbox was put there by the user — sent, queued
            // or still in the outbox — and reads as theirs in the transcript either way.
            outgoing = type != Telephony.Sms.MESSAGE_TYPE_INBOX,
            read = cursor.getInt(6) == 1
        )
    }

    private fun currentMaxId(): Long {
        var max = -1L
        query(
            Telephony.Sms.CONTENT_URI, arrayOf(Telephony.Sms._ID),
            null, null, "${Telephony.Sms._ID} DESC LIMIT 1"
        ) { max = it.getLong(0) }
        return max
    }

    // MARK: - Contacts

    /**
     * Resolved through the phone-lookup view, which does the number-matching itself and is
     * far more forgiving than comparing strings — the provider stores whatever format the
     * sender used.
     */
    private fun contactName(address: String): String? {
        if (address.isBlank() || !hasContactAccess()) return null
        return runCatching {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address)
            )
            var name: String? = null
            query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null) {
                name = it.getString(0)
            }
            name
        }.getOrNull()
    }

    // MARK: - Sending

    /**
     * Sends, and reports what the radio said rather than assuming.
     *
     * Long messages are split: `sendTextMessage` silently fails past a single part, which
     * is the sort of thing that looks like a delivered message and is not.
     */
    fun send(address: String, body: String, onResult: (Boolean, String?) -> Unit) {
        if (!hasSendAccess()) {
            onResult(false, "Tennanova does not have permission to send texts on this phone.")
            return
        }
        if (!SmsAddresses.isSendable(address)) {
            onResult(false, "That is not a number this phone can text.")
            return
        }
        val manager = context.getSystemService(SmsManager::class.java) ?: run {
            onResult(false, "This phone has no SMS service.")
            return
        }

        val action = "$SENT_ACTION.${System.nanoTime()}"
        val parts = manager.divideMessage(body)
        val remaining = java.util.concurrent.atomic.AtomicInteger(parts.size)
        val reported = java.util.concurrent.atomic.AtomicBoolean(false)

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val ok = resultCode == Activity.RESULT_OK
                if (!ok && reported.compareAndSet(false, true)) {
                    unregister(this)
                    onResult(false, failureText(resultCode))
                } else if (ok && remaining.decrementAndGet() == 0 &&
                    reported.compareAndSet(false, true)
                ) {
                    unregister(this)
                    onResult(true, null)
                }
            }
        }
        synchronized(sentReceivers) { sentReceivers.add(receiver) }
        ContextCompat.registerReceiver(
            context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED
        )

        val intents = ArrayList<PendingIntent>(parts.size)
        repeat(parts.size) { index ->
            intents.add(
                PendingIntent.getBroadcast(
                    context, index, Intent(action).setPackage(context.packageName),
                    PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        }

        try {
            if (parts.size == 1) {
                manager.sendTextMessage(address, null, parts[0], intents[0], null)
            } else {
                manager.sendMultipartTextMessage(address, null, parts, intents, null)
            }
        } catch (e: Exception) {
            if (reported.compareAndSet(false, true)) {
                unregister(receiver)
                onResult(false, e.message ?: "The phone refused to send that message.")
            }
        }
    }

    private fun unregister(receiver: BroadcastReceiver) {
        synchronized(sentReceivers) { sentReceivers.remove(receiver) }
        runCatching { context.unregisterReceiver(receiver) }
    }

    private fun failureText(code: Int): String = when (code) {
        SmsManager.RESULT_ERROR_NO_SERVICE -> "No mobile service — the phone could not send it."
        SmsManager.RESULT_ERROR_RADIO_OFF -> "The phone's radio is off."
        SmsManager.RESULT_ERROR_NULL_PDU -> "The phone rejected the message."
        SmsManager.RESULT_ERROR_LIMIT_EXCEEDED -> "The phone has hit its sending limit."
        else -> "The phone could not send that message."
    }

    // MARK: - Watching

    /**
     * Pushes every row that appears after this starts.
     *
     * A high-water mark rather than a diff: the provider notifies on any change, including
     * a message being marked read, and re-reading the tail on every one of those would
     * mirror the same text repeatedly.
     */
    fun observe(onMessages: (List<SmsMessage>) -> Unit) {
        if (!hasReadAccess() || observer != null) return
        highWaterMark.set(currentMaxId())
        val watcher = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) = onChange(selfChange, null)
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                val since = highWaterMark.get()
                val fresh = messagesSince(since)
                if (fresh.isEmpty()) return
                highWaterMark.set(fresh.maxOf { it.id })
                onMessages(fresh)
            }
        }
        observer = watcher
        runCatching {
            resolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, watcher)
        }.onFailure { Log.w(TAG, "could not watch the SMS store: ${it.message}") }
    }

    fun stop() {
        observer?.let { runCatching { resolver.unregisterContentObserver(it) } }
        observer = null
        synchronized(sentReceivers) {
            sentReceivers.toList().forEach { runCatching { context.unregisterReceiver(it) } }
            sentReceivers.clear()
        }
    }

    // MARK: - Plumbing

    private inline fun query(
        uri: Uri,
        projection: Array<String>,
        selection: String?,
        args: Array<String>?,
        order: String?,
        each: (android.database.Cursor) -> Unit
    ) {
        runCatching {
            resolver.query(uri, projection, selection, args, order)?.use { cursor ->
                while (cursor.moveToNext()) each(cursor)
            }
        }.onFailure { Log.w(TAG, "SMS query failed: ${it.message}") }
    }

    private companion object {
        const val TAG = "TennaSms"
        const val MAX_THREADS = 100
        const val MAX_MESSAGES = 200

        /** Enough recent rows to find the newest message of every recent conversation. */
        const val THREAD_SCAN_ROWS = 2000
        const val SENT_ACTION = "com.tennanova.SMS_SENT"

        val MESSAGE_COLUMNS = arrayOf(
            Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ
        )
    }
}
