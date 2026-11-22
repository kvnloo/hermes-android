package com.hermesagent.hermes_android

import android.app.PendingIntent
import androidx.annotation.RequiresApi
import androidx.appfunctions.AppFunctionDeclaration
import androidx.appfunctions.AppFunctionInvalidArgumentException
import androidx.appfunctions.AppFunctionService
import androidx.appfunctions.AppFunctionServiceEntryPoint

@RequiresApi(36)
@AppFunctionServiceEntryPoint(
    serviceName = "HermesAppFunctionService",
    appFunctionXmlFileName = "hermes_app_functions",
)
abstract class HermesAppFunctions : AppFunctionService() {
    /**
     * Prepare a Hermes chat draft for the user to review, edit and send.
     * No bot is contacted until the user taps Send in the app.
     *
     * @param prompt The user's question, 1–4000 characters.
     * @return A one-time action to open the draft in Hermes.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true)
    suspend fun askHermes(prompt: String): PendingIntent {
        val draft = appFunctionDraft(prompt)
            ?: throw AppFunctionInvalidArgumentException("A question of 1–4000 characters is required.")
        return AppFunctionHandoff.pending(this, AppFunctionHandoff.draft(this, draft))
    }

    /**
     * Open the routines list for the current Hermes host. The user selects
     * the routine and taps Run now in the app; this function executes nothing.
     *
     * @return A one-time action to open the routines list.
     */
    @AppFunctionDeclaration(isDescribedByKDoc = true)
    suspend fun runHermesRoutine(): PendingIntent =
        AppFunctionHandoff.pending(this, AndroidEntry.intent(this, AndroidEntry.ROUTINES))
}
