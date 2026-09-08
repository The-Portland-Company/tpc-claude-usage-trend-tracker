package com.theportlandcompany.claudemeter

import android.app.Application
import com.theportlandcompany.claudemeter.data.RefreshWorker
import com.theportlandcompany.claudemeter.notif.NotificationHelper

class ClaudeMeterApp : Application() {
    override fun onCreate() {
        super.onCreate()
        NotificationHelper.ensureChannels(this)
        RefreshWorker.schedule(this)
    }
}
