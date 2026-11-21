package com.hermesagent.hermes_android

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID

class ScreenCaptureActivity : Activity() {
    private var requestPending = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        requestPending = state?.getBoolean("pending") == true
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(context).apply { setText(R.string.screen_preview_help) })
            addView(Button(context).apply {
                setText(R.string.screen_preview_start)
                setOnClickListener { begin() }
            })
            addView(Button(context).apply {
                setText(android.R.string.cancel)
                setOnClickListener { finish() }
            })
        })
    }

    private fun begin() {
        if (requestPending) return
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS)
            return
        }
        if (!getSystemService(NotificationManager::class.java).areNotificationsEnabled()) {
            message(R.string.screen_preview_notifications)
            return
        }
        val manager = getSystemService(MediaProjectionManager::class.java)
        if (manager == null) {
            message(R.string.screen_preview_unavailable)
            return
        }
        try {
            startActivityForResult(manager.createScreenCaptureIntent(), CONSENT)
            requestPending = true
        } catch (_: RuntimeException) {
            message(R.string.screen_preview_unavailable)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, results)
        if (requestCode == NOTIFICATIONS) {
            // Do not chain OS dialogs. Require another explicit tap.
            if (results.firstOrNull() != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                message(R.string.screen_preview_notifications)
            }
        }
    }

    override fun onSaveInstanceState(state: Bundle) {
        state.putBoolean("pending", requestPending)
        super.onSaveInstanceState(state)
    }

    override fun onActivityResult(request: Int, result: Int, data: Intent?) {
        super.onActivityResult(request, result, data)
        if (request != CONSENT || !requestPending) return
        requestPending = false
        if (!hasProjectionConsent(result, data)) {
            message(R.string.screen_preview_cancelled)
            return
        }
        val command = Intent(this, ScreenShareService::class.java).putExtra(CONSENT_EXTRA, data)
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(command) else startService(command)
            finish()
        } catch (_: RuntimeException) {
            message(R.string.screen_preview_unavailable)
        }
    }

    private fun message(id: Int) = Toast.makeText(this, id, Toast.LENGTH_LONG).show()

    private companion object {
        const val CONSENT = 6091
        const val NOTIFICATIONS = 6092
    }
}

internal fun hasProjectionConsent(result: Int, data: Intent?) =
    result == Activity.RESULT_OK && data != null

internal fun screenShareSize(width: Int, height: Int): Pair<Int, Int> {
    require(width > 0 && height > 0)
    val scale = minOf(1.0, 1280.0 / maxOf(width, height))
    return maxOf(1, (width * scale).toInt()) to maxOf(1, (height * scale).toInt())
}

private const val CONSENT_EXTRA = "projection_consent"

// Allow one still image per consent. No microphone, disk recording, or
// network transport; the image is offered to the existing chat draft flow.
class ScreenShareService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var latest: Image? = null
    private var capturePending = false
    private var completed = false

    // A revoked consent or Stop action must fence any delayed frame delivery
    // immediately, before Android asynchronously calls onDestroy().
    private fun stopCapture() {
        completed = true
        stopSelf()
    }

    private val callback = object : MediaProjection.Callback() {
        override fun onStop() { stopCapture() }
        override fun onCapturedContentResize(width: Int, height: Int) {
            if (display == null || completed) return
            try { resize(width, height) } catch (_: RuntimeException) { stopCapture() }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            STOP -> { stopCapture(); return START_NOT_STICKY }
            CAPTURE -> {
                if (projection == null) {
                    stopCapture()
                } else if (!capturePending && !completed) {
                    capturePending = true
                    // Allow time to close the notification shade before capturing.
                    handler.postDelayed(::capture, 2500)
                }
                return START_NOT_STICKY
            }
        }
        if (projection != null || completed) return START_NOT_STICKY
        try {
            setupChannels()
            startForeground(ONGOING, ongoingNotification())
            val consent = requireNotNull(intent?.getParcelableExtra<Intent>(CONSENT_EXTRA))
            val system = getSystemService(MediaProjectionManager::class.java)
            val session = requireNotNull(system?.getMediaProjection(Activity.RESULT_OK, consent))
            projection = session
            session.registerCallback(callback, handler)
            val windowManager = getSystemService(WindowManager::class.java)
            val dimensions = if (Build.VERSION.SDK_INT >= 30) {
                val bounds = windowManager.maximumWindowMetrics.bounds
                bounds.width() to bounds.height()
            } else {
                val metrics = android.util.DisplayMetrics()
                windowManager.defaultDisplay.getRealMetrics(metrics)
                metrics.widthPixels to metrics.heightPixels
            }
            val (width, height) = screenShareSize(dimensions.first, dimensions.second)
            val frames = newReader(width, height)
            reader = frames
            display = requireNotNull(session.createVirtualDisplay(
                "Hermes screen capture", width, height, resources.displayMetrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, frames.surface, null, handler,
            ))
            handler.postDelayed(::stopCapture, 90_000)
        } catch (_: RuntimeException) {
            Toast.makeText(this, R.string.screen_preview_unavailable, Toast.LENGTH_SHORT).show()
            stopCapture()
        }
        return START_NOT_STICKY
    }

    private fun newReader(width: Int, height: Int): ImageReader =
        ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3).apply {
            setOnImageAvailableListener({ source ->
                if (source == reader && !completed) {
                    // Keep one recent frame in memory so a static target can be
                    // captured too. Two spare slots permit acquireLatestImage.
                    source.acquireLatestImage()?.let { current ->
                        latest?.close()
                        latest = current
                    }
                }
            }, handler)
        }

    private fun capture() {
        if (completed) return
        completed = true
        try {
            val frame = requireNotNull(latest)
            check(getSystemService(NotificationManager::class.java).areNotificationsEnabled())
            publish(frame)
        } catch (_: Exception) {
            Toast.makeText(this, R.string.screen_preview_unavailable, Toast.LENGTH_SHORT).show()
        } finally {
            stopSelf()
        }
    }

    private fun resize(contentWidth: Int, contentHeight: Int) {
        val target = display ?: return
        val (width, height) = screenShareSize(contentWidth, contentHeight)
        val old = reader
        if (old?.width == width && old.height == height) return
        val replacement = newReader(width, height)
        reader = replacement
        latest?.close()
        latest = null
        try {
            target.resize(width, height, resources.displayMetrics.densityDpi)
            target.surface = replacement.surface
        } finally {
            old?.close()
        }
    }

    private fun publish(image: Image) {
        val directory = File(cacheDir, "screen_share").apply { mkdirs() }
        directory.listFiles()?.forEach { it.delete() }
        val file = File(directory, "Screen-${UUID.randomUUID()}.png")
        try {
            val plane = image.planes.single()
            val row = ByteArray(image.width * plane.pixelStride)
            val packed = java.nio.ByteBuffer.allocate(row.size * image.height)
            for (y in 0 until image.height) {
                plane.buffer.position(y * plane.rowStride)
                plane.buffer.get(row)
                packed.put(row)
            }
            packed.flip()
            val bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
            try {
                bitmap.copyPixelsFromBuffer(packed)
                file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            } finally {
                bitmap.recycle()
            }

            val uri = FileProvider.getUriForFile(this, "$packageName.screen_share", file)
            val review = AndroidEntry.intent(this, Intent.ACTION_SEND)
                .setDataAndType(uri, "image/png")
                .putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val click = PendingIntent.getActivity(this, 0, review,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
            getSystemService(NotificationManager::class.java).notify(REVIEW,
                notification(REVIEW_CHANNEL)
                    .setContentTitle(getString(R.string.screen_preview_review))
                    .setContentIntent(click)
                    .setAutoCancel(true)
                    .build())
        } catch (e: Exception) {
            file.delete()
            throw e
        }
    }

    private fun setupChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL,
            getString(R.string.screen_preview), NotificationManager.IMPORTANCE_LOW))
        manager.createNotificationChannel(NotificationChannel(REVIEW_CHANNEL,
            getString(R.string.screen_preview_review), NotificationManager.IMPORTANCE_DEFAULT))
    }

    @Suppress("DEPRECATION")
    private fun notification(channel: String): Notification.Builder =
        (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this))
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setVisibility(Notification.VISIBILITY_PRIVATE)

    private fun ongoingNotification(): Notification = notification(CHANNEL)
        .setContentTitle(getString(R.string.screen_preview))
        .setContentText(getString(R.string.screen_preview_notification))
        .setOngoing(true)
        .addAction(action(CAPTURE, R.string.screen_preview_capture))
        .addAction(action(STOP, R.string.screen_preview_stop))
        .build()

    private fun action(name: String, label: Int): Notification.Action {
        val click = PendingIntent.getService(this, 0, Intent(this, javaClass).setAction(name),
            PendingIntent.FLAG_IMMUTABLE)
        return Notification.Action.Builder(null, getText(label), click).build()
    }

    override fun onDestroy() {
        completed = true
        handler.removeCallbacksAndMessages(null)
        display?.release()
        display = null
        latest?.close()
        latest = null
        reader?.close()
        reader = null
        projection?.let {
            it.unregisterCallback(callback)
            it.stop()
        }
        projection = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private companion object {
        const val CHANNEL = "screen_share"
        const val REVIEW_CHANNEL = "screen_share_review"
        const val STOP = "stop_capture"
        const val CAPTURE = "capture_one_frame"
        const val ONGOING = 37101
        const val REVIEW = 37102
    }
}

class ScreenShareFileProvider : FileProvider()
