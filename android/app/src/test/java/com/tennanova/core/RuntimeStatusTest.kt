package com.tennanova.core

import com.tennanova.clipboard.ClipboardAccessStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class RuntimeStatusTest {
    @Test fun connectionClipboardAndTransferErrorsRemainIndependent() {
        RuntimeStatusStore.updateConnection(ConnectionStatus.DISCONNECTED, "connection")
        RuntimeStatusStore.updateClipboard(ClipboardAccessStatus.ERROR, "clipboard")
        RuntimeStatusStore.transfer("Image rejected", "transfer")

        val state = RuntimeStatusStore.state.value
        assertEquals("connection", state.connectionError)
        assertEquals("clipboard", state.clipboardError)
        assertEquals("transfer", state.transferError)
    }
}
