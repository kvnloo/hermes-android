package com.hermesagent.hermes_android

import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class DocumentScannerTest {
    private val pdf = Uri.parse("content://scanner/document.pdf")
    private val page = Uri.parse("content://scanner/page.jpg")

    @Test fun putsPdfFirstAndPreservesPageOrder() {
        val second = Uri.parse("content://scanner/second.jpg")
        assertEquals(
            listOf(pdf to "pdf", page to "jpg", second to "jpg"),
            scanSources(listOf(page, second), pdf, 2, 5),
        )
    }

    @Test fun rejectsMissingOutputsAndMismatchedOrOverLimitPageCounts() {
        assertThrows(IllegalArgumentException::class.java) { scanSources(emptyList(), pdf, 0, 5) }
        assertThrows(IllegalArgumentException::class.java) { scanSources(listOf(page), null, null, 5) }
        assertThrows(IllegalArgumentException::class.java) { scanSources(listOf(page), pdf, 2, 5) }
        assertThrows(IllegalArgumentException::class.java) { scanSources(List(2) { page }, pdf, 2, 1) }
    }
}
