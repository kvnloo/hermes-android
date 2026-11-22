package com.hermesagent.hermes_android

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

internal class DocumentScanner(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.hermesagent.hermes_android/document_scanner")
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var awaitingActivity = false
    private var unsupported = false
    private var pageLimit = MAX_PAGES

    init {
        channel.setMethodCallHandler { call, reply ->
            when (call.method) {
                "isAvailable" -> reply.success(isAvailable())
                "scan" -> start(call.argument<Boolean>("singlePage") == true, reply)
                else -> reply.notImplemented()
            }
        }
    }

    private fun isAvailable(): Boolean = !unsupported && runCatching {
        val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }
        info.totalMem >= 1_700_000_000 &&
            GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity) ==
            ConnectionResult.SUCCESS
    }.getOrDefault(false)

    private fun start(singlePage: Boolean, reply: MethodChannel.Result) {
        if (pending != null) {
            reply.error("busy", null, null)
            return
        }
        if (!isAvailable()) {
            reply.error("unavailable", null, null)
            return
        }
        pending = reply
        pageLimit = if (singlePage) 1 else MAX_PAGES
        try {
            val options = GmsDocumentScannerOptions.Builder()
                .setGalleryImportAllowed(true)
                .setPageLimit(pageLimit)
                .setResultFormats(
                    GmsDocumentScannerOptions.RESULT_FORMAT_JPEG,
                    GmsDocumentScannerOptions.RESULT_FORMAT_PDF,
                )
                .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
                .build()
            GmsDocumentScanning.getClient(options).getStartScanIntent(activity)
                .addOnSuccessListener { sender ->
                    if (pending === reply) {
                        try {
                            awaitingActivity = true
                            activity.startIntentSenderForResult(sender, REQUEST_CODE, null, 0, 0, 0)
                        } catch (_: Exception) {
                            fail("module_unavailable")
                        }
                    }
                }
                .addOnFailureListener { error ->
                    if (pending === reply) {
                        unsupported = error is MlKitException && error.errorCode == MlKitException.UNSUPPORTED
                        fail(if (unsupported || !isAvailable()) "unavailable" else "module_unavailable")
                    }
                }
                .addOnCanceledListener { if (pending === reply) finish(null) }
        } catch (_: Exception) {
            fail("module_unavailable")
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val reply = pending ?: return true
        if (!awaitingActivity) return true
        awaitingActivity = false
        when (resultCode) {
            Activity.RESULT_CANCELED -> finish(null)
            Activity.RESULT_OK -> {
                val sources = runCatching {
                    val scan = GmsDocumentScanningResult.fromActivityResultIntent(data)
                        ?: error("Missing scan")
                    scanSources(
                        scan.pages.orEmpty().map { it.imageUri },
                        scan.pdf?.uri,
                        scan.pdf?.pageCount,
                        pageLimit,
                    )
                }.getOrElse {
                    fail("invalid_result")
                    return true
                }
                worker.execute {
                    val files = mutableListOf<File>()
                    val result = runCatching {
                        sources.map { (uri, format) ->
                            val file = File.createTempFile("document-scan-", ".$format", activity.cacheDir)
                            files.add(file)
                            activity.contentResolver.openInputStream(uri)?.use { input ->
                                file.outputStream().use { output ->
                                    val buffer = ByteArray(8192)
                                    var total = 0L
                                    while (true) {
                                        val count = input.read(buffer)
                                        if (count < 0) break
                                        total += count
                                        if (total > MAX_FILE_BYTES) throw IOException("Scan too large")
                                        output.write(buffer, 0, count)
                                    }
                                    if (total == 0L) throw IOException("Empty scan")
                                }
                            } ?: throw IOException("Unreadable scan")
                            mapOf("path" to file.absolutePath, "format" to format)
                        }
                    }
                    activity.runOnUiThread {
                        if (pending !== reply || result.isFailure) {
                            files.forEach { it.delete() }
                            if (pending === reply) fail("invalid_result")
                        } else {
                            finish(result.getOrThrow())
                        }
                    }
                }
            }
            else -> fail("module_unavailable")
        }
        return true
    }

    fun close() {
        channel.setMethodCallHandler(null)
        finish(null)
        worker.shutdown()
    }

    private fun finish(value: Any?) {
        val reply = pending
        pending = null
        awaitingActivity = false
        reply?.success(value)
    }

    private fun fail(code: String) {
        val reply = pending
        pending = null
        awaitingActivity = false
        reply?.error(code, null, null)
    }

    companion object {
        // Separate from the existing APK installer and attachment saver codes.
        private const val REQUEST_CODE = 0x5ca1
        private const val MAX_PAGES = 5
        private const val MAX_FILE_BYTES = 16L * 1024 * 1024
    }
}

internal fun scanSources(
    pages: List<Uri>, pdf: Uri?, pdfPageCount: Int?, pageLimit: Int,
): List<Pair<Uri, String>> {
    require(pdf != null && pages.size in 1..pageLimit && pdfPageCount == pages.size)
    return listOf(pdf to "pdf") + pages.map { it to "jpg" }
}
