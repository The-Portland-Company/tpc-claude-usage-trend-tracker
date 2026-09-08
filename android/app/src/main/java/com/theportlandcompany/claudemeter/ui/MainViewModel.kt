package com.theportlandcompany.claudemeter.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.theportlandcompany.claudemeter.auth.OAuthSession
import com.theportlandcompany.claudemeter.auth.PairingPayload
import com.theportlandcompany.claudemeter.auth.Pkce
import com.theportlandcompany.claudemeter.data.Account
import com.theportlandcompany.claudemeter.data.AppPrefs
import com.theportlandcompany.claudemeter.data.SecureStore
import com.theportlandcompany.claudemeter.data.HistorySample
import com.theportlandcompany.claudemeter.data.TokenRefreshResult
import com.theportlandcompany.claudemeter.data.UsageApi
import com.theportlandcompany.claudemeter.data.UsageResult
import com.theportlandcompany.claudemeter.data.UsageSnapshot
import com.theportlandcompany.claudemeter.notif.NotificationHelper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

private const val OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private const val OAUTH_REDIRECT_URI = "claudetracker://oauth-callback"
private const val OAUTH_AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
private const val OAUTH_SCOPES = "user:profile user:inference"

sealed class LoadState {
    object Idle : LoadState()
    object Loading : LoadState()
    data class Loaded(val snapshot: UsageSnapshot) : LoadState()
    object SignInExpired : LoadState()
    data class Error(val message: String) : LoadState()
    object NeedsOnboarding : LoadState()
}

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val prefs = AppPrefs(application)
    private val secure = SecureStore(application)

    private val _state = MutableStateFlow<LoadState>(LoadState.Idle)
    val state: StateFlow<LoadState> = _state.asStateFlow()

    private val _accounts = MutableStateFlow<List<Account>>(emptyList())
    val accounts: StateFlow<List<Account>> = _accounts.asStateFlow()

    private val _activeAccountId = MutableStateFlow<String?>(null)
    val activeAccountId: StateFlow<String?> = _activeAccountId.asStateFlow()

    private val _history = MutableStateFlow<List<HistorySample>>(emptyList())
    val history: StateFlow<List<HistorySample>> = _history.asStateFlow()

    init {
        refreshAccountsList()
        val active = prefs.getActiveAccountId()
        if (active == null) {
            _state.value = LoadState.NeedsOnboarding
        } else {
            _activeAccountId.value = active
            load()
        }
    }

    private fun refreshAccountsList() {
        _accounts.value = prefs.getAccountIds().map {
            Account(it, prefs.getAccountLabel(it), prefs.isPrimaryAccount(it))
        }
    }

    fun addAccount(accessToken: String, refreshToken: String?, onResult: (Boolean, String?) -> Unit) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { UsageApi.fetchUsage(accessToken) }
            when (result) {
                is UsageResult.Success -> {
                    val id = UUID.randomUUID().toString()
                    val email = withContext(Dispatchers.IO) { UsageApi.fetchProfileEmail(accessToken) }
                    secure.saveTokens(id, accessToken, refreshToken)
                    prefs.setAccountLabel(id, email ?: "Account")
                    prefs.setAccountIds(prefs.getAccountIds() + id)
                    prefs.setActiveAccountId(id)
                    refreshAccountsList()
                    _activeAccountId.value = id
                    _state.value = LoadState.Loaded(result.snapshot)
                    onResult(true, null)
                }
                is UsageResult.SignInExpired -> onResult(false, "Sign-in expired for that token.")
                is UsageResult.Failure -> onResult(false, result.message)
            }
        }
    }

    fun removeAccount(accountId: String) {
        secure.removeTokens(accountId)
        val remaining = prefs.getAccountIds().filterNot { it == accountId }
        prefs.setAccountIds(remaining)
        refreshAccountsList()
        if (prefs.getActiveAccountId() == accountId) {
            val next = remaining.firstOrNull()
            if (next != null) {
                prefs.setActiveAccountId(next)
                _activeAccountId.value = next
                load()
            } else {
                _activeAccountId.value = null
                _state.value = LoadState.NeedsOnboarding
            }
        }
    }

    fun switchAccount(accountId: String) {
        prefs.setActiveAccountId(accountId)
        _activeAccountId.value = accountId
        load()
    }

    fun load() {
        val accountId = _activeAccountId.value ?: prefs.getActiveAccountId() ?: run {
            _state.value = LoadState.NeedsOnboarding
            return
        }
        val tokens = secure.loadTokens(accountId) ?: run {
            _state.value = LoadState.NeedsOnboarding
            return
        }
        _state.value = LoadState.Loading
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { UsageApi.fetchUsage(tokens.accessToken) }
            when (result) {
                is UsageResult.Success -> {
                    _state.value = LoadState.Loaded(result.snapshot)
                    val samples = result.snapshot.buckets.map {
                        HistorySample(result.snapshot.fetchedAtEpochSeconds, it.id, it.percent)
                    }
                    prefs.appendHistory(accountId, samples, result.snapshot.fetchedAtEpochSeconds)
                    _history.value = prefs.getHistory(accountId)
                    val featured = prefs.getFeaturedBucketIds()
                    val shown = result.snapshot.buckets.filter { featured.contains(it.kind) || featured.contains(it.id) }
                    NotificationHelper.showStatus(getApplication(), shown)
                }
                is UsageResult.SignInExpired -> _state.value = LoadState.SignInExpired
                is UsageResult.Failure -> _state.value = LoadState.Error(result.message)
            }
        }
    }

    // --- OAuth (Authorization Code + PKCE) ---

    /** Builds the authorize URL and stashes the PKCE verifier/state for the
     * pending exchange. Caller opens the returned URL in a Custom Tab. */
    fun buildOAuthAuthorizeUrl(): String {
        val verifier = Pkce.generateCodeVerifier()
        val challenge = Pkce.generateCodeChallenge(verifier)
        val state = Pkce.generateState()
        OAuthSession.pending = OAuthSession.Pending(verifier, state, OAUTH_REDIRECT_URI)
        return "$OAUTH_AUTHORIZE_URL" +
            "?client_id=$OAUTH_CLIENT_ID" +
            "&response_type=code" +
            "&redirect_uri=${android.net.Uri.encode(OAUTH_REDIRECT_URI)}" +
            "&scope=${android.net.Uri.encode(OAUTH_SCOPES)}" +
            "&code_challenge=$challenge" +
            "&code_challenge_method=S256" +
            "&state=$state"
    }

    /** Clears any in-flight PKCE state — used by Cancel / timeout / resume-with-
     * no-callback recovery so a stale authorize attempt can't be exchanged late. */
    fun cancelOAuthPending() {
        OAuthSession.pending = null
    }

    /** Completes the exchange for a code+state pair, whether captured
     * automatically via the redirect activity or pasted manually. */
    fun completeOAuth(code: String, state: String, onResult: (Boolean, String?) -> Unit) {
        val pending = OAuthSession.pending
        if (pending == null || pending.state != state) {
            onResult(false, "That sign-in link expired. Try again.")
            return
        }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                UsageApi.exchangeCode(code, pending.codeVerifier, pending.redirectUri, state)
            }
            OAuthSession.pending = null
            when (result) {
                is TokenRefreshResult.Success ->
                    finishAddingAccount(result.accessToken, result.refreshToken, onResult)
                is TokenRefreshResult.Failure -> onResult(false, result.message)
            }
        }
    }

    /** Parses "CODE#STATE" pasted from the manual/headless authorize page. */
    fun completeOAuthFromManualPaste(pasted: String, onResult: (Boolean, String?) -> Unit) {
        val parts = pasted.trim().split("#", limit = 2)
        if (parts.size != 2 || parts[0].isBlank() || parts[1].isBlank()) {
            onResult(false, "Expected the code in CODE#STATE format.")
            return
        }
        completeOAuth(parts[0], parts[1], onResult)
    }

    // --- QR pairing ---

    fun handlePairingScan(raw: String, onResult: (Boolean, String?) -> Unit) {
        val payload = PairingPayload.parse(raw)
        if (payload == null) {
            onResult(false, "That QR code has expired or isn't a pairing code. Generate a new one on your Mac.")
            return
        }
        finishAddingAccount(payload.accessToken, payload.refreshToken, onResult)
    }

    // --- Shared account finalization ---

    private fun finishAddingAccount(accessToken: String, refreshToken: String?, onResult: (Boolean, String?) -> Unit) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { UsageApi.fetchUsage(accessToken) }
            when (result) {
                is UsageResult.Success -> {
                    val id = UUID.randomUUID().toString()
                    val email = withContext(Dispatchers.IO) { UsageApi.fetchProfileEmail(accessToken) }
                    secure.saveTokens(id, accessToken, refreshToken)
                    prefs.setAccountLabel(id, email ?: "Account")
                    prefs.setAccountIds(prefs.getAccountIds() + id)
                    prefs.setActiveAccountId(id)
                    refreshAccountsList()
                    _activeAccountId.value = id
                    _state.value = LoadState.Loaded(result.snapshot)
                    onResult(true, null)
                }
                is UsageResult.SignInExpired -> onResult(false, "That token has expired.")
                is UsageResult.Failure -> onResult(false, result.message)
            }
        }
    }

    fun featuredBucketIds(): Set<String> = prefs.getFeaturedBucketIds()
    fun setFeaturedBucketIds(ids: Set<String>) = prefs.setFeaturedBucketIds(ids)
    fun isIconStyle(): Boolean = prefs.isIconStyle()
    fun setIconStyle(value: Boolean) = prefs.setIconStyle(value)
}
