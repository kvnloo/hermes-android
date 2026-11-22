package com.hermesagent.hermes_android

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import java.util.UUID

internal fun appFunctionDraft(text: String): String? =
    text.trim().takeIf { it.isNotEmpty() && it.length <= 4000 }

internal object AppFunctionHandoff {
    fun draft(context: Context, text: String) =
        AndroidEntry.intent(context, Intent.ACTION_SEND)
            .setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)

    fun pending(context: Context, intent: Intent): PendingIntent {
        // Extras are not part of PendingIntent identity. A unique URI keeps
        // concurrent drafts from overwriting/misrouting each other's text.
        intent.setDataAndType(Uri.fromParts("hermes-function", UUID.randomUUID().toString(), null), intent.type)
        return PendingIntent.getActivity(context, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
    }
}
