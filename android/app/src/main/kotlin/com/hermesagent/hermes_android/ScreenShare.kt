package com.hermesagent.hermes_android

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Toast

// The preview is a local sink only. Do not hook this up to a remote transport
// without showing the destination and asking the user to approve it separately.
class ScreenPreviewActivity : Activity(), SurfaceHolder.Callback {
    private var requestPending = false
    private var pendingConsent: Intent? = null
    private var visible = false
    private var serviceStarted = false
    private var surface: Surface? = null
    private var width = 0
    private var height = 0
    private val manager get() = getSystemService(MediaProjectionManager::class.java)

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        requestPending = state?.getBoolean("pending") == true
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(Button(context).apply {
                setText(R.string.screen_preview_start)
                setOnClickListener {
                    if (requestPending || ScreenShareService.active) return@setOnClickListener
                    val projectionManager = manager
                    if (projectionManager == null) {
                        message(R.string.screen_preview_unavailable)
                        return@setOnClickListener
                    }
                    try {
                        startActivityForResult(projectionManager.createScreenCaptureIntent(), CONSENT)
                        requestPending = true
                    } catch (_: RuntimeException) {
                        message(R.string.screen_preview_unavailable)
                    }
                }
            })
            addView(Button(context).apply {
                setText(R.string.screen_preview_stop)
                setOnClickListener { finish() }
            })
            addView(SurfaceView(context).apply {
                holder.addCallback(this@ScreenPreviewActivity)
            }, LinearLayout.LayoutParams(-1, 0, 1f))
        })
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
        pendingConsent = data
        startIfReady()
    }

    override fun onPostResume() {
        super.onPostResume()
        visible = true
        startIfReady()
    }

    private fun startIfReady() {
        val consent = pendingConsent ?: return
        val sink = surface ?: return
        if (!visible || !sink.isValid || width <= 0 || height <= 0) return
        pendingConsent = null
        val command = Intent(this, ScreenShareService::class.java)
            .putExtra("consent", consent)
            .putExtra("sink", sink)
            .putExtra("width", width)
            .putExtra("height", height)
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(command) else startService(command)
            serviceStarted = true
        } catch (_: RuntimeException) {
            message(R.string.screen_preview_unavailable)
        }
    }

    private fun message(id: Int) = Toast.makeText(this, id, Toast.LENGTH_SHORT).show()

    override fun surfaceCreated(holder: SurfaceHolder) { surface = holder.surface }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {
        width = w
        height = h
        startIfReady()
    }
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surface = null
        stopPreview()
    }

    override fun onStop() {
        visible = false
        pendingConsent = null
        stopPreview()
        super.onStop()
    }

    private fun stopPreview() {
        if (serviceStarted) {
            stopService(Intent(this, ScreenShareService::class.java))
            serviceStarted = false
        }
    }

    private companion object { const val CONSENT = 6091 }
}

internal fun hasProjectionConsent(result: Int, data: Intent?) =
    result == Activity.RESULT_OK && data != null

class ScreenShareService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var sink: Surface? = null
    private val callback = object : MediaProjection.Callback() {
        override fun onStop() { stopSelf() }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (active) return START_NOT_STICKY
        try {
            startForeground(37101, notification())
            val consent = requireNotNull(intent?.getParcelableExtra<Intent>("consent"))
            val surface = requireNotNull(intent.getParcelableExtra<Surface>("sink"))
            sink = surface
            check(surface.isValid)
            val manager = getSystemService(MediaProjectionManager::class.java)
            val session = requireNotNull(manager?.getMediaProjection(Activity.RESULT_OK, consent))
            projection = session
            session.registerCallback(callback, Handler(Looper.getMainLooper()))
            display = requireNotNull(session.createVirtualDisplay(
                "Hermes local screen preview", intent.getIntExtra("width", 0),
                intent.getIntExtra("height", 0), resources.displayMetrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null,
            ))
            active = true
        } catch (_: RuntimeException) {
            Toast.makeText(this, R.string.screen_preview_unavailable, Toast.LENGTH_SHORT).show()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.screen_preview), NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, CHANNEL)
        } else Notification.Builder(this)
        val stop = PendingIntent.getService(this, 0, Intent(this, javaClass).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE)
        return builder.setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle(getString(R.string.screen_preview))
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, getText(R.string.screen_preview_stop), stop).build())
            .build()
    }

    override fun onDestroy() {
        active = false
        display?.release()
        display = null
        projection?.let {
            it.unregisterCallback(callback)
            it.stop()
        }
        projection = null
        sink?.release()
        sink = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "local_screen_preview"
        private const val STOP = "stop_preview"
        var active = false
            private set
    }
}
