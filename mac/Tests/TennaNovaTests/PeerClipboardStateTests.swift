import Testing
@testable import TennaNova

/// Every send the phone did not need makes Android raise a second "Copied" panel, so the
/// interesting assertions here are the ones about *not* sending.
///
/// `shouldSend` is mutating, and `#expect` cannot call a mutating member inline — hence the
/// local bindings.
struct PeerClipboardStateTests {

    @Test func identicalContentIsSentOnlyOnce() {
        var peer = PeerClipboardState()
        let first = peer.shouldSend("text:hello")
        let second = peer.shouldSend("text:hello")
        #expect(first)
        #expect(!second)
    }

    @Test func contentFromThePhoneIsNeverSentBack() {
        var peer = PeerClipboardState()
        peer.note("text:copied on the phone")
        // This is the reconnect path: `hello` pushes the current pasteboard, and without the
        // note above it would push the phone's own clip straight back at it.
        let resent = peer.shouldSend("text:copied on the phone")
        #expect(!resent)
    }

    @Test func aPhoneImageIsSuppressedOnEveryReconnectNotJustTheFirst() {
        var peer = PeerClipboardState()
        peer.note("image:abc")
        let first = peer.shouldSend("image:abc")
        let second = peer.shouldSend("image:abc")
        #expect(!first)
        #expect(!second)
    }

    @Test func copyingSomethingElseThenBackAgainStillSends() {
        var peer = PeerClipboardState()
        let one = peer.shouldSend("text:one")
        let two = peer.shouldSend("text:two")
        let oneAgain = peer.shouldSend("text:one")
        #expect(one)
        #expect(two)
        #expect(oneAgain)
    }

    @Test func aNewlyPairedPhoneGetsTheClipboardEvenIfItIsUnchanged() {
        var peer = PeerClipboardState()
        let before = peer.shouldSend("text:hello")
        peer.reset()
        let afterReset = peer.shouldSend("text:hello")
        #expect(before)
        #expect(afterReset)
    }
}
