package com.hermesagent.hermes_android

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel

/** Holds microphone eligibility for an already started, user-visible call.
 *  No mic, peer, credentials or restart behavior are owned by this service. */
class LiveMicrophoneService : Service() {
    companion object {
        const val EXTRA_SESSION = "live_session"
        const val RETURN = "hermes.live.return"
        private const val START = "hermes.live.start"
        private const val MUTE = "hermes.live.mute"
        private const val END = "hermes.live.end"
        private const val CHANNEL = "live_microphone"
        private const val NOTIFICATION = 7804

        private var session: Long? = null
        private var acknowledgement: MethodChannel.Result? = null
        private var channel: MethodChannel? = null

        fun attach(activity: MainActivity, bridge: MethodChannel) {
            channel = bridge
            bridge.setMethodCallHandler { call, result ->
                val id = (call.arguments as? Number)?.toLong()
                if (id == null) {
                    result.error("invalid_session", "Missing Live session", null)
                } else when (call.method) {
                    "start" -> {
                        val allowed = activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                            PackageManager.PERMISSION_GRANTED && notificationsAllowed(activity)
                        if (!allowed) {
                            result.success(false)
                        } else {
                            acknowledgement?.success(false)
                            acknowledgement = result
                            session = id
                            val intent = Intent(activity, LiveMicrophoneService::class.java)
                                .setAction(START).putExtra(EXTRA_SESSION, id)
                            try {
                                if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent)
                                else activity.startService(intent)
                            } catch (_: RuntimeException) {
                                finishStart(false)
                                session = null
                            }
                        }
                    }
                    "stop" -> {
                        if (session == id) stop(activity)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        private fun notificationsAllowed(activity: MainActivity): Boolean {
            val manager = activity.getSystemService(NotificationManager::class.java)
            return manager.areNotificationsEnabled() &&
                (Build.VERSION.SDK_INT < 26 ||
                    manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
        }

        private fun finishStart(ok: Boolean) {
            acknowledgement?.success(ok)
            acknowledgement = null
        }

        fun stop(activity: MainActivity) {
            session = null
            finishStart(false)
            activity.stopService(Intent(activity, LiveMicrophoneService::class.java))
        }

        fun detach(activity: MainActivity, bridge: MethodChannel) {
            if (channel !== bridge) return
            bridge.setMethodCallHandler(null)
            channel = null
            stop(activity)
        }

        fun handleReturn(intent: Intent): Boolean {
            if (intent.action != RETURN) return false
            val id = intent.getLongExtra(EXTRA_SESSION, -1)
            if (session == id) channel?.invokeMethod("return", id)
            return true
        }
    }

    private var foregroundSession: Long? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getLongExtra(EXTRA_SESSION, -1) ?: -1
        if (session != id) {
            if (session == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        when (intent?.action) {
            START -> {
                try {
                    val notification = notification(id)
                    if (Build.VERSION.SDK_INT >= 30) {
                        startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                    } else {
                        startForeground(NOTIFICATION, notification)
                    }
                    foregroundSession = id
                    finishStart(true)
                } catch (_: RuntimeException) {
                    finishStart(false)
                    session = null
                    stopSelf()
                }
            }
            MUTE -> channel?.invokeMethod("mute", id)
            END -> {
                channel?.invokeMethod("end", id)
                session = null
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val id = foregroundSession
        if (id != null && session == id) {
            channel?.invokeMethod("end", id)
            session = null
        }
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        val id = foregroundSession
        if (id != null && session == id) {
            session = null
            channel?.invokeMethod("unavailable", id)
        }
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun notification(id: Long): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Live voice", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val returnIntent = Intent(this, MainActivity::class.java)
            .setAction(RETURN).setData(Uri.parse("hermes-live:$id")).putExtra(EXTRA_SESSION, id)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        fun action(which: String, request: Int): PendingIntent = PendingIntent.getService(
            this, request, Intent(this, LiveMicrophoneService::class.java)
                .setAction(which).setData(Uri.parse("hermes-live:$id")).putExtra(EXTRA_SESSION, id), flags,
        )
        val open = PendingIntent.getActivity(this, 7805, returnIntent, flags)
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this)
        }
        return builder.setSmallIcon(R.drawable.ic_stat_mobile_push)
            .setContentTitle("Live voice")
            .setContentText("Microphone call in progress")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Return", open).build())
            .addAction(Notification.Action.Builder(null, "Mute / unmute", action(MUTE, 7806)).build())
            .addAction(Notification.Action.Builder(null, "End", action(END, 7807)).build())
            .build()
    }
}
