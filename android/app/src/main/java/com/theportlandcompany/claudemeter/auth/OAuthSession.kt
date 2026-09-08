package com.theportlandcompany.claudemeter.auth

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** In-memory holder for the in-flight PKCE exchange plus a channel the
 * redirect-catching activity uses to hand the result back to the app. */
object OAuthSession {

    data class Pending(val codeVerifier: String, val state: String, val redirectUri: String)

    data class Result(val code: String, val state: String)

    var pending: Pending? = null

    private val _results = MutableSharedFlow<Result>(extraBufferCapacity = 1)
    val results = _results.asSharedFlow()

    fun deliver(code: String, state: String) {
        _results.tryEmit(Result(code, state))
    }
}
