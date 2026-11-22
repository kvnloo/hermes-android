package com.hermesagent.hermes_android

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class DeviceAccessTest {
    @Test fun defaultOffAndUnknownToolFailsClosed() = runBlocking {
        val access = DeviceAccess(RuntimeEnvironment.getApplication())
        DeviceSource.entries.forEach { assertFalse(access.enabled(it)) }
        assertEquals(DeviceAccess.error("disabled"), access.execute("device.contacts.find", mapOf("name" to "Alex")))
        assertEquals(DeviceAccess.error("invalid_arguments"), access.execute("device.unknown", emptyMap()))
    }

    @Test fun optedInSourceStillNeedsSystemPermission() = runBlocking {
        val access = DeviceAccess(RuntimeEnvironment.getApplication())
        access.setEnabled(DeviceSource.CONTACTS, true)
        assertEquals(DeviceAccess.error("permission_denied"), access.execute("device.contacts.find", mapOf("name" to "Alex")))
        assertFalse(access.enabled(DeviceSource.CALENDAR))
    }

    @Test fun locationCoordinatesAreCoarsened() {
        assertEquals(12.35, DeviceAccess.roundedCoordinate(12.3456), 0.0)
    }
}
