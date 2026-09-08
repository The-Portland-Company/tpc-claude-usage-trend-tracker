package com.theportlandcompany.claudemeter.auth

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Catches `claudetracker://oauth-callback?code=...&state=...` redirects from
 * the Chrome Custom Tab, hands the values to [OAuthSession], then returns to
 * the app's task (MainActivity resumes via the launcher's existing instance). */
class OAuthCallbackActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
        finish()
    }

    private fun handleIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        val code = uri.getQueryParameter("code")
        val state = uri.getQueryParameter("state")
        if (code != null && state != null) {
            OAuthSession.deliver(code, state)
        }
    }
}
