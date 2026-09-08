package com.theportlandcompany.claudemeter.auth

import org.json.JSONObject

/** The QR payload the macOS app shows under "Set up on your phone":
 * `{ "v":1, "t":"<accessToken>", "r":"<refreshToken|null>",
 *    "e":<expiresAtMillis>, "s":["<scopes>"], "iat":<nowMillis> }` */
data class PairingPayload(
    val version: Int,
    val accessToken: String,
    val refreshToken: String?,
    val expiresAtMillis: Long,
    val scopes: List<String>,
    val issuedAtMillis: Long,
) {
    companion object {
        private const val MAX_AGE_MILLIS = 90_000L

        /** Parses and validates freshness/version. Returns null if malformed, wrong
         * version, or older than 90s. */
        fun parse(raw: String, nowMillis: Long = System.currentTimeMillis()): PairingPayload? {
            return try {
                val json = JSONObject(raw)
                val version = json.optInt("v", -1)
                if (version != 1) return null
                val token = json.optString("t").takeIf { it.isNotBlank() } ?: return null
                val refresh = json.optString("r").takeIf { it.isNotBlank() && it != "null" }
                val expiresAt = json.optLong("e", 0L)
                val issuedAt = json.optLong("iat", 0L)
                if (issuedAt <= 0L || nowMillis - issuedAt > MAX_AGE_MILLIS) return null
                val scopesArr = json.optJSONArray("s")
                val scopes = if (scopesArr != null) {
                    (0 until scopesArr.length()).map { scopesArr.getString(it) }
                } else emptyList()
                PairingPayload(version, token, refresh, expiresAt, scopes, issuedAt)
            } catch (e: Exception) {
                null
            }
        }
    }
}
