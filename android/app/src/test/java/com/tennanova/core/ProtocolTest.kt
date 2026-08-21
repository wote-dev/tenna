package com.tennanova.core

import com.tennanova.calls.CallAction
import com.tennanova.calls.CallDirection
import com.tennanova.calls.CallSnapshot
import com.tennanova.calls.CallState
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

    @Test fun aPairingCodeCarriesTheRelayRoom() {
        val room = "JNtIvh6Lm1ONInKzeCuo_S4Mx7LaKPT8d3evEOvspII"
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("port", 18777).put("spki", pin).put("token", token)
            .put("relayHost", "tennanova-relay.fly.dev").put("relayRoom", room)
            .toString()
        val payload = PairingPayload.parse(raw)
        assertEquals("tennanova-relay.fly.dev", payload?.relayHost)
        assertEquals(room, payload?.relayRoom)
    }

    @Test fun aPairingCodeFromAMacWithNoRelayStillPairs() {
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("port", 18777).put("spki", pin).put("token", token).toString()
        val payload = PairingPayload.parse(raw)
        assertNotNull(payload)
        assertNull(payload?.relayHost)
        assertNull(payload?.relayRoom)
    }

    @Test fun halfARelayTargetIsDroppedRatherThanHalfUsed() {
        // A host with no room, or a room with no host, is not a route. Keeping either
        // would buy a doomed round trip on every single reconnect.
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("port", 18777).put("spki", pin).put("token", token)
            .put("relayHost", "tennanova-relay.fly.dev").toString()
        val payload = PairingPayload.parse(raw)
        assertNotNull(payload)
        assertNull(payload?.relayHost)
    }

    @Test fun aRelayTargetIsRejectedWhenTheHostLooksLikeAnInjection() {
        val room = "JNtIvh6Lm1ONInKzeCuo_S4Mx7LaKPT8d3evEOvspII"
        val raw = JSONObject().put("v", 1).put("host", "192.168.1.4")
            .put("port", 18777).put("spki", pin).put("token", token)
            .put("relayHost", "evil.example/../x").put("relayRoom", room).toString()
        val payload = PairingPayload.parse(raw)
        assertNotNull(payload)
        assertNull("a scanned QR is untrusted input like any other", payload?.relayHost)
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

    @Test fun replyResultRoundTripsItsClientId() {
        val json = Messages.notifReplyResult("ABC-123", "0|com.whatsapp|1|x", 0, true, null)

        assertEquals("notif.reply.result", json.getString("type"))
        assertEquals("ABC-123", json.getString("clientId"))
        assertEquals(0, json.getInt("actionId"))
        assertTrue(json.getBoolean("ok"))
        // Absent rather than null: the Mac decodes this into an optional.
        assertFalse(json.has("error"))
    }

    @Test fun replyResultCarriesTheReasonItFailed() {
        val json = Messages.notifReplyResult(null, "k1", 2, false, "The app withdrew it.")

        assertFalse(json.has("clientId"))
        assertFalse(json.getBoolean("ok"))
        assertEquals("The app withdrew it.", json.getString("error"))
    }

    @Test fun theOfflineReplyCapabilityIsAdvertised() {
        val hello = Messages.hello("id", "Phone", "model", 33, 80, null, "token")
        val caps = hello.getJSONArray("capabilities")
        val advertised = (0 until caps.length()).map { caps.getString(it) }

        // The Mac offers a composer for a withdrawn conversation only when it sees this.
        assertTrue(Proto.OFFLINE_REPLY_CAPABILITY in advertised)
        assertTrue(Proto.IMAGE_CLIPBOARD_CAPABILITY in advertised)
    }

    @Test fun `a call carries everything the Mac draws a card from`() {
        val call = CallSnapshot(
            id = "0|com.dialer|1|null|1000",
            state = CallState.RINGING,
            direction = CallDirection.INCOMING,
            pkg = "com.dialer",
            appLabel = "Phone",
            displayName = "Sam",
            number = "+61491570006",
            isVideo = false,
            whenMs = 1723900000000,
            canAnswer = true,
            canDecline = true,
            canHangUp = false,
            iconHash = "ab12",
            avatarHash = "cd34",
            actions = listOf(NotifAction(2, "Message", false))
        )
        val json = Messages.callState(call, resync = false)
        assertEquals("call.state", json.getString("type"))
        assertEquals("ringing", json.getString("state"))
        assertEquals("incoming", json.getString("direction"))
        assertEquals("Sam", json.getString("displayName"))
        assertEquals("+61491570006", json.getString("number"))
        assertTrue(json.getBoolean("canAnswer"))
        assertFalse(json.getBoolean("canHangUp"))
        assertEquals("Message", json.getJSONArray("actions").getJSONObject(0).getString("label"))
        // Absence is the signal, exactly as it is for `resync` on a notification.
        assertFalse(json.has("resync"))
        assertTrue(Messages.callState(call, resync = true).getBoolean("resync"))
    }

    @Test fun `a call with no caller details omits them rather than sending blanks`() {
        val call = CallSnapshot(
            id = "k", state = CallState.ENDED, direction = CallDirection.OUTGOING,
            pkg = "com.dialer", appLabel = "Phone", displayName = null, number = null,
            isVideo = false, whenMs = 1, canAnswer = false, canDecline = false,
            canHangUp = false
        )
        val json = Messages.callState(call, resync = false)
        assertFalse(json.has("displayName"))
        assertFalse(json.has("number"))
        assertFalse(json.has("iconHash"))
        assertEquals(0, json.getJSONArray("actions").length())
    }

    @Test fun `a failed call action reports the sentence the user will read`() {
        val json = Messages.callActionResult(
            "9F3B", "k", CallAction.ANSWER, ok = false, error = "That call is not ringing."
        )
        assertEquals("call.action.result", json.getString("type"))
        assertEquals("9F3B", json.getString("clientId"))
        assertEquals("answer", json.getString("action"))
        assertFalse(json.getBoolean("ok"))
        assertEquals("That call is not ringing.", json.getString("error"))
        // Success carries no error key at all.
        assertFalse(
            Messages.callActionResult(null, "k", CallAction.HANGUP, true, null).has("error")
        )
    }

    // MARK: - Files

    private val fileOffer = FileOfferHeader(
        id = "a1b2c3d4", name = "screen-20250817-005420.mp4", bytes = 14_417_920L,
        mime = "video/mp4", sha256 = "b".repeat(64), modified = 1_723_900_000_000L
    )

    @Test fun helloAdvertisesFileTransfer() {
        val hello = Messages.hello("id", "Phone", "Model", 36, 90, token, null)
        val capabilities = hello.getJSONArray("capabilities")
        val advertised = (0 until capabilities.length()).map { capabilities.getString(it) }
        assertTrue(advertised.contains(Proto.FILE_TRANSFER_CAPABILITY))
    }

    @Test fun fileOfferRoundTrips() {
        val json = Messages.fileOffer(fileOffer)
        assertEquals("file.offer", json.getString("type"))
        assertEquals(Proto.VERSION, json.getInt("v"))
        assertEquals(fileOffer, FileOfferHeader.parse(json))
    }

    @Test fun `a modification time is omitted rather than nulled`() {
        val json = Messages.fileOffer(fileOffer.copy(modified = null))
        // Absent rather than null: the Mac decodes this into an optional.
        assertFalse(json.has("modified"))
        assertNull(FileOfferHeader.parse(json)?.modified)
    }

    @Test fun fileOfferValidationIsStrict() {
        assertTrue(fileOffer.isValid)
        assertFalse(fileOffer.copy(bytes = 0).isValid)
        assertFalse(fileOffer.copy(bytes = Proto.MAX_FILE_BYTES + 1).isValid)
        assertFalse(fileOffer.copy(sha256 = "B".repeat(64)).isValid)
        assertFalse(fileOffer.copy(id = "abc").isValid)
        assertFalse(fileOffer.copy(id = "not hex!").isValid)
        assertFalse(fileOffer.copy(mime = "x".repeat(101)).isValid)
    }

    /**
     * The name is the one field a hostile peer controls that could name a path. The offer
     * is refused outright rather than repaired, and nothing is ever stored under it.
     */
    @Test fun `a name that could name a path is refused`() {
        assertFalse(fileOffer.copy(name = "../../.ssh/authorized_keys").isValid)
        assertFalse(fileOffer.copy(name = "sub/dir.txt").isValid)
        assertFalse(fileOffer.copy(name = "windows\\path.txt").isValid)
        assertFalse(fileOffer.copy(name = "..").isValid)
        assertFalse(fileOffer.copy(name = "").isValid)
        assertFalse(fileOffer.copy(name = "n".repeat(256)).isValid)
        // Legitimate names that merely look alarming still pass.
        assertTrue(fileOffer.copy(name = "..notes..txt").isValid)
        assertTrue(fileOffer.copy(name = "r\u00e9sum\u00e9 (final) [v2].pdf").isValid)
    }

    @Test fun chunkHeaderRoundTripsAndBoundsItself() {
        val json = Messages.fileChunk("a1b2c3d4", 3_145_728L, 262_144)
        assertEquals("file.chunk", json.getString("type"))
        assertEquals(
            FileChunkHeader("a1b2c3d4", 3_145_728L, 262_144),
            FileChunkHeader.parse(json)
        )
        assertFalse(FileChunkHeader("a1b2c3d4", -1L, 1).isValid)
        assertFalse(FileChunkHeader("a1b2c3d4", 0L, Proto.FILE_CHUNK_BYTES + 1).isValid)
        assertFalse(FileChunkHeader("a1b2c3d4", 0L, 0).isValid)
    }

    @Test fun beginAckAndDoneCarryWhatTheyMust() {
        assertEquals(0L, Messages.fileBegin("a1b2c3d4", 0L).getLong("offset"))
        assertEquals(3_407_872L, Messages.fileAck("a1b2c3d4", 3_407_872L).getLong("received"))
        assertEquals("file.done", Messages.fileDone("a1b2c3d4").getString("type"))
        assertEquals("user", Messages.fileCancel("a1b2c3d4", "user").getString("reason"))
    }

    @Test fun aSuccessfulFileResultCarriesNoErrorKey() {
        val ok = Messages.fileResult("a1b2c3d4", true, null)
        assertTrue(ok.getBoolean("ok"))
        // Absent rather than null: the Mac decodes this into an optional.
        assertFalse(ok.has("error"))

        val bad = Messages.fileResult("a1b2c3d4", false, "checksum mismatch")
        assertFalse(bad.getBoolean("ok"))
        assertEquals("checksum mismatch", bad.getString("error"))
    }
}
