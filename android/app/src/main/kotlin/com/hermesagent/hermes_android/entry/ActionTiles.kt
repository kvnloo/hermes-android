package com.hermesagent.hermes_android.entry

import android.os.Build
import android.service.quicksettings.TileService
import com.hermesagent.hermes_android.AndroidEntry

abstract class ActionTileService(private val action: String) : TileService() {
    @Suppress("DEPRECATION")
    override fun onClick() {
        super.onClick()
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(AndroidEntry.pendingIntent(this, action))
        } else {
            startActivityAndCollapse(AndroidEntry.intent(this, action))
        }
    }
}

class NewChatTileService : ActionTileService(AndroidEntry.NEW_CHAT)
class LiveVoiceTileService : ActionTileService(AndroidEntry.LIVE_VOICE)
