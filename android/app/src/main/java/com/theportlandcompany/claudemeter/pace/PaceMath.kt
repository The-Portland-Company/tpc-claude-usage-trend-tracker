package com.theportlandcompany.claudemeter.pace

import kotlin.math.max
import kotlin.math.min

/**
 * Pure functions that turn a usage bucket into "where is this heading".
 * Ported bit-for-bit from Sources/PaceMath.swift — keep in sync with it.
 */
object PaceMath {

    /** Length of a bucket's window, in seconds, derived from its `kind`. Anthropic
     * does not send the window length, only `resets_at`. */
    fun windowLengthSeconds(kind: String): Double? {
        if (kind == "session" || kind == "five_hour") return 5 * 3600.0
        if (kind.startsWith("weekly") || kind.startsWith("seven_day")) return 7 * 24 * 3600.0
        return null
    }

    data class Projection(
        val elapsedFraction: Double,
        val projectedAtReset: Double,
        val hits100AtEpochSeconds: Double?,
        val ratePerHour: Double,
        val sustainableRatePerHour: Double,
    ) {
        val overPace: Boolean get() = projectedAtReset > 100
    }

    /** Straight-line projection from window start to reset. Returns null when the
     * kind has no known window length or resetsAt is missing. All times are epoch
     * seconds (UTC). */
    fun project(percent: Double, kind: String, resetsAtEpochSeconds: Double?, nowEpochSeconds: Double): Projection? {
        val length = windowLengthSeconds(kind) ?: return null
        val resetsAt = resetsAtEpochSeconds ?: return null
        val start = resetsAt - length
        val elapsed = nowEpochSeconds - start
        // Clamp: right after a reset the fraction is ~0 and a tiny percent would project to infinity.
        val fraction = min(max(elapsed / length, 0.02), 1.0)
        val projected = percent / fraction
        val hours = length / 3600
        val rate = percent / (fraction * hours)
        val sustainable = 100 / hours
        var hits100: Double? = null
        if (percent > 0 && rate > 0 && projected > 100) {
            val hoursTo100 = (100 - percent) / rate
            hits100 = nowEpochSeconds + hoursTo100 * 3600
        }
        return Projection(
            elapsedFraction = fraction,
            projectedAtReset = projected,
            hits100AtEpochSeconds = hits100,
            ratePerHour = rate,
            sustainableRatePerHour = sustainable,
        )
    }

    enum class Trend(val glyph: String) {
        RISING("↗"), STEADY("→"), FALLING("↘"), UNKNOWN("·")
    }

    /** Compare the slope over the recent samples with the sustainable slope.
     * `samples` are (epochSeconds, percent) for one bucket, any order. */
    fun trend(
        samples: List<Pair<Double, Double>>,
        kind: String,
        nowEpochSeconds: Double,
        lookbackSeconds: Double = 3600.0,
    ): Trend {
        val length = windowLengthSeconds(kind) ?: return Trend.UNKNOWN
        val recent = samples.filter { nowEpochSeconds - it.first <= lookbackSeconds }.sortedBy { it.first }
        val first = recent.firstOrNull() ?: return Trend.UNKNOWN
        val last = recent.lastOrNull() ?: return Trend.UNKNOWN
        if (last.first - first.first < 600) return Trend.UNKNOWN
        val hours = (last.first - first.first) / 3600
        val slope = (last.second - first.second) / hours // percent per hour, negative after a reset
        val sustainable = 100 / (length / 3600)
        return when {
            slope < 0 -> Trend.FALLING // a reset happened inside the window
            slope > sustainable * 1.25 -> Trend.RISING
            slope < sustainable * 0.75 -> Trend.FALLING
            else -> Trend.STEADY
        }
    }

    enum class Severity(val rank: Int) {
        NORMAL(0), WARNING(1), CRITICAL(2)
    }

    /** Local severity, independent of Anthropic's `severity` string, so the UI
     * can go amber before the server does. */
    fun severity(percent: Double, projection: Projection?): Severity {
        if (percent >= 90) return Severity.CRITICAL
        if (projection != null && projection.overPace && percent >= 50) return Severity.CRITICAL
        if (percent >= 75) return Severity.WARNING
        if (projection != null && projection.overPace) return Severity.WARNING
        return Severity.NORMAL
    }

    /** "in 2d 4h", "in 3h 12m", "in 40m", "now". */
    fun countdown(toEpochSeconds: Double, fromEpochSeconds: Double): String {
        val s = max(0, (toEpochSeconds - fromEpochSeconds).toInt())
        if (s == 0) return "now"
        val d = s / 86400
        val h = (s % 86400) / 3600
        val m = (s % 3600) / 60
        if (d > 0) return "in ${d}d ${h}h"
        if (h > 0) return "in ${h}h ${m}m"
        return "in ${m}m"
    }
}
