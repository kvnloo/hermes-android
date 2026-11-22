package com.hermesagent.hermes_android

import android.Manifest
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
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
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

class DeviceAccessActivity : ComponentActivity() {
    private lateinit var access: DeviceAccess
    private lateinit var list: LinearLayout
    private var refreshJob: kotlinx.coroutines.Job? = null
    private val scope = kotlinx.coroutines.MainScope()
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestPermission()) { refresh() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        access = DeviceAccess(this)
        list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val padding = (20 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
        }
        setContentView(ScrollView(this).apply { addView(list) })
    }

    override fun onResume() { super.onResume(); refresh() }

    private fun refresh() {
        refreshJob?.cancel()
        refreshJob = scope.launch {
            val states = DeviceSource.entries.associateWith { source ->
                if (!access.enabled(source)) "Off"
                else try {
                    if (!access.available(source)) "Unavailable on this device"
                    else if (access.granted(source)) "Permission granted"
                    else "Permission denied or not yet granted"
                } catch (e: kotlinx.coroutines.CancellationException) { throw e }
                catch (_: Exception) { "Unavailable on this device" }
            }
            list.removeAllViews()
            list.addView(TextView(this@DeviceAccessActivity).apply {
                text = "Device access\nSources are off by default. This build does not send device data to a host."
                textSize = 18f
            })
            for ((source, state) in states) {
                list.addView(Switch(this@DeviceAccessActivity).apply {
                    text = "${source.label} · $state"
                    isChecked = access.enabled(source)
                    setOnCheckedChangeListener { _, checked -> access.setEnabled(source, checked); refresh() }
                })
                if (access.enabled(source) && access.available(source) && state != "Permission granted") {
                    list.addView(Button(this@DeviceAccessActivity).apply {
                        text = "Grant or manage ${source.label} permission"
                        setOnClickListener { requestSource(source) }
                    })
                }
            }
        }
    }

    private fun requestSource(source: DeviceSource) {
        val packageUri = Uri.parse("package:$packageName")
        try {
            when (source) {
                DeviceSource.ALARM -> {
                    val alarms = getSystemService(AlarmManager::class.java)
                    if (Build.VERSION.SDK_INT >= 31 && !alarms.canScheduleExactAlarms()) {
                        startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, packageUri))
                    } else if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        permissions.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
                    }
                }
                else -> {
                    val permission = requireNotNull(source.permission)
                    val asked = getPreferences(MODE_PRIVATE)
                    if (asked.getBoolean(permission, false) && !shouldShowRequestPermissionRationale(permission)) {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
                    } else {
                        asked.edit().putBoolean(permission, true).apply()
                        permissions.launch(permission)
                    }
                }
            }
        } catch (_: RuntimeException) {
            android.widget.Toast.makeText(this, "Permission settings are unavailable.", android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    override fun onDestroy() { scope.cancel(); super.onDestroy() }
}

class HealthPermissionRationaleActivity : android.app.Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(TextView(this).apply {
            setPadding(32, 32, 32, 32)
            text = "Hermes requests read-only access to the last 24 hours of step totals. " +
                "Device access defaults off. This build does not send health data to a host. " +
                "You can turn it off in Hermes settings or revoke it in Health Connect."
        })
    }
}
