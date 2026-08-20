package com.tennanova.sms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsAddressesTest {

    @Test fun `one person written four ways is one conversation`() {
        val forms = listOf("+61 491 570 006", "0491570006", "491570006", "+61491570006")
        val normalized = forms.map { SmsAddresses.normalize(it) }.toSet()

        // Country code and trunk prefix are exactly the parts that differ between
        // spellings; the subscriber number is the part that does not.
        assertEquals(1, normalized.size)
    }

    @Test fun `short codes are not truncated into each other`() {
        // A five-digit sender has no prefix to strip, and cutting one down would merge
        // unrelated services into one thread.
        assertEquals("19876", SmsAddresses.normalize("19876"))
        assertTrue(SmsAddresses.normalize("19876") != SmsAddresses.normalize("28876"))
    }

    @Test fun `alphanumeric senders survive intact`() {
        // Banks and carriers send from names, not numbers.
        assertEquals("amaysim", SmsAddresses.normalize("amaysim"))
    }

    @Test fun `a contact name wins over the raw number`() {
        assertEquals("Sam", SmsAddresses.display("Sam", "+61491570006"))
        assertEquals("+61491570006", SmsAddresses.display(null, "+61491570006"))
        assertEquals("+61491570006", SmsAddresses.display("   ", "+61491570006"))
    }

    @Test fun `an unknown sender still gets a name`() {
        assertEquals("Unknown", SmsAddresses.display(null, "   "))
    }

    @Test fun `blank and punctuation-only destinations are refused`() {
        assertFalse(SmsAddresses.isSendable(""))
        assertFalse(SmsAddresses.isSendable("  "))
        assertFalse(SmsAddresses.isSendable("+-()"))
    }

    @Test fun `real destinations are accepted in any format`() {
        assertTrue(SmsAddresses.isSendable("+61 491 570 006"))
        assertTrue(SmsAddresses.isSendable("0491570006"))
        assertTrue(SmsAddresses.isSendable("amaysim"))
        assertTrue(SmsAddresses.isSendable("19876"))
    }
}
