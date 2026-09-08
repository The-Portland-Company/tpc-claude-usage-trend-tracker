package com.theportlandcompany.claudemeter

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.theportlandcompany.claudemeter.auth.OAuthSession
import com.theportlandcompany.claudemeter.data.Account
import com.theportlandcompany.claudemeter.data.ExtraUsage
import com.theportlandcompany.claudemeter.pace.PaceMath
import com.theportlandcompany.claudemeter.ui.*

class MainActivity : ComponentActivity() {

    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            ClaudeMeterTheme {
                Surface {
                    AppRoot(viewModel)
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.load()
    }
}

private enum class Screen { MAIN, SETTINGS, ADD_ACCOUNT }

@Composable
fun AppRoot(viewModel: MainViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val accounts by viewModel.accounts.collectAsStateWithLifecycle()
    val activeAccountId by viewModel.activeAccountId.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()

    var screen by remember { mutableStateOf(Screen.MAIN) }
    val context = androidx.compose.ui.platform.LocalContext.current

    val notifPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notifPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    var pendingResult by remember { mutableStateOf<((Boolean, String?) -> Unit)?>(null) }
    LaunchedEffect(Unit) {
        OAuthSession.results.collect { result ->
            viewModel.completeOAuth(result.code, result.state) { ok, err ->
                pendingResult?.invoke(ok, err)
                if (ok) screen = Screen.MAIN
            }
        }
    }

    val qrScanLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
        val raw = result.contents
        if (raw != null) {
            viewModel.handlePairingScan(raw) { ok, err ->
                pendingResult?.invoke(ok, err)
                if (ok) screen = Screen.MAIN
            }
        }
    }

    fun launchOAuth() {
        val url = viewModel.buildOAuthAuthorizeUrl()
        CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(url))
    }

    fun launchQrScan() {
        qrScanLauncher.launch(
            ScanOptions()
                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt("Scan the QR code from your Mac's Settings")
                .setBeepEnabled(false)
                .setOrientationLocked(true),
        )
    }

    when {
        state is LoadState.NeedsOnboarding || screen == Screen.ADD_ACCOUNT -> {
            OnboardingScreen(
                onSignInWithClaude = { onResult ->
                    pendingResult = onResult
                    launchOAuth()
                },
                onPairWithMac = { onResult ->
                    pendingResult = onResult
                    launchQrScan()
                },
                onSubmitManualCode = { pasted, onResult ->
                    viewModel.completeOAuthFromManualPaste(pasted) { ok, err ->
                        onResult(ok, err)
                        if (ok) screen = Screen.MAIN
                    }
                },
                onSubmit = { access, refresh, onResult ->
                    viewModel.addAccount(access, refresh) { ok, err ->
                        onResult(ok, err)
                        if (ok) screen = Screen.MAIN
                    }
                },
                onCancel = if (accounts.isNotEmpty()) { { screen = Screen.MAIN } } else null,
            )
        }
        screen == Screen.SETTINGS -> {
            SettingsScreen(
                viewModel = viewModel,
                accounts = accounts,
                activeAccountId = activeAccountId,
                onBack = { screen = Screen.MAIN },
                onAddAccount = { screen = Screen.ADD_ACCOUNT },
            )
        }
        else -> {
            MainScreen(
                state = state,
                history = history,
                onSettings = { screen = Screen.SETTINGS },
                onRefresh = { viewModel.load() },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    state: LoadState,
    history: List<com.theportlandcompany.claudemeter.data.HistorySample>,
    onSettings: () -> Unit,
    onRefresh: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Claude Usage Trend Tracker") },
                actions = {
                    IconButton(onClick = onSettings) {
                        Icon(Icons.Filled.Settings, contentDescription = "Settings")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            when (state) {
                is LoadState.Loading, LoadState.Idle -> {
                    Box(Modifier.fillMaxWidth().padding(vertical = 48.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                }
                is LoadState.SignInExpired -> {
                    Text("Sign-in expired", style = MaterialTheme.typography.titleMedium, color = SeverityCritical)
                    Spacer(Modifier.height(8.dp))
                    Text("Add this account again with a fresh token from Settings.")
                }
                is LoadState.Error -> {
                    Text("Couldn't load usage", style = MaterialTheme.typography.titleMedium, color = SeverityCritical)
                    Spacer(Modifier.height(8.dp))
                    Text(state.message)
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = onRefresh) { Text("Retry") }
                }
                is LoadState.Loaded -> {
                    val now = state.snapshot.fetchedAtEpochSeconds
                    Text(
                        verdictLine(state.snapshot.buckets, now),
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(20.dp))
                    state.snapshot.buckets.forEach { bucket ->
                        val row = buildBucketRow(bucket, history, now)
                        BucketCard(row)
                        Spacer(Modifier.height(12.dp))
                    }
                    state.snapshot.extraUsage?.let { extra ->
                        if (extra.isEnabled) {
                            ExtraUsageCard(extra)
                            Spacer(Modifier.height(12.dp))
                        }
                    }
                }
                else -> {}
            }
        }
    }
}

@Composable
fun BucketCard(row: BucketRow) {
    val tint = when (row.severity) {
        PaceMath.Severity.NORMAL -> MaterialTheme.colorScheme.onSurface
        PaceMath.Severity.WARNING -> SeverityWarning
        PaceMath.Severity.CRITICAL -> SeverityCritical
    }
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(row.bucket.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text(
                    "${row.bucket.percent.toInt()}%",
                    style = MaterialTheme.typography.titleLarge,
                    color = tint,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.width(6.dp))
                Text(row.trend.glyph, style = MaterialTheme.typography.titleLarge, color = tint)
            }
            LinearProgressIndicator(
                progress = { (row.bucket.percent / 100.0).toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                color = tint,
            )
            Spacer(Modifier.height(6.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                row.paceLine?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                row.resetCountdown?.let { Text("resets $it", style = MaterialTheme.typography.bodySmall) }
            }
        }
    }
}

@Composable
fun ExtraUsageCard(extra: ExtraUsage) {
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(Modifier.fillMaxWidth()) {
                Text("Overage credits", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text("${extra.utilization.toInt()}%", style = MaterialTheme.typography.titleLarge)
            }
            Spacer(Modifier.height(4.dp))
            Text(
                "$${"%.2f".format(extra.usedCredits / 100.0)} of $${"%.2f".format(extra.monthlyLimit / 100.0)} this month",
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
fun OnboardingScreen(
    onSignInWithClaude: ((Boolean, String?) -> Unit) -> Unit,
    onPairWithMac: ((Boolean, String?) -> Unit) -> Unit,
    onSubmitManualCode: (String, (Boolean, String?) -> Unit) -> Unit,
    onSubmit: (String, String?, (Boolean, String?) -> Unit) -> Unit,
    onCancel: (() -> Unit)?,
) {
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var advancedExpanded by remember { mutableStateOf(false) }

    var manualCode by remember { mutableStateOf("") }
    var accessToken by remember { mutableStateOf("") }
    var refreshToken by remember { mutableStateOf("") }

    fun runFlow(start: ((Boolean, String?) -> Unit) -> Unit) {
        loading = true
        error = null
        start { ok, err ->
            loading = false
            if (!ok) error = err ?: "Couldn't sign you in."
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
    ) {
        Text("Claude Usage Trend Tracker", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text(
            "Connect a Claude account to see your usage and pace.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(24.dp))

        Button(
            enabled = !loading,
            onClick = { runFlow(onSignInWithClaude) },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Sign in with Claude")
        }
        Spacer(Modifier.height(10.dp))
        OutlinedButton(
            enabled = !loading,
            onClick = { runFlow(onPairWithMac) },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Pair with my Mac")
        }

        error?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, color = SeverityCritical)
        }
        if (loading) {
            Spacer(Modifier.height(12.dp))
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }

        Spacer(Modifier.height(24.dp))
        TextButton(onClick = { advancedExpanded = !advancedExpanded }, modifier = Modifier.fillMaxWidth()) {
            Text(if (advancedExpanded) "Hide advanced options" else "Advanced: paste a token")
        }

        if (advancedExpanded) {
            Spacer(Modifier.height(8.dp))
            Text("Paste OAuth code", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(4.dp))
            Text(
                "If sign-in didn't return to the app, paste the CODE#STATE shown on the authorize page.",
                style = MaterialTheme.typography.bodySmall,
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = manualCode,
                onValueChange = { manualCode = it },
                label = { Text("CODE#STATE") },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            Button(
                enabled = manualCode.isNotBlank() && !loading,
                onClick = {
                    loading = true
                    error = null
                    onSubmitManualCode(manualCode.trim()) { ok, err ->
                        loading = false
                        if (!ok) error = err ?: "Couldn't complete sign-in."
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Complete sign-in")
            }

            Spacer(Modifier.height(20.dp))
            Text("Paste a token directly", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(4.dp))
            Text(
                "Find it on a machine where you've run Claude Code, in the credential store's claudeAiOauth.accessToken field.",
                style = MaterialTheme.typography.bodySmall,
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = accessToken,
                onValueChange = { accessToken = it },
                label = { Text("Access token") },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = refreshToken,
                onValueChange = { refreshToken = it },
                label = { Text("Refresh token (optional)") },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Button(
                enabled = accessToken.isNotBlank() && !loading,
                onClick = {
                    loading = true
                    error = null
                    onSubmit(accessToken.trim(), refreshToken.trim().ifBlank { null }) { ok, err ->
                        loading = false
                        if (!ok) error = err ?: "Couldn't validate that token."
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (loading) "Validating…" else "Add account")
            }
        }

        if (onCancel != null) {
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    viewModel: MainViewModel,
    accounts: List<Account>,
    activeAccountId: String?,
    onBack: () -> Unit,
    onAddAccount: () -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var iconStyle by remember { mutableStateOf(viewModel.isIconStyle()) }
    var featured by remember { mutableStateOf(viewModel.featuredBucketIds()) }

    val allKnownBuckets = listOf("session" to "5-hour session", "weekly_all" to "Week · all models")

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            Text("Accounts", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            accounts.forEach { account ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(
                        selected = account.id == activeAccountId,
                        onClick = { viewModel.switchAccount(account.id) },
                    )
                    Text(account.label, modifier = Modifier.weight(1f))
                    IconButton(onClick = { viewModel.removeAccount(account.id) }) {
                        Icon(Icons.Filled.Delete, contentDescription = "Remove")
                    }
                }
            }
            TextButton(onClick = onAddAccount) { Text("Add account") }

            Spacer(Modifier.height(24.dp))
            Text("Featured limits", style = MaterialTheme.typography.titleMedium)
            allKnownBuckets.forEach { (kind, label) ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = featured.contains(kind),
                        onCheckedChange = { checked ->
                            featured = if (checked) featured + kind else featured - kind
                            viewModel.setFeaturedBucketIds(featured)
                        },
                    )
                    Text(label)
                }
            }

            Spacer(Modifier.height(24.dp))
            Text("Notification style", style = MaterialTheme.typography.titleMedium)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Icon + percent", modifier = Modifier.weight(1f))
                Switch(
                    checked = iconStyle,
                    onCheckedChange = {
                        iconStyle = it
                        viewModel.setIconStyle(it)
                    },
                )
            }

            Spacer(Modifier.height(32.dp))
            TextButton(onClick = {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://theportlandcompany.com/apps"))
                context.startActivity(intent)
            }) {
                Text("More apps by Spencer Hill & The Portland Company")
            }
        }
    }
}
