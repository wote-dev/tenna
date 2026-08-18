package com.tennanova.clipboard

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CopyCommandTest {

    @Test fun bareCopyIsACommand() {
        assertTrue(looksLikeCopyCommand("Copy"))
        assertTrue(looksLikeCopyCommand("  copy  "))
    }

    @Test fun imageCopyLabelsAreCommands() {
        // The regression this whole matcher exists for: these never matched, so copying a
        // picture went unnoticed unless SystemUI happened to describe its own chip.
        assertTrue(looksLikeCopyCommand("Copy image"))
        assertTrue(looksLikeCopyCommand("Copy photo"))
        assertTrue(looksLikeCopyCommand("Copy picture"))
    }

    @Test fun otherSuffixedLabelsStillMatch() {
        assertTrue(looksLikeCopyCommand("Copy text"))
        assertTrue(looksLikeCopyCommand("Copy link address"))
        assertTrue(looksLikeCopyCommand("Copy to clipboard"))
    }

    @Test fun translatedLabelsMatch() {
        assertTrue(looksLikeCopyCommand("Kopieren"))
        assertTrue(looksLikeCopyCommand("Copiar imagen"))
        assertTrue(looksLikeCopyCommand("Copier l'image"))
    }

    @Test fun unrelatedLabelsAreNotCommands() {
        assertFalse(looksLikeCopyCommand(null))
        assertFalse(looksLikeCopyCommand(""))
        assertFalse(looksLikeCopyCommand("Share"))
        assertFalse(looksLikeCopyCommand("Copyright"))
        assertFalse(looksLikeCopyCommand("Send a copy"))
    }

    @Test fun proseThatMerelyStartsWithCopyIsNotACommand() {
        assertFalse(
            looksLikeCopyCommand(
                "Copy the pairing code from the Mac menu bar and paste it here to continue"
            )
        )
    }
}
