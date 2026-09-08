package com.theportlandcompany.claudemeter.data

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.theportlandcompany.claudemeter.notif.NotificationHelper
import java.util.concurrent.TimeUnit

/** Periodic background refresh (WorkManager min granularity ~15 min — coarser
 * than the desktop's 5-min poll; documented platform limitation per the
 * parity manifest §4 Android notes). */
class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val prefs = AppPrefs(applicationContext)
        val secure = SecureStore(applicationContext)
        val accountId = prefs.getActiveAccountId() ?: return Result.success()
        val tokens = secure.loadTokens(accountId) ?: return Result.success()
        val result = UsageApi.fetchUsage(tokens.accessToken)
        if (result is UsageResult.Success) {
            val featured = prefs.getFeaturedBucketIds()
            val shown = result.snapshot.buckets.filter { featured.contains(it.kind) || featured.contains(it.id) }
            NotificationHelper.showStatus(applicationContext, shown)
            prefs.appendHistory(
                accountId,
                result.snapshot.buckets.map { HistorySample(result.snapshot.fetchedAtEpochSeconds, it.id, it.percent) },
                result.snapshot.fetchedAtEpochSeconds,
            )
        }
        return Result.success()
    }

    companion object {
        private const val WORK_NAME = "claude_meter_refresh"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<RefreshWorker>(15, TimeUnit.MINUTES).build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
