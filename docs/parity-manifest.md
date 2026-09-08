# Claude Usage Trend Tracker — Cross-Platform Parity Manifest

## 1. Purpose & scope

Claude Usage Trend Tracker shows a Claude Code user, at a glance, how much of
their 5-hour session and weekly usage limits they've burned, whether they're
on pace to run out before the next reset, and lets them monitor multiple
Claude accounts from one place. The macOS menu-bar app (`Sources/`) is the
source of truth. This manifest is the spec every other platform build (iOS,
Windows, Android) must conform to: same data contract, same math, same
feature set, translated to each OS's native idioms. It exists so that a
new-platform build starts from "what must be true," not from re-reading Swift.

## 2. Shared data contract

### 2.1 API

- **Auth**: Bearer token read from the local Claude Code credential store —
  macOS Keychain service `Claude Code-credentials`, key `claudeAiOauth`,
  fields `accessToken` (string) and `expiresAt` (ms since epoch). The app
  never writes/refreshes this token for the primary account — a second
  writer can invalidate the token Claude Code itself is using.
- **Usage**: `GET https://api.anthropic.com/api/oauth/usage`
  Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
  `User-Agent: <AppName>/<version>`.
  Response: `{ limits: [...], extra_usage: {...} }` (see 2.2/2.3). Unknown
  top-level keys are ignored; unknown `kind` values must still render
  generically (title-cased fallback), never crash.
- **Profile (best-effort, non-fatal)**: `GET https://api.anthropic.com/api/oauth/profile`,
  same headers. Response: `{ account: { email } }`. Used only to label the
  active account; a failure here must never block the usage fetch.
- **Token refresh (added/secondary accounts only)**: `POST
  https://console.anthropic.com/v1/oauth/token`, JSON body `{grant_type:
  "refresh_token", refresh_token, client_id}`, client id
  `9d1c250a-e61b-44d9-88ed-5944d1962f5e`. Response: `{access_token,
  refresh_token?, expires_in}`. Any failure (network, non-2xx, unparseable)
  degrades to "sign-in expired," never a crash.
- **HTTP 401** on the usage endpoint always means "sign-in expired," not a
  generic error — surface it as such.
- Poll interval: every 5 minutes while running, plus an immediate refresh on
  wake/foreground.

### 2.2 Bucket kinds

Each `limits[]` entry ("bucket") has: `kind`, optional `group`, `percent`
(0–100+), optional `severity` (server-provided, ignored in favor of local
math — see 2.4), optional `resets_at` (ISO-8601), optional
`scope.model.display_name` (e.g. `"Fable"`), optional `is_active`.

| kind | meaning | window length | title |
| --- | --- | --- | --- |
| `session` | rolling 5-hour session limit | 5 hours | "5-hour session" |
| `weekly_all` | week, all models combined | 7 days | "Week · all models" |
| `weekly_scoped` | week, one model (has `scope.model.display_name`) | 7 days | "Week · {model}" (e.g. "Week · Fable") |
| anything else | unrecognized — render generically | none (no projection) | `kind` with underscores → spaces, capitalized |

A bucket's stable identity for history/notifications is `kind` alone, except
`weekly_scoped` which is disambiguated by scope: `"{kind}|{scopeDisplayName}"`.

`weekly_all` is the **primary** bucket: it drives the top-line verdict, the
default menu-bar/status figure, and the app's overall severity floor.

### 2.3 Overage credits (optional)

`extra_usage`: `{is_enabled, used_credits, monthly_limit, utilization}`
(credits in cents; divide by 100 for dollars). When `is_enabled`, show as an
extra row: "Overage credits", percent = `utilization`, subtext "$X of $Y
this month," severity computed the same way as any bucket (percent-only,
no projection).

### 2.4 Severity, trend, projection — identical math on every platform

These are pure functions (`PaceMath.swift`) with no I/O; every platform must
implement them bit-for-bit the same, not approximate them, so a user sees
the same numbers switching devices.

**Window length by kind:**
`session` (or legacy `five_hour`) → 5h. `weekly_*` (or legacy `seven_day`) →
7 days. Anything else → no window, so no projection/trend (nil).

**Projection** (straight-line pace, computed only when window length and
`resets_at` are both known):
```
windowStart = resetsAt - windowLength
elapsedFraction = clamp(now - windowStart) / windowLength, min 0.02, max 1.0
projectedAtReset = percent / elapsedFraction
ratePerHour = percent / (elapsedFraction * windowHours)
sustainableRatePerHour = 100 / windowHours
overPace = projectedAtReset > 100
hits100At = now + ((100 - percent) / ratePerHour) hours,
            only when percent > 0 and ratePerHour > 0 and overPace
```
The 0.02 floor prevents a divide-by-near-zero right after a reset.

**Severity** (local, independent of any server-sent severity string — this
lets the UI go amber before the server does):
```
if percent >= 90: critical
elif overPace and percent >= 50: critical
elif percent >= 75: warning
elif overPace: warning
else: normal
```
App-wide severity = the max severity across all visible buckets.

**Trend** (arrow over the last 1 hour of samples):
```
recent = samples in the last 3600s, sorted by time
require >= 2 samples spanning >= 600s, else "unknown" (·)
slope = (last.percent - first.percent) / hoursBetween
sustainable = 100 / windowHours
if slope < 0: falling (↘)          # a reset happened inside the lookback
elif slope > sustainable * 1.25: rising (↗)
elif slope < sustainable * 0.75: falling (↘)
else: steady (→)
```

**Countdown formatting** ("in 2d 4h" / "in 3h 12m" / "in 40m" / "now") for
any relative time shown to the user (e.g. "you'll run out by…", reset
countdowns).

**Verdict line** (top-of-screen headline), from the `weekly_all` bucket only:
if `overPace` and `hits100At` is known → "You're going to run out by
{weekday, month day 'at' h:mm a}."; else → "You will not run out."; if no
`weekly_all` bucket yet, show a waiting/error state instead.

### 2.5 Persisted history

7-day ring buffer of `(timestamp, bucketId, percent)` samples, one entry per
poll per bucket, pruned to entries within the last 7 days. Keyed per
account (each account has its own history). Used to feed the sparkline (last
~48 samples) and the trend calculation. Store as local structured data
(JSON file, SQLite, platform DB) — no server sync required.

## 3. Feature parity matrix

| Feature | macOS | iOS | Windows | Android |
| --- | --- | --- | --- | --- |
| Glanceable percentages | Menu-bar text/icon items (persistent, always visible) | Home-Screen widget (small/medium WidgetKit) + Live Activity/Dynamic Island for the active session bucket; app itself for full detail | System-tray (notification area) icon with text overlay via a custom tray icon renderer | Persistent status-bar notification (ongoing, low-priority) showing the chosen bucket(s); Home-screen Glance widget as the no-notification alternative |
| Choose which limits shown | Settings: toggle bucket in/out of menu bar, ordered list | Widget configuration (WidgetKit `IntentConfiguration`): pick bucket(s) per widget instance | Tray-icon settings dialog: same toggle list | Widget config activity (`AppWidgetConfigure`) + in-app notification settings for which buckets appear |
| Icon vs colored-text style | Settings toggle: SF Symbol+percent vs. severity-tinted percent text | Widget has two layouts (icon-grid vs. text-only); user picks per widget via widget configuration | Tray icon renders either a glyph+percent bitmap or a colored percent-only bitmap, per setting | Notification/widget layout toggle: icon+percent chip vs. plain colored percent text |
| Per-model limits (e.g. Fable) | `weekly_scoped` rows in popover, own menu-bar entry option | Additional widget instance/row per scoped model; app detail list | Additional tray-icon slot / flyout row per scoped model | Additional widget cell / expandable notification line per scoped model |
| Pace projection ("you'll run out by…") | Verdict line at top of popover | Prominent widget/app text, plus a Live Activity countdown while over-pace | Flyout header text on tray click | Expanded notification's top line; widget primary text |
| Reset / threshold notifications | `UNUserNotificationCenter` local notifications (weekly reset, session reset opt-in, 75%/90% thresholds, over-pace) | `UNUserNotificationCenter` (same identifiers/logic) or scheduled local notifications via BGTask refresh | Windows `ToastNotificationManager` (Action Center toasts) | `NotificationManager` channel-based notifications (Android 13+ requires runtime POST_NOTIFICATIONS permission) |
| Multi-account | Account switcher in popover; add via pasted access/refresh token; per-account history/cache | In-app account switcher (same paste-token flow); widget bound to one chosen account at config time | Tray flyout account switcher; same paste-token add flow | In-app switcher; each home-widget instance bound to one account via its own configuration |
| Launch at login / autostart | `SMAppService.mainApp` (Settings toggle) | N/A (iOS apps don't autostart; rely on background refresh + widget timeline) | Registered via Startup folder / Task Scheduler entry or MSIX startup task, toggle in settings | `BOOT_COMPLETED` receiver re-arms the persistent notification/widget refresh worker, toggle in settings |
| Overage credits | "Overage credits" row when `extra_usage.is_enabled` | Same row in app detail view; omitted from small widgets for space | Same row in flyout | Same row in expanded notification / app detail |
| "More apps" CTA | Text link in popover footer | Link/row in app Settings screen | Link in tray flyout footer or Settings | Link in app Settings / About screen |

## 4. Per-platform notes

**macOS** — SwiftUI menu-bar app (`MenuBarExtra`), `@Observable` model,
`URLSession`, Keychain for credentials (primary account read-only from
Claude Code's own item; added accounts in the app's own keychain item under
`ClaudeUsageTrendTracker.account.<id>`). Distribution: Mac App Store
(current), with TestFlight/notarized DMG possible for pre-release builds.

**iOS** — SwiftUI app + WidgetKit extension (widget + optional Live
Activity/Dynamic Island for an active over-pace session). No background
polling equivalent to a 5-min timer; use `WidgetKit` timeline reloads
(`TimelineProvider` requesting refresh windows) plus opportunistic refresh
on app foreground and BGAppRefreshTask for periodic wake-ups. Credentials:
since iOS cannot read the macOS Claude Code Keychain item, accounts are
added by pasting a token (same flow as macOS "added accounts"), stored in
iOS Keychain (`kSecClassGenericPassword`, app's own access group).
Distribution: App Store.

**Windows** — .NET/WinUI 3 (or Tauri if a lighter binary is preferred;
WinUI 3 is the closer native match to macOS's menu-bar affordances via a
tray icon + flyout). System-tray icon with a custom-rendered glyph/text
bitmap refreshed per poll, flyout window mirroring the popover. Credentials
stored via Windows Credential Manager (DPAPI-backed), not plaintext config.
Distribution: MSIX package, Microsoft Store or side-loaded signed installer.

**Android** — Kotlin + Jetpack Compose. Glanceable surface is a persistent
low-priority foreground-service notification (ongoing, dismiss-proof only
while polling is active) showing chosen bucket(s), plus a Glance-based
home-screen widget for users who prefer no persistent notification. Polling
via `WorkManager` periodic work (min ~15 min granularity — coarser than the
5-min desktop interval; document this as an expected platform limitation)
plus foreground-service ticks while the notification is shown. Credentials
in `EncryptedSharedPreferences` / Android Keystore-backed storage. 
Distribution: Google Play Store.

**Cross-cutting**: every platform's local credential storage must be
OS-native secure storage (Keychain/Keystore/Credential Manager/DPAPI) —
never plaintext files or app-group UserDefaults/SharedPreferences for token
values. Only non-secret metadata (labels, emails, cached snapshot JSON,
menu-bar bucket selection, history) may live in ordinary
defaults/preferences/local DB.

## 5. Visual + naming consistency

- **App name**: "Claude Usage Trend Tracker" everywhere (exact casing);
  bundle/app display name must match across stores.
- **Icon**: same mark, full-bleed, adapted to each platform's icon shape
  rules (squircle/adaptive icon/etc.) without adding padding that isn't
  there in the macOS icon.
- **Severity colors** (must match exactly, using each OS's system semantic
  colors where available so it also adapts to light/dark and accessibility
  settings):
  - `normal` → system accent color (macOS: `Color.accentColor`)
  - `warning` → orange
  - `critical` → red
- **Menu-bar/tray tint rule**: `normal` severity renders as the platform's
  default label/primary text color (not tinted), only `warning`/`critical`
  get the severity color — avoids a permanently-colored status item.
- **Terminology** (verbatim, do not rephrase per platform):
  - "5-hour session"
  - "Week · all models"
  - "Week · {ModelDisplayName}" (e.g. "Week · Fable") — model names come
    from the API's `scope.model.display_name`, never hardcoded
  - "Overage credits"
  - Trend glyphs: ↗ rising, → steady, ↘ falling, · unknown
  - Verdict copy: "You're going to run out by {date/time}." / "You will not
    run out."
- **Footer CTA**: "More apps by Spencer Hill & The Portland Company" (same
  wording, linked out) wherever a settings/about surface exists.

## 6. Acceptance checklist per platform

- [ ] Reads/stores credentials only in OS-native secure storage; primary
      account (where applicable) is read-only from the OS's own Claude Code
      credential entry.
- [ ] Calls the exact usage/profile endpoints and headers in §2.1; treats
      HTTP 401 as "sign-in expired."
- [ ] Implements bucket kinds, titles, and IDs exactly per §2.2.
- [ ] Implements projection, severity, trend, and countdown formulas
      byte-for-byte per §2.4 (covered by unit tests mirroring
      `PaceMathTests.swift`).
- [ ] Persists a 7-day ring-buffer history per account and feeds it into
      the sparkline/trend.
- [ ] Shows the `weekly_all`-driven verdict line using the exact copy in
      §2.4/§5.
- [ ] Glanceable percentage surface matches its row in the parity matrix
      (§3) and lets the user choose which bucket(s) appear and icon vs.
      colored-text style.
- [ ] Supports per-model (`weekly_scoped`) rows/widgets.
- [ ] Fires reset and threshold (75%/90%) and over-pace notifications with
      the same arm/re-arm semantics as `NotificationPlanner.swift` (one per
      window, re-armed on a new `resets_at`).
- [ ] Supports adding/removing/switching multiple accounts via pasted
      token, each with its own cached snapshot and history.
- [ ] Provides an autostart/launch-at-login equivalent where the platform
      supports it, or documents why not (iOS).
- [ ] Shows the overage-credits row when `extra_usage.is_enabled`.
- [ ] Uses the exact app name, icon, severity colors, and terminology in §5.
- [ ] Includes the "More apps by Spencer Hill & The Portland Company" CTA.
- [ ] Ships through the platform's standard store/distribution channel
      named in §4.
