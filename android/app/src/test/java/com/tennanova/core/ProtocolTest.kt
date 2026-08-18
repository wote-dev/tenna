package com.tennanova.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class ProtocolTest {
    private val token = Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })
    private val pin = Base64.getEncoder().encodeToString(ByteArray(32) { (it + 1).toByte() })

    @Test fun validPairingPayloadIsAccepted() {
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("port", 18777).put("spki", pin).put("token", token).toString()
        assertEquals("192.168.1.4", PairingPayload.parse(raw)?.host)
    }

    @Test fun optionalUsbPortIsAcceptedWithoutChangingProtocolVersion() {
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("port", 18777).put("usbPort", 18777)
            .put("spki", pin).put("token", token).toString()
        val payload = PairingPayload.parse(raw)
        assertEquals(18777, payload?.usbPort)
        assertEquals("192.168.1.4", payload?.host)
    }

    @Test fun everyAdvertisedAddressIsKept() {
        // A Mac on a hotspot answers on more than one address and cannot know which one
        // the phone will be able to reach.
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("hosts", JSONArray(listOf("192.168.1.4", "192.168.43.37", "10.0.0.8")))
            .put("port", 18777).put("spki", pin).put("token", token).toString()
        val payload = PairingPayload.parse(raw)

        assertEquals("192.168.1.4", payload?.host)
        assertEquals(listOf("192.168.1.4", "192.168.43.37", "10.0.0.8"), payload?.hosts)
    }

    @Test fun aPairingCodeWithoutTheListStillPairs() {
        // Codes from an older Mac build carry `host` alone.
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("port", 18777).put("spki", pin).put("token", token).toString()
        assertEquals(listOf("192.168.1.4"), PairingPayload.parse(raw)?.hosts)
    }

    @Test fun junkInTheAddressListIsDroppedRatherThanFatal() {
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("hosts", JSONArray(listOf("192.168.1.4", "mac.local/path", "192.168.1.4", "")))
            .put("port", 18777).put("spki", pin).put("token", token).toString()
        assertEquals(listOf("192.168.1.4"), PairingPayload.parse(raw)?.hosts)
    }

    @Test fun invalidOptionalUsbPortIsRejected() {
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("port", 18777).put("usbPort", 0)
            .put("spki", pin).put("token", token).toString()
        assertNull(PairingPayload.parse(raw))
    }

    @Test fun malformedPairingFieldsAreRejected() {
        val base = JSONObject().put("v", 1).put("host", "https://bad.example")
            .put("port", 70000).put("spki", "short").put("token", token)
        assertNull(PairingPayload.parse(base.toString()))
    }

    @Test fun pairingRejectsHostInjectionAndWrongLengthSecrets() {
        val badHost = JSONObject().put("v", 1).put("host", "mac.local/path")
            .put("port", 18777).put("spki", pin).put("token", token)
        assertNull(PairingPayload.parse(badHost.toString()))
        badHost.put("host", "mac.local").put("spki",
            Base64.getEncoder().encodeToString(ByteArray(31)))
        assertNull(PairingPayload.parse(badHost.toString()))
    }

    @Test fun helloAdvertisesImageClipboard() {
        val hello = Messages.hello("id", "Phone", "Model", 36, 90, token, null)
        val capabilities = hello.getJSONArray("capabilities")
        assertEquals(Proto.IMAGE_CLIPBOARD_CAPABILITY, capabilities.getString(0))
    }

    @Test fun imageHeaderValidationIsStrict() {
        val hash = "a".repeat(64)
        val valid = ClipImageHeader("android", 1, "image/png", 10, hash, "photo.png")
        assertTrue(valid.isValid)
        assertNotNull(ClipImageHeader.parse(Messages.clipImage(valid)))
        assertFalse(valid.copy(bytes = Proto.MAX_IMAGE_BYTES + 1).isValid)
        assertFalse(valid.copy(mime = "text/plain").isValid)
        assertFalse(valid.copy(sha256 = "A".repeat(64)).isValid)
        assertFalse(valid.copy(name = "x".repeat(121)).let {
            ClipImageHeader.parse(Messages.clipImage(it))?.name?.length == 121
        })
    }

    @Test fun imageHashDetectsPayloadChanges() {
        val original = com.tennanova.clipboard.ImageTransfer.sha256("image".toByteArray())
        val changed = com.tennanova.clipboard.ImageTransfer.sha256("Image".toByteArray())
        assertEquals(64, original.length)
        assertFalse(original == changed)
    }
}
