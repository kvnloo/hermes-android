package com.hermesagent.hermes_android

import android.app.Activity
import android.content.Intent
import android.view.Display
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Redrawing the window for Glass relaunches the task on the display it was on. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class GlassWindowRelaunchTest {
    private fun activity() = Robolectric.buildActivity(Activity::class.java).setup().get()

    @Test fun secondaryDisplayRelaunchStaysOnThatDisplay() {
        assertEquals(7, relaunchOptions(7)!!.launchDisplayId)
    }

    @Test fun defaultDisplayRelaunchAddsNoLaunchDisplay() {
        assertNull(relaunchOptions(Display.DEFAULT_DISPLAY))
        assertNull(relaunchOptions(Display.INVALID_DISPLAY))
    }

    @Test @Config(sdk = [25])
    fun launchDisplayIsSkippedBelowApi26() {
        assertNull(relaunchOptions(7))
    }

    @Test fun relaunchFromSecondaryDisplayStartsNewTaskWithItsOptions() {
        val activity = activity()
        GlassWindowPlugin(activity).relaunch(displayId = 7)
        val started = shadowOf(activity).nextStartedActivityForResult
        val flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        assertEquals(flags, started.intent.flags and flags)
        assertEquals(activity.javaClass.name, started.intent.component!!.className)
        assertEquals(7, started.options!!.getInt("android.activity.launchDisplayId", -1))
        assertTrue(activity.isFinishing)
    }

    @Test fun relaunchFromDefaultDisplayIsUnchanged() {
        val activity = activity()
        GlassWindowPlugin(activity).relaunch()
        val started = shadowOf(activity).nextStartedActivityForResult
        assertNull(started.options)
        assertTrue(activity.isFinishing)
    }
}
