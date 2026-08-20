package com.tennanova.calls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CallSignalTest {

    private fun classify(
        category: String? = CallSignal.CATEGORY_CALL,
        callType: Int? = null,
        answer: Boolean = false,
        hangUp: Boolean = false,
        ongoing: Boolean = false
    ) = CallSignal.classify(category, callType, answer, hangUp, ongoing)

    @Test fun `an ordinary notification is not a call`() {
        // The overwhelmingly common case, and the one that must cost nothing.
        assertNull(classify(category = "msg"))
        assertNull(classify(category = null))
        assertNull(classify(category = "promo", ongoing = true))
    }

    @Test fun `CallStyle says outright which way a call is going`() {
        assertEquals(CallState.RINGING, classify(callType = CallSignal.CALL_TYPE_INCOMING))
        assertEquals(CallState.ACTIVE, classify(callType = CallSignal.CALL_TYPE_ONGOING))
        assertEquals(CallState.RINGING, classify(callType = CallSignal.CALL_TYPE_SCREENING))
    }

    @Test fun `a CallStyle notification is a call even without the call category`() {
        // Nothing obliges an app to set both, and the style is the stronger signal.
        assertEquals(
            CallState.RINGING,
            classify(category = null, callType = CallSignal.CALL_TYPE_INCOMING)
        )
    }

    @Test fun `the call type wins over the ongoing flag`() {
        // Incoming call notifications are routinely ongoing — that is what stops the user
        // swiping the ring away — so the flag alone would call every ring an active call.
        assertEquals(
            CallState.RINGING,
            classify(callType = CallSignal.CALL_TYPE_INCOMING, ongoing = true)
        )
    }

    @Test fun `without a call type the intents describe the state`() {
        assertEquals(CallState.RINGING, classify(answer = true, ongoing = true))
        assertEquals(CallState.ACTIVE, classify(hangUp = true))
        assertEquals(CallState.ACTIVE, classify(ongoing = true))
    }

    @Test fun `a call with nothing else to go on is treated as ringing`() {
        // The louder of the two mistakes. A ring shown as an in-progress call is a missed
        // call; an in-progress call shown as a ring is a card with a dead Answer button,
        // and `canAnswer` is false there anyway because there is no intent to fire.
        assertEquals(CallState.RINGING, classify())
    }

    @Test fun `a tel person carries the number`() {
        assertEquals("+61491570006", CallSignal.numberFrom("tel:+61491570006"))
        assertEquals("+61 491 570 006", CallSignal.numberFrom("tel:+61%20491%20570%20006"))
    }

    @Test fun `a person who is not a phone number has no number`() {
        // A WhatsApp call names a contact lookup, not a diallable number.
        assertNull(CallSignal.numberFrom("content://com.android.contacts/contacts/12"))
        assertNull(CallSignal.numberFrom(null))
        assertNull(CallSignal.numberFrom("tel:"))
    }

    @Test fun `the caller is named by whoever knows best`() {
        assertEquals("Sam", CallSignal.displayName("Sam", "+61491570006", "+61491570006"))
        assertEquals("+61491570006", CallSignal.displayName(null, null, "+61491570006"))
        assertNull(CallSignal.displayName(null, null, null))
        // Some dialers put the literal string "null" in the title, which is a worse thing
        // to show as a caller's name than showing nothing at all.
        assertNull(CallSignal.displayName(null, "null", null))
        assertEquals("+61491570006", CallSignal.displayName(null, "null", "+61491570006"))
        // Blank is not a name either.
        assertEquals("Sam", CallSignal.displayName("  ", "Sam", null))
    }

    @Test fun `every wire action round-trips`() {
        CallAction.entries.forEach { assertEquals(it, CallAction.parse(it.wire)) }
        assertNull(CallAction.parse("mute"))
        assertNull(CallAction.parse(null))
    }
}
