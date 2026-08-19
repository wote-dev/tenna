package com.tennanova.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayConfigTest {

    @Test fun queryValuesArePercentEncodedIncludingPlus() {
        // The relay reads its parameters with URLSearchParams, which treats a bare `+`
        // as a space. Leaving one through would make it look for a different room.
        assertEquals("AAAA%2F%2B%2B%3Dvector", RelayConfig.escape("AAAA/++=vector"))
        assertEquals("plain-room_id.42~", RelayConfig.escape("plain-room_id.42~"))
        assertEquals("%20", RelayConfig.escape(" "))
    }

    @Test fun nonAsciiIsEncodedPerUtf8Byte() {
        assertEquals("%C3%A9", RelayConfig.escape("é"))
    }

    @Test fun aRoomIdLooksLikeBase64urlOfASha256() {
        assertTrue(RelayConfig.isValidRoom("JNtIvh6Lm1ONInKzeCuo_S4Mx7LaKPT8d3evEOvspII"))
        assertFalse("padding and slashes never appear in base64url",
            RelayConfig.isValidRoom("JNtIvh6Lm1ONInKzeCuo/S4Mx7LaKPT8d3evEOvspII="))
        assertFalse(RelayConfig.isValidRoom(""))
        assertFalse(RelayConfig.isValidRoom("short"))
    }

    @Test fun aRelayHostMustBeANameNotAUrlOrAnInjection() {
        assertTrue(RelayConfig.isValidHost("tennanova-relay.fly.dev"))
        assertFalse("a bare label could be anything on the local network",
            RelayConfig.isValidHost("localhost"))
        assertFalse(RelayConfig.isValidHost("evil.example/../"))
        assertFalse(RelayConfig.isValidHost("evil.example:443"))
        assertFalse(RelayConfig.isValidHost("wss://evil.example"))
        assertFalse(RelayConfig.isValidHost(""))
    }

    @Test fun aJoinUrlIsRefusedRatherThanBuiltFromJunk() {
        assertNull(RelayConfig.joinUrl("evil.example/x", "JNtIvh6Lm1ONInKzeCuo_S4Mx7LaKPT8d3evEOvspII"))
        assertNull(RelayConfig.joinUrl("relay.fly.dev", "not a room"))
        assertEquals(
            "wss://relay.fly.dev/v1/join?room=JNtIvh6Lm1ONInKzeCuo_S4Mx7LaKPT8d3evEOvspII",
            RelayConfig.joinUrl("relay.fly.dev", "JNtIvh6Lm1ONInKzeCuo_S4Mx7LaKPT8d3evEOvspII")
        )
    }
}
