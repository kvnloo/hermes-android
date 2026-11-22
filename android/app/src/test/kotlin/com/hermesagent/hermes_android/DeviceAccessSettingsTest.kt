package com.hermesagent.hermes_android

import android.Manifest
import android.app.Activity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The Flutter Device access page reads these states; copy and order are the old screen's. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class DeviceAccessSettingsTest {
    private fun activity() = Robolectric.buildActivity(Activity::class.java).setup().get()

    @Test fun everySourceStartsOffInScreenOrder() = runBlocking {
        val launched = mutableListOf<String>()
        val states = DeviceAccessSettings(activity()) { p, _ -> launched += p }.states()
        assertEquals(listOf("HEALTH", "CALENDAR", "CONTACTS", "LOCATION", "ALARM"), states.map { it["source"] })
        assertEquals(
            listOf("Health Connect steps", "Calendar", "Contacts", "Approximate location", "Exact alarms"),
            states.map { it["label"] },
        )
        assertTrue(states.all { it["state"] == "Off" && it["enabled"] == false && it["canRequest"] == false })
        assertTrue(launched.isEmpty())
    }

    @Test fun enabledSourceWithoutPermissionOffersTheGrantAction() = runBlocking {
        val activity = activity()
        val settings = DeviceAccessSettings(activity) { _, _ -> }
        settings.setEnabled(DeviceSource.CALENDAR, true)
        var calendar = settings.states().single { it["source"] == "CALENDAR" }
        assertEquals("Permission denied or not yet granted", calendar["state"])
        assertEquals(true, calendar["canRequest"])

        shadowOf(activity.application).grantPermissions(Manifest.permission.READ_CALENDAR)
        calendar = settings.states().single { it["source"] == "CALENDAR" }
        assertEquals("Permission granted", calendar["state"])
        assertEquals(false, calendar["canRequest"])
    }

    @Test fun healthIsUnavailableBelowApi34() = runBlocking {
        val settings = DeviceAccessSettings(activity()) { _, _ -> }
        settings.setEnabled(DeviceSource.HEALTH, true)
        val health = settings.states().single { it["source"] == "HEALTH" }
        assertEquals("Unavailable on this device", health["state"])
        assertEquals(false, health["canRequest"])
    }

    @Test fun firstRequestPromptsThenAnsweredRequestCompletes() {
        val launched = mutableListOf<String>()
        var answer: (() -> Unit)? = null
        val settings = DeviceAccessSettings(activity()) { p, done -> launched += p; answer = done }
        var result: Boolean? = null
        settings.request(DeviceSource.CONTACTS) { result = it }
        assertEquals(listOf(Manifest.permission.READ_CONTACTS), launched)
        assertNull("waits for the prompt's answer", result)
        answer!!.invoke()
        assertEquals(true, result)
    }
}
