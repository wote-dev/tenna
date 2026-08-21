package com.tennanova.notifications

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SelfMessageTest {

    private val now = 1_000_000L

    private fun ours(
        post: SelfMessage.Post,
        reply: SelfMessage.SentReply? = null,
        at: Long = now
    ) = SelfMessage.isOurOwn(post, reply, at)

    @Test fun `an incoming chat message is not ours`() {
        assertFalse(ours(SelfMessage.Post(
            hasMessages = true,
            lastSenderName = "Declan",
            selfName = "You",
            title = "Declan",
            body = "That's fine with me mate"
        )))
    }

    @Test fun `a message the style attributes to nobody is ours`() {
        // A null Person is how both MessagingStyle and its androidx twin say "the user".
        assertTrue(ours(SelfMessage.Post(hasMessages = true, title = "Declan", body = "on my way")))
    }

    @Test fun `a message from the style's own user is ours`() {
        assertTrue(ours(SelfMessage.Post(
            hasMessages = true, lastSenderName = "You", selfName = "You",
            title = "Declan", body = "on my way"
        )))
    }

    @Test fun `a message keyed to the style's own user is ours`() {
        // Two people can share a display name; a Person key is the identity that cannot.
        assertTrue(ours(SelfMessage.Post(
            hasMessages = true,
            lastSenderName = "Daniel", lastSenderKey = "self",
            selfName = "Daniel Z", selfKey = "self",
            title = "Declan", body = "on my way"
        )))
    }

    @Test fun `a repost titled with the user rather than the chat is ours`() {
        // WhatsApp's answer to a reply: the collapsed line names the speaker, so the chat
        // name is gone and "You" arrives where "Declan" used to be.
        assertTrue(ours(SelfMessage.Post(
            hasMessages = true, lastSenderName = "You", selfName = "You",
            title = "You", body = "on my way"
        )))
        assertTrue(ours(SelfMessage.Post(
            hasMessages = true, lastSenderName = "Someone else", selfName = "You",
            conversationTitle = "You", body = "on my way"
        )))
    }

    @Test fun `an app with no self name at all suppresses nothing on a name`() {
        // Blank against blank is not evidence, and would silence every notification the
        // phone posts without a title.
        assertFalse(ours(SelfMessage.Post(
            hasMessages = true, lastSenderName = "Declan", selfName = "",
            title = "", body = "hello"
        )))
    }

    @Test fun `the reply the shade is showing is ours`() {
        assertTrue(ours(SelfMessage.Post(
            title = "Declan",
            body = "on my way",
            remoteInputHistory = listOf("on my way", "five minutes")
        )))
    }

    @Test fun `remote input history does not silence a genuinely new message`() {
        // Some apps leave the history in place. What the notification is *showing* is the
        // test, not what it remembers.
        assertFalse(ours(SelfMessage.Post(
            hasMessages = true, lastSenderName = "Declan", selfName = "You",
            title = "Declan",
            body = "see you then",
            remoteInputHistory = listOf("on my way")
        )))
    }

    @Test fun `a reply this phone fired comes back as ours`() {
        val reply = SelfMessage.SentReply("Thanks Declan, see you next week.", now - 2_000)
        assertTrue(ours(
            SelfMessage.Post(title = "Declan", body = "Thanks Declan, see you next week."),
            reply
        ))
    }

    @Test fun `whitespace does not defeat the match`() {
        val reply = SelfMessage.SentReply(" on my way ", now - 2_000)
        assertTrue(ours(SelfMessage.Post(title = "Declan", body = "on my way"), reply))
    }

    @Test fun `a stale reply stops suppressing`() {
        // Otherwise sending "ok" once would swallow every "ok" that chat ever receives.
        val reply = SelfMessage.SentReply("ok", now - SelfMessage.OWN_REPLY_WINDOW_MS - 1)
        assertFalse(ours(SelfMessage.Post(title = "Declan", body = "ok"), reply))
    }

    @Test fun `a different message from the same chat still arrives`() {
        val reply = SelfMessage.SentReply("on my way", now - 2_000)
        assertFalse(ours(SelfMessage.Post(title = "Declan", body = "no rush"), reply))
    }

    @Test fun `an ordinary non-chat notification is not ours`() {
        assertFalse(ours(SelfMessage.Post(
            title = "Delivered", body = "Your parcel is at the door"
        )))
    }

    @Test fun `an empty body cannot match a reply`() {
        // Every text-less notification would otherwise look like the last thing we sent.
        val reply = SelfMessage.SentReply("", now - 2_000)
        assertFalse(ours(SelfMessage.Post(title = "Declan", body = ""), reply))
    }
}
