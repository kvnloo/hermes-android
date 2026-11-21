package com.hermesagent.hermes_android

import android.app.PendingIntent
import android.content.Context
import android.content.Intent

internal object AndroidEntry {
    private const val PREFIX = "com.hermesagent.hermes_android.action."
    const val NEW_CHAT = PREFIX + "QUICK_CHAT"
    const val LIVE_VOICE = PREFIX + "LIVE_VOICE"
    const val SESSIONS = PREFIX + "SESSIONS"
    const val ROUTINES = PREFIX + "ROUTINES"
    val actions = setOf(NEW_CHAT, LIVE_VOICE, SESSIONS, ROUTINES)

    fun intent(context: Context, action: String) =
        Intent(context, MainActivity::class.java).setAction(action)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    fun pendingIntent(context: Context, action: String) =
        PendingIntent.getActivity(
            context, 0, intent(context, action), PendingIntent.FLAG_IMMUTABLE
        )
}
