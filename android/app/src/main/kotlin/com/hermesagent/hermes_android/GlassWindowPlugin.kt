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

/** The window and Flutter render surface pick their modes at activity creation. */
class GlassWindowPlugin(private val activity: Activity) {
    val glass: Boolean = activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        .all.let { it["flutter.nextgen_enabled"] != false && it["flutter.nextgen_surface"] == "glass" }
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
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.hermesagent.hermes_android/glass").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "state" -> result.success(state())
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
        if (glass && Build.VERSION.SDK_INT >= 31) ensureListener()
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
        if (!glass || Build.VERSION.SDK_INT < 31) return
        applyBlur31()
    }

    @TargetApi(31)
    private fun applyBlur31() {
        val enabled = activity.windowManager.isCrossWindowBlurEnabled
        val px = if (enabled) (32 * activity.resources.displayMetrics.density).roundToInt() else 0
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
        if (Build.VERSION.SDK_INT >= 31) removeListener31(l)
        listener = null
    }

    @TargetApi(31)
    private fun removeListener31(l: Consumer<Boolean>) {
        runCatching { activity.windowManager.removeCrossWindowBlurEnabledListener(l) }
    }

    private fun crossWindowBlurEnabled(): Boolean =
        Build.VERSION.SDK_INT >= 31 && enabled31()

    @TargetApi(31)
    private fun enabled31(): Boolean = activity.windowManager.isCrossWindowBlurEnabled

    private fun state(): Map<String, Any?> {
        val attributes = activity.window.attributes
        return mapOf(
            "transparent" to (glass && attributes.format == PixelFormat.TRANSLUCENT),
            "showsWallpaper" to ((attributes.flags and WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER) != 0),
            "crossWindowBlurEnabled" to crossWindowBlurEnabled(),
        )
    }
}
