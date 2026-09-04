# Releasing Claude Usage Trend Tracker

Two scripts. Both regenerate the Xcode project with XcodeGen first, so run them
from anywhere in the repo.

## Build and install locally

```
scripts/build-local.sh              # build, copy to /Applications, relaunch
scripts/build-local.sh --no-install # build only
```

The app is installed as `/Applications/Claude Usage Trend Tracker.app`. The script kills any
running copy, waits a second, reopens the installed bundle and prints its pid,
so you are always looking at the build you just made.

## Build a DMG

```
scripts/build-release.sh
```

Produces `dist/ClaudeUsageTrendTracker-<version>.dmg` containing the app and an
`/Applications` shortcut. The version comes from `MARKETING_VERSION` in
`project.yml`.

## What signing you get today

This Mac has an "Apple Development" and an "Apple Distribution" certificate. It
has no **Developer ID Application** certificate and no notarization credentials,
so the DMG this produces today is **not notarized**. It installs fine on this
Mac and will be blocked by Gatekeeper on anyone else's.

The app is deliberately **not sandboxed**: it reads Claude Code's Keychain item
(`Claude Code-credentials`), which the sandbox would block. Hardened runtime is
on, and no hardened-runtime exceptions are needed, so the entitlements file is
an empty dict.

## One-time setup for public distribution

A human has to do these once. They cannot be automated.

1. In Xcode, Settings, Accounts, add the Apple ID for team VP38993WK6.
2. Create a **Developer ID Application** certificate, either from that Accounts
   screen ("Manage Certificates", plus button) or in the Apple Developer portal.
3. Create an app-specific password at appleid.apple.com.
4. Save notarization credentials into the keychain:

```
xcrun notarytool store-credentials claude-usage-trend-tracker-notary \
  --apple-id <your-apple-id> \
  --team-id VP38993WK6 \
  --password <app-specific-password>
```

Then every release is:

```
SIGNING_IDENTITY="Developer ID Application" scripts/build-release.sh
```

That path exports through `ExportOptions-developer-id.plist`, submits to
`notarytool --wait`, staples the ticket, and writes the DMG. Set
`NOTARY_PROFILE` if the keychain profile is named something other than
`claude-usage-trend-tracker-notary`.
