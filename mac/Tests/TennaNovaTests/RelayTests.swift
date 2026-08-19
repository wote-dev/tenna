import Testing
@testable import TennaNova

/// The room id is computed independently by the Mac, the relay server and the phone.
/// If any two of those disagree by a single character the phone silently knocks on a
/// door that does not exist, so the vectors are pinned here and mirrored in
/// `relay/test/relay.test.js` and `RelayConfigTest.kt`.
struct RelayTests {

    @Test func roomIdMatchesTheRelayImplementation() {
        #expect(Relay.roomId(for: "tennanova-test-vector")
                == "JNtIvh6Lm1ONInKzeCuo_S4Mx7LaKPT8d3evEOvspII")
        #expect(Relay.roomId(for: "")
                == "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
        // Real secrets are base64, so the characters base64url has to rewrite are
        // exactly the ones a secret is most likely to contain.
        #expect(Relay.roomId(for: "AAAA/++=vector")
                == "iLddcQgCzexerMOW_AdBBxjxiwLEywPUh0iKVYIFnbQ")
    }

    @Test func roomIdsAreSafeInQueryStringsAndQRCodes() {
        let id = Relay.roomId(for: TLSIdentity.randomToken())
        #expect(!id.contains("+"))
        #expect(!id.contains("/"))
        #expect(!id.contains("="))
    }

    @Test func theRoomIdCannotBeWalkedBackToTheSecret() {
        // Not a proof of anything cryptographic — just a guard against someone
        // "simplifying" the hash away and shipping the secret to every phone.
        let secret = TLSIdentity.randomToken()
        #expect(Relay.roomId(for: secret) != secret)
    }

    @Test func urlsCarryTheSecretAndStreamThroughToTheRelay() throws {
        let control = try #require(Relay.controlURL(secret: "AAAA/++=vector"))
        #expect(control.scheme == "wss")
        #expect(control.path == "/v1/host")
        // The literal secret must survive percent-encoding intact, or the relay hashes
        // something else and the Mac ends up hosting a room nobody can find.
        #expect(control.query?.contains("secret=AAAA%2F%2B%2B%3Dvector") == true)

        let accept = try #require(Relay.acceptURL(secret: "s3cret", sid: "abc"))
        #expect(accept.path == "/v1/accept")
        #expect(accept.query?.contains("sid=abc") == true)
    }
}
