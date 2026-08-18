package com.tennanova.clipboard

/**
 * Recognises the label of a "copy" control in a context menu or share sheet.
 *
 * Matched by leading word rather than whole string, because the interesting cases are not bare
 * "Copy": Gallery and Chrome say **"Copy image"**, share sheets say "Copy photo", browsers say
 * "Copy link address". Matching those exactly was why image copies went unnoticed — an image
 * copy produces no text selection either, so the menu label is often the only signal there is.
 *
 * The length cap keeps a sentence that merely opens with "copy" from counting as a command.
 */
internal fun looksLikeCopyCommand(label: String?): Boolean {
    val trimmed = label?.trim()?.lowercase().orEmpty()
    if (trimmed.isEmpty() || trimmed.length > MAX_COPY_LABEL_LENGTH) return false
    return COPY_VERBS.any { verb -> trimmed == verb || trimmed.startsWith("$verb ") }
}

private const val MAX_COPY_LABEL_LENGTH = 40

private val COPY_VERBS = setOf(
    "copy",
    "copier",   // fr
    "copiar",   // es / pt
    "copia",    // it
    "kopieren", // de
    "kopiëren", // nl
    "kopiera",  // sv
    "kopyala",  // tr
    "копировать"
)
