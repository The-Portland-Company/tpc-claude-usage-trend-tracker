package com.theportlandcompany.claudemeter.notif

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.theportlandcompany.claudemeter.data.RefreshWorker

/** Re-arms the periodic refresh worker after a reboot, per the parity manifest's
 * autostart requirement. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            RefreshWorker.schedule(context)
        }
    }
}
