package com.hermesagent.hermes_android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout

class HermesVoiceService : VoiceInteractionService()

class HermesSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?) = HermesAssistantSession(this)
}

private class HermesAssistantSession(context: Context) : VoiceInteractionSession(context) {
    override fun onCreateContentView(): View = assistantActions(context,
        open = { startAssistantActivity(Intent(context, AssistOverlayActivity::class.java)); finish() },
        dismiss = { finish() }
    )
}

private fun assistantActions(context: Context, open: () -> Unit, dismiss: () -> Unit) =
    LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(Button(context).apply {
            setText(R.string.assistant_open)
            setOnClickListener { open() }
        })
        addView(Button(context).apply {
            setText(android.R.string.cancel)
            setOnClickListener { dismiss() }
        })
    }

class AssistOverlayActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContentView(assistantActions(this, open = {
            // The standard app entry point retains the existing screen-lock gate.
            startActivity(AndroidEntry.intent(this, AndroidEntry.NEW_CHAT))
            finish()
        }, dismiss = ::finish))
    }
}

// Needed by the platform's voice-interaction metadata parser. System-wide
// transcription is not provided; chat dictation uses the app's own UI.
class HermesRecognitionService : android.speech.RecognitionService() {
    override fun onStartListening(intent: Intent?, callback: Callback) {
        callback.error(android.speech.SpeechRecognizer.ERROR_CLIENT)
    }
    override fun onStopListening(callback: Callback) = Unit
    override fun onCancel(callback: Callback) = Unit
}
