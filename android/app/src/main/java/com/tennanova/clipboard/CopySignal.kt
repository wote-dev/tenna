package com.tennanova.clipboard

import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The parts of an [AccessibilityEvent] the copy decision needs, lifted into plain data so the
 * rule can be exercised without a device.
 */
internal data class CopyEventFacts(
    val eventType: Int,
    val action: Int = 0,
    val packageName: String = "",
    val className: String = "",
    val text: String = "",
    val contentDescription: String = "",
    val fromIndex: Int = -1,
    val toIndex: Int = -1,
    val isPassword: Boolean = false
)

/**
 * Decides which accessibility events look like a copy — and, just as importantly, which ones
 * must not.
 *
 * The second half is where the cost is. A false positive makes the service put a focus-taking
 * window over whatever app the user is in, and the events that used to produce one — a
 * keystroke, a tap into a text field — are exactly the events that happen while a keyboard is
 * on screen. So the weak evidence (a SystemUI window appearing shortly after the user touched
 * something) is only trusted when the touch itself was plausibly part of a copy.
 */
internal class CopySignalDetector {

    /**
     * When the user last did something a copy could plausibly follow, or 0 when nothing is
     * pending. Typing clears it rather than merely failing to set it.
     */
    private var armedAt = 0L

    fun isCopySignal(facts: CopyEventFacts, now: Long): Boolean {
        if (facts.action == AccessibilityNodeInfo.ACTION_COPY) return true
        if (facts.describesClipboard) return true

        // SystemUI raises its clipboard chip immediately after a copy. Requiring a recent
        // *touch* rather than a recent text selection is what lets image copies through:
        // selecting text is a thing only text copies do, so an image copy never opened this
        // window and was caught only when the chip happened to describe itself.
        if (facts.isSystemUiWindow && armedAt != 0L &&
            now - armedAt <= INTERACTION_COPY_WINDOW_MS) return true

        updateArming(facts, now)

        // Copy context-menu clicks are the most common signal on apps whose SystemUI
        // clipboard overlay does not expose a descriptive class name.
        if (facts.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED) {
            return looksLikeCopyCommand(facts.text) || looksLikeCopyCommand(facts.contentDescription)
        }
        return false
    }

    private fun updateArming(facts: CopyEventFacts, now: Long) {
        when (facts.eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED ->
                // A copy always starts from a selected range; typing only ever moves a caret.
                // Disarming on the caret is the point of this branch rather than a side
                // effect — it shuts the window a previous selection opened the instant the
                // user goes back to typing, so a passing SystemUI event cannot be mistaken
                // for a copy mid-sentence.
                armedAt = if (facts.hasSelectionRange) now else 0L

            AccessibilityEvent.TYPE_VIEW_CLICKED ->
                // Tapping *into* a text field is the one click that reliably precedes a
                // keyboard rather than a copy, and the keyboard's own arrival is a SystemUI
                // window event.
                if (!facts.isTextEditor) armedAt = now
        }
    }

    private val CopyEventFacts.describesClipboard: Boolean
        get() {
            // `text` on a selection change is the whole field being edited, so searching it
            // there would make typing the word "copied" a copy signal on every keystroke
            // that followed. It is only meaningful where it names a control or a chip.
            val quotesText = eventType == AccessibilityEvent.TYPE_VIEW_CLICKED || isSystemUiWindow
            val metadata = buildString {
                append(className.lowercase())
                append(' ')
                append(contentDescription.lowercase())
                if (quotesText) {
                    append(' ')
                    append(text.lowercase())
                }
            }
            return "clipboard" in metadata || "copied" in metadata
        }

    private val CopyEventFacts.isSystemUiWindow: Boolean
        get() = packageName == SYSTEM_UI_PACKAGE && eventType in WINDOW_EVENT_TYPES

    private val CopyEventFacts.hasSelectionRange: Boolean
        get() = fromIndex >= 0 && toIndex >= 0 && fromIndex != toIndex

    private val CopyEventFacts.isTextEditor: Boolean
        get() = isPassword || className.lowercase().let { name ->
            EDITOR_CLASS_HINTS.any { it in name }
        }

    private companion object {
        const val SYSTEM_UI_PACKAGE = "com.android.systemui"
        const val INTERACTION_COPY_WINDOW_MS = 2_000L
        val EDITOR_CLASS_HINTS = listOf("edittext", "autocompletetextview", "searchview")
        val WINDOW_EVENT_TYPES = setOf(
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED
        )
    }
}

internal fun AccessibilityEvent.copyFacts(): CopyEventFacts = CopyEventFacts(
    eventType = eventType,
    action = action,
    packageName = packageName?.toString().orEmpty(),
    className = className?.toString().orEmpty(),
    text = text.joinToString(" "),
    contentDescription = contentDescription?.toString().orEmpty(),
    fromIndex = fromIndex,
    toIndex = toIndex,
    isPassword = isPassword
)
