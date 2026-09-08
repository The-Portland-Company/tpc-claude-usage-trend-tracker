package com.theportlandcompany.claudemeter.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.theportlandcompany.claudemeter.data.Account
import com.theportlandcompany.claudemeter.data.AppPrefs
import com.theportlandcompany.claudemeter.data.SecureStore
import com.theportlandcompany.claudemeter.data.HistorySample
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

    fun featuredBucketIds(): Set<String> = prefs.getFeaturedBucketIds()
    fun setFeaturedBucketIds(ids: Set<String>) = prefs.setFeaturedBucketIds(ids)
    fun isIconStyle(): Boolean = prefs.isIconStyle()
    fun setIconStyle(value: Boolean) = prefs.setIconStyle(value)
}
