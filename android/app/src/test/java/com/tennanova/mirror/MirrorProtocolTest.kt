package com.tennanova.mirror

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class MirrorProtocolTest {
    @Test fun resolutionPreservesAspectAndUsesEvenDimensions() {
        assertEquals(MirrorSize(1080, 1920), MirrorSize.fit(1440, 2560))
        val odd = MirrorSize.fit(1001, 501)
        assertEquals(0, odd.width % 2)
        assertEquals(0, odd.height % 2)
    }

    @Test fun bitrateStartsWithinTheRequiredBounds() {
        assertEquals(2_000_000, MirrorSize.initialBitrate(320, 240))
        assertTrue(MirrorSize.initialBitrate(1920, 1080) in 2_000_000..8_000_000)
        assertEquals(8_000_000, MirrorSize.initialBitrate(3840, 2160))
    }

    @Test fun sustainedQueuePressureReducesBitrateAndQuietTimeRecoversIt() {
        val controller = MirrorBitrateController(8_000_000)
        assertNull(controller.sample(MirrorBitrateController.HIGH_QUEUE + 1, 0))
        assertEquals(6_000_000, controller.sample(MirrorBitrateController.HIGH_QUEUE + 1, 500))
        assertNull(controller.sample(0, 1_000))
        assertEquals(6_600_000, controller.sample(0, 11_000))
    }

    @Test fun binaryHeaderIsBigEndianAndLeavesTheAccessUnitUntouched() {
        val accessUnit = byteArrayOf(0, 0, 0, 1, 0x65)
        val packet = MirrorVideoPacket.encode(0x1234, 0x10203040, 0x0102030405060708,
            keyframe = true, accessUnit = accessUnit)
        assertArrayEquals("TNMV".toByteArray(), packet.copyOfRange(0, 4))
        assertEquals(1, packet[4].toInt())
        assertEquals(1, packet[5].toInt())
        val header = ByteBuffer.wrap(packet)
        assertEquals(0x1234, header.getShort(6).toInt() and 0xffff)
        assertEquals(0x10203040, header.getInt(8))
        assertEquals(0x0102030405060708, header.getLong(12))
        assertArrayEquals(accessUnit, packet.copyOfRange(20, packet.size))
    }

    @Test fun annexBParserAcceptsThreeAndFourByteStartCodes() {
        val bytes = byteArrayOf(0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2)
        val units = H264AnnexB.units(bytes)
        assertEquals(2, units.size)
        assertArrayEquals(byteArrayOf(0x67, 1), units[0])
        assertArrayEquals(byteArrayOf(0x68, 2), units[1])
    }

    @Test fun normalizedInputsAreBoundedAndRejectStaleSessions() {
        val tap = JSONObject().put("sessionId", "session-123")
            .put("inputId", "input-123").put("kind", "tap")
            .put("x", 0.25).put("y", 0.75)
        assertNotNull(MirrorInputValidator.parse(tap, "session-123").input)
        assertEquals("stale_session", MirrorInputValidator.parse(tap, "other-session").error)
        tap.put("x", 1.01)
        assertEquals("invalid_input", MirrorInputValidator.parse(tap, "session-123").error)
    }

    @Test fun swipePointCountAndOrderingAreValidatedAndDurationIsClamped() {
        val points = JSONArray()
            .put(JSONObject().put("x", 0.1).put("y", 0.2).put("t", 0.0))
            .put(JSONObject().put("x", 0.8).put("y", 0.9).put("t", 1.0))
        val message = JSONObject().put("sessionId", "session-123")
            .put("inputId", "input-123").put("kind", "swipe")
            .put("durationMs", 8_000).put("points", points)
        val swipe = MirrorInputValidator.parse(message, "session-123").input as MirrorInput.Swipe
        assertEquals(1_000, swipe.durationMs)
        points.getJSONObject(1).put("t", -0.1)
        assertEquals("invalid_input", MirrorInputValidator.parse(message, "session-123").error)
    }
}
