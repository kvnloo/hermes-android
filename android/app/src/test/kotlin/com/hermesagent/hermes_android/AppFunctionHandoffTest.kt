package com.hermesagent.hermes_android

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class AppFunctionHandoffTest {
    @Test fun promptIsBoundedAndNeverBecomesAnAction() {
        assertNull(appFunctionDraft("   "))
        assertNull(appFunctionDraft("a".repeat(4001)))
        assertEquals("Hello", appFunctionDraft(" Hello "))
        val context = RuntimeEnvironment.getApplication()
        val intent = AppFunctionHandoff.draft(context, "Hello")
        assertEquals(Intent.ACTION_SEND, intent.action)
        assertEquals("Hello", intent.getStringExtra(Intent.EXTRA_TEXT))
    }

    @Test fun concurrentDraftsHaveDifferentPendingIntentIdentities() {
        val context = RuntimeEnvironment.getApplication()
        assertNotEquals(
            AppFunctionHandoff.pending(context, AppFunctionHandoff.draft(context, "first")),
            AppFunctionHandoff.pending(context, AppFunctionHandoff.draft(context, "second")),
        )
    }
}
