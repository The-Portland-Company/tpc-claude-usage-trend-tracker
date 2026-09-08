package com.theportlandcompany.claudemeter.ui

import com.theportlandcompany.claudemeter.data.HistorySample
import com.theportlandcompany.claudemeter.data.UsageBucket
import com.theportlandcompany.claudemeter.pace.PaceMath

/** View-model for one rendered bucket row, computed from the shared PaceMath. */
data class BucketRow(
    val bucket: UsageBucket,
    val severity: PaceMath.Severity,
    val trend: PaceMath.Trend,
    val resetCountdown: String?,
    val paceLine: String?,
)

fun buildBucketRow(bucket: UsageBucket, history: List<HistorySample>, nowEpochSeconds: Double): BucketRow {
    val projection = PaceMath.project(bucket.percent, bucket.kind, bucket.resetsAtEpochSeconds, nowEpochSeconds)
    val severity = PaceMath.severity(bucket.percent, projection)
    val samples = history.filter { it.bucketId == bucket.id }.map { it.timestampEpochSeconds to it.percent }
    val trend = PaceMath.trend(samples, bucket.kind, nowEpochSeconds)
    val countdown = bucket.resetsAtEpochSeconds?.let { PaceMath.countdown(it, nowEpochSeconds) }
    val paceLine = projection?.let {
        if (it.overPace) "Over pace" else "On pace"
    }
    return BucketRow(bucket, severity, trend, countdown, paceLine)
}

/** Top-of-screen headline, driven by the weekly_all bucket only, per the parity manifest. */
fun verdictLine(buckets: List<UsageBucket>, nowEpochSeconds: Double): String {
    val weeklyAll = buckets.firstOrNull { it.kind == "weekly_all" } ?: return "Waiting for usage data…"
    val projection = PaceMath.project(weeklyAll.percent, weeklyAll.kind, weeklyAll.resetsAtEpochSeconds, nowEpochSeconds)
    if (projection != null && projection.overPace && projection.hits100AtEpochSeconds != null) {
        val instant = java.time.Instant.ofEpochSecond(projection.hits100AtEpochSeconds.toLong())
        val zoned = instant.atZone(java.time.ZoneId.systemDefault())
        val formatter = java.time.format.DateTimeFormatter.ofPattern("EEEE, MMMM d 'at' h:mm a")
        return "You're going to run out by ${zoned.format(formatter)}."
    }
    return "You will not run out."
}
