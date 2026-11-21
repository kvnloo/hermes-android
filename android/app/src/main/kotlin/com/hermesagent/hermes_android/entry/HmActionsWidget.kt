package com.hermesagent.hermes_android.entry

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import com.hermesagent.hermes_android.AndroidEntry
import com.hermesagent.hermes_android.R

class HmActionsWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = RemoteViews(context.packageName, R.layout.hm_actions_widget)
        views.setOnClickPendingIntent(
            R.id.entry_new_chat, AndroidEntry.pendingIntent(context, AndroidEntry.NEW_CHAT)
        )
        views.setOnClickPendingIntent(
            R.id.entry_live_voice, AndroidEntry.pendingIntent(context, AndroidEntry.LIVE_VOICE)
        )
        for (id in ids) manager.updateAppWidget(id, views)
    }
}
