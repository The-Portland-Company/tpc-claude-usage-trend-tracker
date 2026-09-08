package com.theportlandcompany.claudemeter.data

data class Account(
    val id: String,
    val label: String, // email if known, else id
    val isPrimaryReadOnly: Boolean = false,
)

data class ModelScope(val displayName: String)

data class UsageBucket(
    val kind: String,
    val group: String?,
    val percent: Double,
    val resetsAtEpochSeconds: Double?,
    val scopeModelDisplayName: String?,
    val isActive: Boolean?,
) {
    /** Stable identity for history/notifications. */
    val id: String
        get() = if (kind == "weekly_scoped" && scopeModelDisplayName != null) "$kind|$scopeModelDisplayName" else kind

    val title: String
        get() = when (kind) {
            "session", "five_hour" -> "5-hour session"
            "weekly_all" -> "Week · all models"
            "weekly_scoped" -> "Week · ${scopeModelDisplayName ?: "?"}"
            else -> kind.replace('_', ' ').replaceFirstChar { it.uppercase() }
        }
}

data class ExtraUsage(
    val isEnabled: Boolean,
    val usedCredits: Long, // cents
    val monthlyLimit: Long, // cents
    val utilization: Double,
)

data class UsageSnapshot(
    val buckets: List<UsageBucket>,
    val extraUsage: ExtraUsage?,
    val fetchedAtEpochSeconds: Double,
)

data class HistorySample(val timestampEpochSeconds: Double, val bucketId: String, val percent: Double)
