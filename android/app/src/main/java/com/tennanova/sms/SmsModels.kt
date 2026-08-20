package com.tennanova.sms

/**
 * One SMS conversation, as the Mac's sidebar needs it.
 *
 * `displayName` is resolved on this side of the wire deliberately. The phone already holds
 * READ_CONTACTS for exactly this, and resolving here means the Mac needs no contacts
 * protocol, no contact cache and no second permission story of its own.
 */
data class SmsThreadSummary(
    val id: Long,
    val address: String,
    val displayName: String,
    val snippet: String,
    val whenMs: Long,
    val unread: Int
)

/**
 * One text message.
 *
 * `outgoing` is "the user sent this", not "this device sent this" — a message typed on the
 * phone and one typed on the Mac are the same thing to whoever is reading the thread.
 */
data class SmsMessage(
    val id: Long,
    val threadId: Long,
    val address: String,
    val displayName: String?,
    val body: String,
    val whenMs: Long,
    val outgoing: Boolean,
    val read: Boolean
)

/**
 * Pure helpers over phone numbers. Separated from [SmsMirror] because this is all the
 * behaviour worth testing and none of it needs a ContentResolver.
 */
object SmsAddresses {

    /**
     * The digits that actually identify a number, for comparing two spellings of one
     * person: `+61 491 570 006`, `0491570006` and `491570006` all reduce to the same thing.
     *
     * Keeps the last [SIGNIFICANT_DIGITS] because country code and trunk prefix are
     * exactly the parts that differ between spellings, and the subscriber number is the
     * part that does not. Short codes stay whole — a five-digit sender has no prefix to
     * strip and truncating one would merge unrelated services.
     */
    fun normalize(raw: String): String {
        val digits = raw.filter { it.isDigit() }
        if (digits.isEmpty()) return raw.trim().lowercase()
        return if (digits.length <= SIGNIFICANT_DIGITS) digits
        else digits.takeLast(SIGNIFICANT_DIGITS)
    }

    /** What to call this conversation: the contact, or the number when there is no contact. */
    fun display(contactName: String?, address: String): String {
        val name = contactName?.trim()
        if (!name.isNullOrEmpty()) return name
        val trimmed = address.trim()
        return trimmed.ifEmpty { "Unknown" }
    }

    /**
     * Whether this is something `SmsManager` can be handed at all.
     *
     * Deliberately permissive about *shape* — numbers arrive in every format, and
     * alphanumeric sender ids are real — but a blank or punctuation-only destination is
     * refused rather than sent into the void.
     */
    fun isSendable(address: String): Boolean {
        val trimmed = address.trim()
        return trimmed.length in 2..40 && trimmed.any { it.isLetterOrDigit() }
    }

    const val SIGNIFICANT_DIGITS = 9
}
