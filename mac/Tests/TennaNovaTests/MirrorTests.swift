import Testing
@testable import TennaNova

struct MirrorTests {
    @Test func packetHeaderParsesInNetworkByteOrder() throws {
        let packet = try #require(MirrorVideoPacket.parse(validMirrorPacketBytes()))
        #expect(packet.keyframe)
        #expect(packet.generation == 0x1234)
        #expect(packet.sequence == 0x10203040)
        #expect(packet.presentationTimeUs == 0x0102030405060708)
        #expect(mirrorAccessUnitBytes(packet) == [0, 0, 0, 1, 0x65])
    }

    @Test func malformedPacketFlagsAndMagicAreRejected() {
        #expect(MirrorVideoPacket.parse(malformedMirrorPacket(flags: 2)) == nil)
        #expect(MirrorVideoPacket.parse(malformedMirrorPacket(corruptMagic: true)) == nil)
    }

    @Test func annexBBecomesLengthPrefixedAVCC() throws {
        #expect(annexBUnitBytes() == [[0x67, 1], [0x68, 2]])
        #expect(annexBAVCCBytes() == [
            0, 0, 0, 2, 0x67, 1,
            0, 0, 0, 2, 0x68, 2
        ])
    }

    @Test func letterboxHitTestingMapsOnlyTheVideo() throws {
        #expect(portraitLetterboxFrame() == [375, 0, 250, 500])
        #expect(portraitLetterboxPoint(x: 100, y: 250) == nil)
        #expect(portraitLetterboxPoint(x: 500, y: 250) == [0.5, 0.5])
    }

    @Test func stateReducerRejectsAStaleRequest() {
        let center = MirrorCenter()
        center.prepareMacRequest("new-request")
        let accepted = center.apply(MirrorStateMessage(
            requestId: "old-request", sessionId: "old-session", state: "starting",
            controlAvailable: true, reason: nil
        ))
        #expect(!accepted)
        #expect(center.sessionId == nil)
    }

    @Test func mirrorConfigRoundTripsItsParameterSets() throws {
        let decoded = try mirrorConfigRoundTrip()
        #expect(decoded.sessionId == "session")
        #expect(decoded.generation == 2)
        #expect(mirrorConfigParameterBytes(decoded) == [[0x67, 1], [0x68, 2]])
        #expect(decoded.isValid)
    }

    @Test func streamAuthenticationRequiresTokenSessionPrimaryAndLocalRoute() {
        let hello = MirrorStreamHello(deviceId: "phone", deviceToken: "secret",
                                      sessionId: "active")
        #expect(MirrorStreamAuthentication.accepts(
            hello, expectedToken: "secret", announcedSessionId: "active",
            localRoute: true, peerSupportsVideo: true, primaryAuthenticated: true
        ))
        #expect(!MirrorStreamAuthentication.accepts(
            hello, expectedToken: "wrong", announcedSessionId: "active",
            localRoute: true, peerSupportsVideo: true, primaryAuthenticated: true
        ))
        #expect(!MirrorStreamAuthentication.accepts(
            hello, expectedToken: "secret", announcedSessionId: "stale",
            localRoute: true, peerSupportsVideo: true, primaryAuthenticated: true
        ))
        #expect(!MirrorStreamAuthentication.accepts(
            hello, expectedToken: "secret", announcedSessionId: "active",
            localRoute: false, peerSupportsVideo: true, primaryAuthenticated: true
        ))
    }
}
