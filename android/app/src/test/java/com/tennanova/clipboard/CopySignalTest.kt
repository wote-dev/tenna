package com.tennanova.clipboard

import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The false negatives here cost a missed copy; the false positives cost a keyboard, in every
 * app on the phone. Both directions are asserted.
 */
class CopySignalTest {

    private val detector = CopySignalDetector()

    private fun caretMove(at: Int, text: String = "hello") = CopyEventFacts(
        eventType = AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
        className = "android.widget.EditText",
        text = text,
        fromIndex = at,
        toIndex = at
    )

    private fun selection(from: Int, to: Int) = CopyEventFacts(
        eventType = AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
        className = "android.widget.EditText",
        text = "hello",
        fromIndex = from,
        toIndex = to
    )

    private fun click(className: String, label: String) = CopyEventFacts(
        eventType = AccessibilityEvent.TYPE_VIEW_CLICKED,
        className = className,
        text = label
    )

    private val systemUiWindow = CopyEventFacts(
        eventType = AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
        packageName = "com.android.systemui"
    )

    @Test fun explicitCopyActionIsAlwaysASignal() {
        assertTrue(
            detector.isCopySignal(
                CopyEventFacts(
                    eventType = AccessibilityEvent.TYPE_VIEW_CLICKED,
                    action = AccessibilityNodeInfo.ACTION_COPY
                ),
                now = 0
            )
        )
    }

    @Test fun selectingTextThenSystemUiChipIsACopy() {
        detector.isCopySignal(selection(from = 0, to = 5), now = 100)
        assertTrue(detector.isCopySignal(systemUiWindow, now = 400))
    }

    @Test fun typingThenSystemUiIsNotACopy() {
        detector.isCopySignal(caretMove(at = 1), now = 100)
        detector.isCopySignal(caretMove(at = 2), now = 160)
        assertFalse(detector.isCopySignal(systemUiWindow, now = 200))
    }

    @Test fun typingAfterASelectionDisarmsIt() {
        detector.isCopySignal(selection(from = 0, to = 5), now = 100)
        detector.isCopySignal(caretMove(at = 5), now = 150)
        assertFalse(detector.isCopySignal(systemUiWindow, now = 200))
    }

    @Test fun tappingIntoATextFieldDoesNotArmTheHeuristic() {
        detector.isCopySignal(click("android.widget.EditText", "Message"), now = 100)
        assertFalse(detector.isCopySignal(systemUiWindow, now = 300))
    }

    @Test fun tappingAnOrdinaryControlStillArmsTheHeuristic() {
        // This is the path an image copy takes: no text selection ever happens, so the tap on
        // the long-press menu is the only thing that can open the window.
        detector.isCopySignal(click("android.widget.ImageView", ""), now = 100)
        assertTrue(detector.isCopySignal(systemUiWindow, now = 300))
    }

    @Test fun aCopyMenuItemIsASignalOnItsOwn() {
        assertTrue(detector.isCopySignal(click("android.widget.TextView", "Copy image"), now = 0))
    }

    @Test fun aChipThatNamesItselfIsASignalWithoutAnyInteraction() {
        assertTrue(
            detector.isCopySignal(
                systemUiWindow.copy(className = "com.android.systemui.ClipboardOverlay"),
                now = 0
            )
        )
    }

    @Test fun typingTheWordCopiedIsNotACopy() {
        assertFalse(
            detector.isCopySignal(
                caretMove(at = 9, text = "I copied that yesterday"),
                now = 100
            )
        )
    }

    @Test fun anOldSelectionNoLongerExplainsASystemUiWindow() {
        detector.isCopySignal(selection(from = 0, to = 5), now = 100)
        assertFalse(detector.isCopySignal(systemUiWindow, now = 100 + 2_500))
    }
}
