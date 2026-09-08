package com.theportlandcompany.claudemeter.data

import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

private const val USER_AGENT = "ClaudeUsageTrendTracker/1.0"
private const val OAUTH_BETA_HEADER = "oauth-2025-04-20"
private const val CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

sealed class UsageResult {
    data class Success(val snapshot: UsageSnapshot) : UsageResult()
    object SignInExpired : UsageResult()
    data class Failure(val message: String) : UsageResult()
}

sealed class TokenRefreshResult {
    data class Success(val accessToken: String, val refreshToken: String?, val expiresInSeconds: Long) : TokenRefreshResult()
    data class Failure(val message: String) : TokenRefreshResult()
}

/** Plain HttpURLConnection client for the Anthropic OAuth usage/profile endpoints. */
object UsageApi {

    fun fetchUsage(accessToken: String): UsageResult {
        return try {
            val conn = openGet("https://api.anthropic.com/api/oauth/usage", accessToken)
            val code = conn.responseCode
            if (code == 401) {
                conn.disconnect()
                return UsageResult.SignInExpired
            }
            if (code !in 200..299) {
                val body = readStream(conn.errorStream)
                conn.disconnect()
                return UsageResult.Failure("HTTP $code: $body")
            }
            val body = readStream(conn.inputStream)
            conn.disconnect()
            UsageResult.Success(parseUsage(body))
        } catch (e: Exception) {
            UsageResult.Failure(e.message ?: "network error")
        }
    }

    /** Best-effort; returns null on any failure, never throws. */
    fun fetchProfileEmail(accessToken: String): String? {
        return try {
            val conn = openGet("https://api.anthropic.com/api/oauth/profile", accessToken)
            if (conn.responseCode !in 200..299) {
                conn.disconnect()
                return null
            }
            val body = readStream(conn.inputStream)
            conn.disconnect()
            JSONObject(body).optJSONObject("account")?.optString("email")?.takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            null
        }
    }

    fun refreshToken(refreshToken: String): TokenRefreshResult {
        return try {
            val payload = JSONObject()
                .put("grant_type", "refresh_token")
                .put("refresh_token", refreshToken)
                .put("client_id", CLIENT_ID)
            postToken(payload)
        } catch (e: Exception) {
            TokenRefreshResult.Failure(e.message ?: "network error")
        }
    }

    /** Exchanges an authorization code (from the OAuth redirect or the manual
     * CODE#STATE paste) for an access/refresh token pair. */
    fun exchangeCode(
        code: String,
        codeVerifier: String,
        redirectUri: String,
        state: String,
    ): TokenRefreshResult {
        return try {
            val payload = JSONObject()
                .put("grant_type", "authorization_code")
                .put("client_id", CLIENT_ID)
                .put("code", code)
                .put("redirect_uri", redirectUri)
                .put("code_verifier", codeVerifier)
                .put("state", state)
            postToken(payload)
        } catch (e: Exception) {
            TokenRefreshResult.Failure(e.message ?: "network error")
        }
    }

    private fun postToken(payload: JSONObject): TokenRefreshResult {
        val url = URL("https://console.anthropic.com/v1/oauth/token")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        conn.setRequestProperty("User-Agent", USER_AGENT)
        conn.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
        val code = conn.responseCode
        if (code !in 200..299) {
            val err = readStream(conn.errorStream)
            conn.disconnect()
            return TokenRefreshResult.Failure("HTTP $code: $err")
        }
        val body = readStream(conn.inputStream)
        conn.disconnect()
        val json = JSONObject(body)
        return TokenRefreshResult.Success(
            accessToken = json.getString("access_token"),
            refreshToken = json.optString("refresh_token").takeIf { it.isNotBlank() },
            expiresInSeconds = json.optLong("expires_in", 0L),
        )
    }

    private fun openGet(urlString: String, accessToken: String): HttpURLConnection {
        val conn = URL(urlString).openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.setRequestProperty("Authorization", "Bearer $accessToken")
        conn.setRequestProperty("anthropic-beta", OAUTH_BETA_HEADER)
        conn.setRequestProperty("User-Agent", USER_AGENT)
        conn.connectTimeout = 15_000
        conn.readTimeout = 15_000
        return conn
    }

    private fun readStream(stream: java.io.InputStream?): String {
        if (stream == null) return ""
        BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).use { reader ->
            return reader.readText()
        }
    }

    private fun parseUsage(body: String): UsageSnapshot {
        val json = JSONObject(body)
        val nowSeconds = System.currentTimeMillis() / 1000.0
        val buckets = mutableListOf<UsageBucket>()
        val limits = json.optJSONArray("limits")
        if (limits != null) {
            for (i in 0 until limits.length()) {
                val b = limits.getJSONObject(i)
                val kind = b.optString("kind", "unknown")
                val group = b.optString("group").takeIf { it.isNotBlank() }
                val percent = b.optDouble("percent", 0.0)
                val resetsAtStr = b.optString("resets_at").takeIf { it.isNotBlank() }
                val resetsAt = resetsAtStr?.let { parseIso8601(it) }
                val scope = b.optJSONObject("scope")?.optJSONObject("model")?.optString("display_name")
                    ?.takeIf { it.isNotBlank() }
                val isActive = if (b.has("is_active")) b.optBoolean("is_active") else null
                buckets.add(UsageBucket(kind, group, percent, resetsAt, scope, isActive))
            }
        }
        val extra = json.optJSONObject("extra_usage")?.let {
            ExtraUsage(
                isEnabled = it.optBoolean("is_enabled", false),
                usedCredits = it.optLong("used_credits", 0L),
                monthlyLimit = it.optLong("monthly_limit", 0L),
                utilization = it.optDouble("utilization", 0.0),
            )
        }
        return UsageSnapshot(buckets, extra, nowSeconds)
    }

    private fun parseIso8601(s: String): Double? {
        return try {
            val instant = java.time.Instant.parse(s)
            instant.toEpochMilli() / 1000.0
        } catch (e: Exception) {
            null
        }
    }
}
