package com.hermesagent.hermes_android

import android.annotation.TargetApi
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.function.Consumer
import kotlin.math.roundToInt

/**
 * Glass surfaces: lets the Android wallpaper (live wallpapers included) show through the
 * Flutter window and asks the compositor to blur it.
 *
 * The window mode (opaque vs transparent) is decided once, when the activity is created,
 * because Flutter picks its render surface from it. Dart persists `theme_surface` and asks
 * for [Activity.recreate]; everything else (blur radius) is applied live.
 *
 * Inert for the default Solid surface: the activity keeps Flutter's opaque SurfaceView and
 * this class never touches the window.
 */
object GlassWindow {
    const val CHANNEL = "com.hermesagent.hermes_android/glass"
    const val MIN_BLUR_SDK = 31

    /** Android clamps large radii internally; past ~120dp cost rises with no visible gain. */
    const val MAX_BLUR_DP = 120.0

    // Legacy shared_preferences plugin store; keys carry the plugin's "flutter." prefix.
    private const val PREFS = "FlutterSharedPreferences"
    private const val SURFACE_KEY = "flutter.theme_surface"
    private const val BLUR_KEY = "flutter.theme_glass_blur_dp"

    fun wantsGlass(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(SURFACE_KEY, null) == "glass"

    /** The persisted blur so the first frame already blurs (Dart re-sends it after start). */
    fun savedBlurDp(context: Context): Double {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // shared_preferences stores doubles as a prefixed string on Android.
        val raw = prefs.all[BLUR_KEY]
        return when (raw) {
            is String -> raw.removePrefix(DOUBLE_PREFIX).toDoubleOrNull()
            is Number -> raw.toDouble()
            else -> null
        } ?: 28.0
    }

    private const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"

    fun pxFor(dp: Double, density: Float): Int =
        (dp.coerceIn(0.0, MAX_BLUR_DP) * density).roundToInt()
}

class GlassWindowPlugin private constructor(
    private val activity: Activity,
    private val glass: Boolean,
) {
    private var blurDp = if (glass) GlassWindow.savedBlurDp(activity) else 0.0
    private var listener: Consumer<Boolean>? = null
    private var channel: MethodChannel? = null

    /** Call from onCreate, before Flutter attaches, so the first frame shows the wallpaper. */
    fun configureWindow() {
        if (!glass) return
        val window = activity.window
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.setFormat(PixelFormat.TRANSLUCENT)
        window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER)
        applyBlur()
    }

    fun attach(engine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, GlassWindow.CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "state" -> result.success(state())
                    "setBlur" -> {
                        blurDp = (call.argument<Number>("dp") ?: 0).toDouble()
                        applyBlur()
                        result.success(state())
                    }
                    // Window mode follows the saved preference on the next create.
                    // A fresh launch rather than recreate(): live wallpapers only
                    // start drawing for a new wallpaper target on a real launch.
                    "recreate" -> {
                        result.success(true)
                        activity.window.decorView.post { relaunch() }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        if (glass && Build.VERSION.SDK_INT >= GlassWindow.MIN_BLUR_SDK) ensureListener()
    }

    private fun relaunch() {
        val intent = Intent(activity, activity.javaClass)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        activity.startActivity(intent)
        activity.finish()
        @Suppress("DEPRECATION")
        activity.overridePendingTransition(0, 0)
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        removeListener()
    }

    private fun applyBlur() {
        if (!glass || Build.VERSION.SDK_INT < GlassWindow.MIN_BLUR_SDK) return
        applyBlur31()
    }

    @TargetApi(31)
    private fun applyBlur31() {
        val enabled = activity.windowManager.isCrossWindowBlurEnabled
        val px = if (enabled) GlassWindow.pxFor(blurDp, activity.resources.displayMetrics.density) else 0
        // Blurs only what sits behind this window's transparent background: the wallpaper.
        activity.window.setBackgroundBlurRadius(px)
    }

    @TargetApi(31)
    private fun ensureListener() {
        if (listener != null) return
        val l = Consumer<Boolean> { enabled ->
            applyBlur()
            channel?.invokeMethod("blurChanged", mapOf("enabled" to enabled))
        }
        activity.windowManager.addCrossWindowBlurEnabledListener(activity.mainExecutor, l)
        listener = l
    }

    private fun removeListener() {
        val l = listener ?: return
        if (Build.VERSION.SDK_INT >= GlassWindow.MIN_BLUR_SDK) removeListener31(l)
        listener = null
    }

    @TargetApi(31)
    private fun removeListener31(l: Consumer<Boolean>) {
        runCatching { activity.windowManager.removeCrossWindowBlurEnabledListener(l) }
    }

    private fun crossWindowBlurEnabled(): Boolean =
        Build.VERSION.SDK_INT >= GlassWindow.MIN_BLUR_SDK && enabled31()

    @TargetApi(31)
    private fun enabled31(): Boolean = activity.windowManager.isCrossWindowBlurEnabled

    private fun state(): Map<String, Any?> {
        val flags = activity.window.attributes.flags
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "transparent" to glass,
            "showsWallpaper" to ((flags and WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER) != 0),
            "blurSupported" to (Build.VERSION.SDK_INT >= GlassWindow.MIN_BLUR_SDK),
            "crossWindowBlurEnabled" to crossWindowBlurEnabled(),
            "blurDp" to blurDp,
        )
    }

    companion object {
        fun create(activity: Activity): GlassWindowPlugin =
            GlassWindowPlugin(activity, GlassWindow.wantsGlass(activity))
    }
}
