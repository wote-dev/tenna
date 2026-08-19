package com.tennanova.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The store that decides whether a conversation can still be replied to.
 *
 * Typed with Strings rather than `Notification.Action`, which is exactly why
 * [RetainedActions] is generic: the behaviour worth testing needs no Android runtime.
 */
class RetainedActionsTest {

    @Test fun `actions survive the notification being removed`() {
        val actions = RetainedActions<String>()
        actions.put("k1", "reply")

        // Nothing is called on removal any more. This is the whole fix: messaging apps
        // withdraw their notification as soon as the chat is read on the phone, and
        // dropping the actions there is what made almost every thread unreplyable.
        assertEquals("reply", actions.get("k1"))
    }

    @Test fun `a repost replaces the previous action list`() {
        val actions = RetainedActions<String>()
        actions.put("k1", "old")
        actions.put("k1", "new")

        // `actionId` is a positional index into whichever post carried it, so a stale
        // list would fire the wrong button.
        assertEquals("new", actions.get("k1"))
        assertEquals(1, actions.size)
    }

    @Test fun `an unknown key has nothing to reply through`() {
        assertNull(RetainedActions<String>().get("never seen"))
    }

    @Test fun `forgetting a key drops it`() {
        val actions = RetainedActions<String>()
        actions.put("k1", "reply")
        actions.forget("k1")

        assertNull(actions.get("k1"))
    }

    @Test fun `the store is bounded, oldest first`() {
        val limit = 4
        val actions = RetainedActions<String>(limit)
        repeat(limit + 2) { actions.put("k$it", "reply$it") }

        // Each entry holds PendingIntents, so this cannot grow for as long as the
        // service is bound.
        assertEquals(limit, actions.size)
        assertNull(actions.get("k0"))
        assertNull(actions.get("k1"))
        assertNotNull(actions.get("k5"))
    }

    @Test fun `a conversation being replied to is the last to be evicted`() {
        val limit = 3
        val actions = RetainedActions<String>(limit)
        actions.put("chat", "reply")
        actions.put("a", "x")
        actions.put("b", "x")

        // Reading counts as using it, so an active conversation outlives the noise of
        // every transactional notification arriving around it.
        assertNotNull(actions.get("chat"))
        actions.put("c", "x")
        actions.put("d", "x")

        assertNotNull(actions.get("chat"))
        assertNull(actions.get("a"))
    }
}
