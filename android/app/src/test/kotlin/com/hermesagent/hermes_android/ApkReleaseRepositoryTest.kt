package com.hermesagent.hermes_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ApkReleaseRepositoryTest {
    private val tag = "v3.2.6"
    private val name = "app-arm64-v8a-release.apk"
    private val sha = "0037e440f19dad89318902f90a6b8ef29cfe0289304e62fde6b9d4896a6fbff4"

    @Test fun ownerIsKvnloo() {
        assertEquals("kvnloo", ApkReleaseRepository.OWNER)
        assertEquals("hermes-android", ApkReleaseRepository.NAME)
        assertEquals(
            "https://github.com/kvnloo/hermes-android/releases/download/$tag/$name",
            ApkReleaseRepository.downloadUrl(tag, name),
        )
    }

    @Test fun onlyTheConfiguredRepositoryIsAccepted() {
        assertNotNull(ApkUpdateSource.parse(tag, ApkReleaseRepository.downloadUrl(tag, name), name, sha, 123L))
        val otherOwner = "https://github.com/someone-else/hermes-android/releases/download/$tag/$name"
        assertNull(ApkUpdateSource.parse(tag, otherOwner, name, sha, 123L))
    }

    @Test fun playInstallerMeansNoInAppUpdate() {
        assertTrue(ApkUpdatePolicy.isPlayInstall("com.android.vending"))
        assertFalse(ApkUpdatePolicy.isPlayInstall(null))
        assertFalse(ApkUpdatePolicy.isPlayInstall("com.google.android.packageinstaller"))
        assertFalse(ApkUpdatePolicy.isPlayInstall("org.fdroid.fdroid"))
    }
}
