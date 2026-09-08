package com.theportlandcompany.claudemeter.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject

/** Secure, OS-native storage for account tokens (EncryptedSharedPreferences /
 * Android Keystore-backed). Only token values live here; labels/metadata live
 * in ordinary SharedPreferences via [AppPrefs]. */
class SecureStore(context: Context) {

    private val prefs: SharedPreferences

    init {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        prefs = EncryptedSharedPreferences.create(
            context,
            "claude_meter_secure",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    data class StoredTokens(val accessToken: String, val refreshToken: String?)

    fun saveTokens(accountId: String, accessToken: String, refreshToken: String?) {
        prefs.edit()
            .putString("access_$accountId", accessToken)
            .putString("refresh_$accountId", refreshToken)
            .apply()
    }

    fun loadTokens(accountId: String): StoredTokens? {
        val access = prefs.getString("access_$accountId", null) ?: return null
        val refresh = prefs.getString("refresh_$accountId", null)
        return StoredTokens(access, refresh)
    }

    fun removeTokens(accountId: String) {
        prefs.edit().remove("access_$accountId").remove("refresh_$accountId").apply()
    }
}

/** Non-secret metadata: account list, labels, bucket selection, style, history. */
class AppPrefs(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("claude_meter_prefs", Context.MODE_PRIVATE)

    fun getAccountIds(): List<String> {
        val raw = prefs.getString("account_ids", "[]") ?: "[]"
        val arr = JSONArray(raw)
        return (0 until arr.length()).map { arr.getString(it) }
    }

    fun setAccountIds(ids: List<String>) {
        prefs.edit().putString("account_ids", JSONArray(ids).toString()).apply()
    }

    fun getAccountLabel(accountId: String): String = prefs.getString("label_$accountId", accountId) ?: accountId

    fun setAccountLabel(accountId: String, label: String) {
        prefs.edit().putString("label_$accountId", label).apply()
    }

    fun isPrimaryAccount(accountId: String): Boolean = prefs.getBoolean("primary_$accountId", false)

    fun setPrimaryAccount(accountId: String, isPrimary: Boolean) {
        prefs.edit().putBoolean("primary_$accountId", isPrimary).apply()
    }

    fun getActiveAccountId(): String? = prefs.getString("active_account_id", null)

    fun setActiveAccountId(accountId: String) {
        prefs.edit().putString("active_account_id", accountId).apply()
    }

    fun getFeaturedBucketIds(): Set<String> =
        prefs.getStringSet("featured_bucket_ids", setOf("weekly_all", "session")) ?: emptySet()

    fun setFeaturedBucketIds(ids: Set<String>) {
        prefs.edit().putStringSet("featured_bucket_ids", ids).apply()
    }

    fun isIconStyle(): Boolean = prefs.getBoolean("icon_style", true)

    fun setIconStyle(value: Boolean) {
        prefs.edit().putBoolean("icon_style", value).apply()
    }

    // --- History (7-day ring buffer per account) ---

    fun getHistory(accountId: String): List<HistorySample> {
        val raw = prefs.getString("history_$accountId", "[]") ?: "[]"
        val arr = JSONArray(raw)
        val list = mutableListOf<HistorySample>()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            list.add(HistorySample(o.getDouble("t"), o.getString("b"), o.getDouble("p")))
        }
        return list
    }

    fun appendHistory(accountId: String, samples: List<HistorySample>, nowEpochSeconds: Double) {
        val sevenDaysAgo = nowEpochSeconds - 7 * 24 * 3600
        val merged = (getHistory(accountId) + samples).filter { it.timestampEpochSeconds >= sevenDaysAgo }
        val arr = JSONArray()
        merged.forEach {
            arr.put(
                JSONObject()
                    .put("t", it.timestampEpochSeconds)
                    .put("b", it.bucketId)
                    .put("p", it.percent),
            )
        }
        prefs.edit().putString("history_$accountId", arr.toString()).apply()
    }
}
