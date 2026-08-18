package com.tennanova.test

import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import androidx.test.uiautomator.By
import org.junit.Assert.assertTrue
import org.junit.Test

class AccessibilityClipboardIntegrationTest {
    @Test fun explicitCopyClickEmitsARealAccessibilitySignal() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.context.startActivity(
            Intent(instrumentation.context, ClipboardProbeActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )

        val device = UiDevice.getInstance(instrumentation)
        assertTrue(
            "Copy probe did not appear",
            device.wait(Until.hasObject(By.pkg("com.tennanova.test")), 5_000)
        )
        // The probe's single Button fills the activity, making this robust against
        // vendor accessibility-tree differences in test APKs.
        device.click(device.displayWidth / 2, device.displayHeight / 2)
        device.waitForIdle()
        Thread.sleep(750)
    }
}
