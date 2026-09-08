package com.theportlandcompany.claudemeter.notif

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import com.theportlandcompany.claudemeter.MainActivity
import com.theportlandcompany.claudemeter.R
import com.theportlandcompany.claudemeter.data.UsageBucket

const val CHANNEL_ID_STATUS = "claude_meter_status"
const val CHANNEL_ID_ALERTS = "claude_meter_alerts"
private const val STATUS_NOTIFICATION_ID = 1001

object NotificationHelper {

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID_STATUS, "Usage status", NotificationManager.IMPORTANCE_LOW),
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID_ALERTS, "Usage alerts", NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    /** Persistent, low-priority ongoing notification showing the chosen bucket(s). */
    fun buildStatusNotification(context: Context, buckets: List<UsageBucket>): android.app.Notification {
        val summary = if (buckets.isEmpty()) "No buckets selected" else buckets.joinToString("  ·  ") {
            "${it.title}: ${it.percent.toInt()}%"
        }
        val intent = android.content.Intent(context, MainActivity::class.java)
        val pendingIntent = androidx.core.app.TaskStackBuilder.create(context)
            .addNextIntentWithParentStack(intent)
            .getPendingIntent(0, android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE)

        return NotificationCompat.Builder(context, CHANNEL_ID_STATUS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Claude usage")
            .setContentText(summary)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .build()
    }

    fun showStatus(context: Context, buckets: List<UsageBucket>) {
        ensureChannels(context)
        val nm = androidx.core.app.NotificationManagerCompat.from(context)
        if (androidx.core.content.ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return
        nm.notify(STATUS_NOTIFICATION_ID, buildStatusNotification(context, buckets))
    }
}
