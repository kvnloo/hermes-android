package com.hermesagent.hermes_android

import android.app.Activity
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ScreenShareTest {
    @Test fun captureKeepsAspectRatioAndBoundsMemory() {
        assertEquals(640 to 1280, screenShareSize(1440, 2880))
        assertEquals(320 to 240, screenShareSize(320, 240))
    }

    @Test fun cancellationCannotStartProjectionEvenIfThereIsData() {
        assertFalse(hasProjectionConsent(Activity.RESULT_CANCELED, Intent()))
    }

    @Test fun resultMustContainASingleUseConsentToken() {
        assertFalse(hasProjectionConsent(Activity.RESULT_OK, null))
        assertTrue(hasProjectionConsent(Activity.RESULT_OK, Intent()))
    }
}
