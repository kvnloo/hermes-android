package com.hermesagent.hermes_android

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.health.connect.AggregateRecordsRequest
import android.health.connect.AggregateRecordsResponse
import android.health.connect.HealthConnectException
import android.health.connect.HealthConnectManager
import android.health.connect.TimeInstantRangeFilter
import android.health.connect.datatypes.StepsRecord
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.OutcomeReceiver
import android.provider.CalendarContract.Instances
import android.provider.ContactsContract
import android.provider.Settings
import android.widget.TextView
import androidx.annotation.RequiresApi
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal enum class DeviceSource(val label: String, val permission: String? = null) {
    HEALTH("Health Connect steps", "android.permission.health.READ_STEPS"),
    CALENDAR("Calendar", Manifest.permission.READ_CALENDAR),
    CONTACTS("Contacts", Manifest.permission.READ_CONTACTS),
    LOCATION("Approximate location", Manifest.permission.ACCESS_COARSE_LOCATION),
    ALARM("Exact alarms"),
}

internal class DeviceAccess(private val context: Context) {
    private val prefs = context.getSharedPreferences("device_access", Context.MODE_PRIVATE)
    fun enabled(source: DeviceSource) = prefs.getBoolean(source.name, false)
    fun setEnabled(source: DeviceSource, value: Boolean) {
        prefs.edit().putBoolean(source.name, value).apply()
        if (source == DeviceSource.ALARM && !value) {
            context.getSystemService(AlarmManager::class.java)?.cancel(alarmIntent(context))
        }
    }

    fun available(source: DeviceSource): Boolean = when (source) {
        DeviceSource.HEALTH -> Build.VERSION.SDK_INT >= 34 && PlatformHealth.available(context)
        DeviceSource.LOCATION -> context.getSystemService(LocationManager::class.java) != null
        DeviceSource.ALARM -> context.getSystemService(AlarmManager::class.java) != null
        else -> true
    }

    suspend fun granted(source: DeviceSource): Boolean = when (source) {
        DeviceSource.ALARM -> {
            val alarms = context.getSystemService(AlarmManager::class.java)
            val notifications = context.getSystemService(NotificationManager::class.java)
            alarms != null && (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) &&
                notifications?.areNotificationsEnabled() == true
        }
        else -> context.checkSelfPermission(requireNotNull(source.permission)) == PackageManager.PERMISSION_GRANTED
    }

    // Local dispatch only. A future gateway adapter must get per-call approval
    // in the unlocked foreground chat before calling this code.
    suspend fun execute(tool: String, args: Map<String, Any?>): Map<String, Any?> = withContext(Dispatchers.IO) {
        val source = when (tool) {
            "device.health.steps" -> DeviceSource.HEALTH
            "device.calendar.events" -> DeviceSource.CALENDAR
            "device.contacts.find" -> DeviceSource.CONTACTS
            "device.location.approximate" -> DeviceSource.LOCATION
            "device.alarm.set" -> DeviceSource.ALARM
            else -> return@withContext error("invalid_arguments")
        }
        if (!enabled(source)) return@withContext error("disabled")
        try {
            if (!available(source)) return@withContext error("unavailable")
            if (!granted(source)) return@withContext error("permission_denied")
            val now = System.currentTimeMillis()
            val data: Map<String, Any?> = when (source) {
                DeviceSource.HEALTH -> {
                    require(args.isEmpty())
                    if (Build.VERSION.SDK_INT < 34) return@withContext error("unavailable")
                    mapOf("steps" to PlatformHealth.steps(context, Instant.ofEpochMilli(now)))
                }
                DeviceSource.CALENDAR -> {
                    val start = epoch(args["startMs"])
                    val end = epoch(args["endMs"])
                    require(args.keys == setOf("startMs", "endMs") &&
                        start in (now - WEEK)..(now + 4 * WEEK) && end > start && end - start <= WEEK)
                    val uri = Instances.CONTENT_URI.buildUpon()
                        .appendPath(start.toString()).appendPath(end.toString()).build()
                    val events = mutableListOf<Map<String, Any?>>()
                    context.contentResolver.query(uri, arrayOf(Instances.TITLE, Instances.BEGIN, Instances.END),
                        null, null, "${Instances.BEGIN} ASC")?.use { cursor ->
                        while (events.size < 25 && cursor.moveToNext()) {
                            events += mapOf("title" to cursor.getString(0)?.take(200),
                                "startMs" to cursor.getLong(1), "endMs" to cursor.getLong(2))
                        }
                    } ?: return@withContext error("unavailable")
                    mapOf("events" to events)
                }
                DeviceSource.CONTACTS -> {
                    val name = args["name"] as? String ?: throw IllegalArgumentException()
                    require(args.keys == setOf("name") && name.trim().length in 2..80)
                    val uri = ContactsContract.Contacts.CONTENT_FILTER_URI.buildUpon().appendPath(name.trim()).build()
                    val names = mutableListOf<String>()
                    context.contentResolver.query(uri, arrayOf(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY),
                        null, null, null)?.use { cursor ->
                        while (names.size < 10 && cursor.moveToNext()) {
                            cursor.getString(0)?.take(120)?.let(names::add)
                        }
                    } ?: return@withContext error("unavailable")
                    mapOf("names" to names)
                }
                DeviceSource.LOCATION -> {
                    require(args.isEmpty())
                    val manager = context.getSystemService(LocationManager::class.java)
                    val fix = manager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                        ?.takeIf { now - it.time in 0..300_000 }
                        ?: return@withContext error("unavailable")
                    mapOf("latitude" to roundedCoordinate(fix.latitude),
                        "longitude" to roundedCoordinate(fix.longitude), "timeMs" to fix.time)
                }
                DeviceSource.ALARM -> {
                    val at = epoch(args["atMs"])
                    require(args.keys == setOf("atMs") && at in (now + 10_000)..(now + WEEK))
                    context.getSystemService(AlarmManager::class.java).setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP, at, alarmIntent(context))
                    mapOf("atMs" to at)
                }
            }
            mapOf("ok" to true, "data" to data)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: SecurityException) {
            error("permission_denied")
        } catch (_: IllegalArgumentException) {
            error("invalid_arguments")
        } catch (_: Exception) {
            error("unavailable")
        }
    }

    companion object {
        private const val WEEK = 604_800_000L
        internal fun error(code: String) = mapOf("ok" to false, "error" to mapOf("code" to code))
        internal fun roundedCoordinate(value: Double) = Math.round(value * 100) / 100.0
        private fun epoch(value: Any?): Long = when (value) {
            is Int -> value.toLong()
            is Long -> value
            else -> throw IllegalArgumentException()
        }
        private fun alarmIntent(context: Context) = PendingIntent.getBroadcast(
            context, 0, Intent(context, DeviceAlarmReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
    }
}

// Keep platform Health Connect types out of paths used on API 24–33.
@RequiresApi(34)
private object PlatformHealth {
    fun available(context: Context) = context.getSystemService(HealthConnectManager::class.java) != null

    suspend fun steps(context: Context, end: Instant): Long? = suspendCancellableCoroutine { continuation ->
        val manager = requireNotNull(context.getSystemService(HealthConnectManager::class.java))
        val period = TimeInstantRangeFilter.Builder()
            .setStartTime(end.minusSeconds(86400))
            .setEndTime(end)
            .build()
        val metric = StepsRecord.STEPS_COUNT_TOTAL
        manager.aggregate(AggregateRecordsRequest.Builder<Long>(period).addAggregationType(metric).build(),
            context.mainExecutor, object : OutcomeReceiver<AggregateRecordsResponse<Long>, HealthConnectException> {
                override fun onResult(result: AggregateRecordsResponse<Long>) {
                    continuation.resume(result.get(metric))
                }

                override fun onError(error: HealthConnectException) {
                    continuation.resumeWithException(
                        if (error.errorCode == HealthConnectException.ERROR_SECURITY) SecurityException(error)
                        else error
                    )
                }
            })
    }
}

class DeviceAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!DeviceAccess(context).enabled(DeviceSource.ALARM)) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return
        val channel = "device_alarm"
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(channel, "Device alarm", NotificationManager.IMPORTANCE_HIGH))
            Notification.Builder(context, channel)
        } else Notification.Builder(context)
        manager.notify(8421, builder.setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Hermes device alarm").setAutoCancel(true).build())
    }
}

/**
 * Backend of Settings → Device access. The page itself is Flutter
 * (HmDeviceAccessScreen) so it follows the app theme and has the shared top
 * bar with back; this class keeps the native state, toggle and permission
 * logic and serves it over [CHANNEL].
 */
internal class DeviceAccessSettings(
    private val activity: Activity,
    private val launchPermission: (permission: String, done: () -> Unit) -> Unit,
) {
    private val access = DeviceAccess(activity)
    // The former DeviceAccessActivity kept "already asked" in getPreferences(),
    // whose file is named after that activity. Reuse it so returning users keep it.
    private val asked = activity.getSharedPreferences("DeviceAccessActivity", Context.MODE_PRIVATE)

    suspend fun state(source: DeviceSource): String =
        if (!access.enabled(source)) "Off"
        else try {
            if (!access.available(source)) "Unavailable on this device"
            else if (access.granted(source)) "Permission granted"
            else "Permission denied or not yet granted"
        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (_: Exception) { "Unavailable on this device" }

    /** One entry per source, in [DeviceSource] order. */
    suspend fun states(): List<Map<String, Any>> = DeviceSource.entries.map { source ->
        val state = state(source)
        val enabled = access.enabled(source)
        val available = runCatching { access.available(source) }.getOrDefault(false)
        mapOf(
            "source" to source.name,
            "label" to source.label,
            "enabled" to enabled,
            "state" to state,
            "canRequest" to (enabled && available && state != "Permission granted"),
        )
    }

    fun setEnabled(source: DeviceSource, value: Boolean) = access.setEnabled(source, value)

    /** Opens the permission prompt or settings page; [done] runs once it is up or answered. */
    fun request(source: DeviceSource, done: (Boolean) -> Unit) {
        val packageUri = Uri.parse("package:${activity.packageName}")
        try {
            when (source) {
                DeviceSource.ALARM -> {
                    val alarms = activity.getSystemService(AlarmManager::class.java)
                    if (Build.VERSION.SDK_INT >= 31 && !alarms.canScheduleExactAlarms()) {
                        activity.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, packageUri))
                    } else if (Build.VERSION.SDK_INT >= 33 &&
                        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        launchPermission(Manifest.permission.POST_NOTIFICATIONS) { done(true) }
                        return
                    } else {
                        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
                    }
                }
                else -> {
                    val permission = requireNotNull(source.permission)
                    if (asked.getBoolean(permission, false) && !activity.shouldShowRequestPermissionRationale(permission)) {
                        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
                    } else {
                        asked.edit().putBoolean(permission, true).apply()
                        launchPermission(permission) { done(true) }
                        return
                    }
                }
            }
            done(true)
        } catch (_: RuntimeException) {
            done(false)
        }
    }

    companion object {
        const val CHANNEL = "com.hermesagent.hermes_android/device_access"
    }
}

/** Serves [DeviceAccessSettings] to Flutter: states, setEnabled, requestSource. */
internal class DeviceAccessChannel(
    messenger: io.flutter.plugin.common.BinaryMessenger,
    private val settings: DeviceAccessSettings,
) {
    private val scope = kotlinx.coroutines.MainScope()
    private val channel = io.flutter.plugin.common.MethodChannel(messenger, DeviceAccessSettings.CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            val source = call.argument<String>("source")?.let { name ->
                DeviceSource.entries.firstOrNull { it.name == name }
            }
            when (call.method) {
                "states" -> scope.launch {
                    try { result.success(settings.states()) }
                    catch (e: kotlinx.coroutines.CancellationException) { throw e }
                    catch (e: Exception) { result.error("unavailable", e.message, null) }
                }
                "setEnabled" -> {
                    val value = call.argument<Boolean>("enabled")
                    if (source == null || value == null) result.error("bad_args", null, null)
                    else { settings.setEnabled(source, value); result.success(null) }
                }
                "requestSource" -> {
                    if (source == null) result.error("bad_args", null, null)
                    else settings.request(source) { ok -> result.success(ok) }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun close() { channel.setMethodCallHandler(null); scope.cancel() }
}

class HealthPermissionRationaleActivity : android.app.Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        actionBar?.hide()
        setContentView(TextView(this).apply {
            setPadding(32, 32, 32, 32)
            padForSystemBars(this)
            text = "Hermes requests read-only access to the last 24 hours of step totals. " +
                "Device access defaults off. This build does not send health data to a host. " +
                "You can turn it off in Hermes settings or revoke it in Health Connect."
        })
    }
}

/** Adds the system-bar and cutout insets to [view]'s own padding (edge-to-edge). */
private fun padForSystemBars(view: android.view.View) {
    val base = intArrayOf(view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom)
    ViewCompat.setOnApplyWindowInsetsListener(view) { v, insets ->
        val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
        v.setPadding(base[0] + bars.left, base[1] + bars.top, base[2] + bars.right, base[3] + bars.bottom)
        insets
    }
}
