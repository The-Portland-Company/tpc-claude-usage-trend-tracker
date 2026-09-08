package com.theportlandcompany.claudemeter.auth

import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom

/** PKCE (Proof Key for Code Exchange) helpers for the OAuth authorization-code flow. */
object Pkce {

    private val random = SecureRandom()

    private fun randomBase64Url(byteCount: Int): String {
        val bytes = ByteArray(byteCount)
        random.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    /** 64 random URL-safe bytes, base64url (no padding). */
    fun generateCodeVerifier(): String = randomBase64Url(64)

    /** base64url( SHA256(codeVerifier) ), method S256. */
    fun generateCodeChallenge(codeVerifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(codeVerifier.toByteArray(Charsets.US_ASCII))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    /** Random 32-byte base64url state token, verified on return. */
    fun generateState(): String = randomBase64Url(32)
}
