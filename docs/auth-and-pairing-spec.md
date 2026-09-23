# Auth & Pairing Spec — Claude Usage Trend Tracker

How the iOS and Android apps obtain a Claude access token without the user
hand-copying it out of the macOS Keychain. Two paths, offered side by side:

1. **Sign in with Claude (OAuth)** — primary.
2. **Pair with your Mac (QR)** — fallback, fully in our control.

Manual token paste stays as a hidden "Advanced" option.

---

## 1. Sign in with Claude — OAuth 2.0 (Authorization Code + PKCE)

Reuses the Claude Code OAuth client (there is no public third-party client for
consumer usage today). Everything below is the **client side only** — no client
secret exists (public client + PKCE).

### Constants
- `CLIENT_ID` = `9d1c250a-e61b-44d9-88ed-5944d1962f5e`  (Claude Code's public client)
- Authorize URL: `https://claude.ai/oauth/authorize`
- Token URL: `https://console.anthropic.com/v1/oauth/token`
- Scopes: `user:profile user:inference` (the usage endpoint works with the
  Claude-Code-issued token set; request the minimal profile+inference scopes)
- Usage API stays: `GET https://api.anthropic.com/api/oauth/usage`, headers
  `Authorization: Bearer <access>` + `anthropic-beta: oauth-2025-04-20`.

### PKCE
- `code_verifier` = 64 random URL-safe bytes, base64url (no padding).
- `code_challenge` = base64url( SHA256(code_verifier) ), method `S256`.
- `state` = random 32 bytes base64url; verify on return.

### Flow (mobile)
1. Build authorize URL with `client_id, response_type=code, redirect_uri,
   scope, code_challenge, code_challenge_method=S256, state`.
2. Open it in an in-app browser tab:
   - iOS: `ASWebAuthenticationSession` (callback scheme registered).
   - Android: Chrome Custom Tabs (AppAuth) with an app-link/scheme redirect.
3. Two possible returns — implement BOTH, prefer (a):
   - **(a) Auto-capture**: if the client accepts our `redirect_uri`
     (`claudetracker://oauth-callback`), the browser redirects back with
     `?code=...&state=...`; the session hands it to the app.
   - **(b) Manual code**: if the client rejects custom redirects, use the
     manual/headless variant — the authorize page shows `CODE#STATE`; user
     copies it, returns, pastes into a single field. Split on `#` →
     `code`, `state`.
4. Verify `state`. Exchange at Token URL (POST JSON):
   ```json
   { "grant_type": "authorization_code", "client_id": "<CLIENT_ID>",
     "code": "<code>", "redirect_uri": "<same redirect>",
     "code_verifier": "<verifier>", "state": "<state>" }
   ```
   Response: `{ access_token, refresh_token, expires_in, ... }`.
5. Store tokens securely (Keychain / EncryptedSharedPreferences), compute
   `expiresAt = now + expires_in`.
6. Refresh independently when near expiry (POST `grant_type=refresh_token`,
   `client_id`, `refresh_token`). NOTE: the app holds its OWN token set
   (separate from any Claude Code install), so refreshing here is safe — it
   does not stomp a desktop Claude Code session.

### Unverifiable-until-live note
Whether `CLIENT_ID` permits `claudetracker://oauth-callback` can only be
confirmed with a real login. Ship (a) with (b) as automatic fallback, so the
sign-in works either way.

---

## 2. Pair with your Mac — QR (fully in our control)

The macOS app already holds a valid token (read from Claude Code's Keychain).
It hands it to a phone over the local visual channel — nothing leaves the
machine except the QR the camera sees.

### macOS (source) — new "Set up on your phone" in Settings
- Button reveals a **QR code** (and a short numeric code as backup) encoding a
  compact JSON payload:
  ```json
  { "v":1, "t":"<accessToken>", "r":"<refreshToken|null>",
    "e":<expiresAtMillis>, "s":["<scopes>"], "iat":<nowMillis> }
  ```
- `r` is always `null`. Refresh tokens rotate, so sharing one lets whichever
  device renews first revoke the other's copy (this silently signed the Mac
  out). The phone gets a short-lived access token only and uses Sign in with
  Claude for a lasting session.
- The QR is shown only on demand and auto-hides after 60s (`iat` lets the phone
  reject stale payloads). Never persisted to disk; regenerated each time.
- Render with a self-contained QR generator (no network).

### iOS / Android (sink)
- "Pair with my Mac" → camera QR scanner (iOS AVFoundation; Android CameraX +
  ML Kit barcode or ZXing).
- Decode JSON, reject if `now - iat > 90s` or `v != 1`.
- Validate the token by calling the usage endpoint once; on success store it
  (same secure store as OAuth) and proceed.

### Security
- Payload contains a real token — treat as a secret. Only shown on explicit
  user action, short TTL, transferred over the camera (no server, no network
  hop). Store encrypted at rest on the phone. Document this in the UI ("Only do
  this on a device you own").

---

## Onboarding UI (both phones)
Primary screen offers, in order:
1. **Sign in with Claude** (OAuth) — big primary button.
2. **Pair with my Mac** (QR) — secondary button.
3. **Advanced: paste a token** — collapsed disclosure (the current flow, kept).

Wording and severity colors follow `parity-manifest.md`.
