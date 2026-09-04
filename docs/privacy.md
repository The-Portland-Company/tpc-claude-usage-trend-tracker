# Privacy Policy — Claude Usage Trend Tracker

Effective 2026-09-04. Published by The Portland Company.

Claude Usage Trend Tracker is a macOS menu bar app that shows your Claude Code
plan usage and projects whether your current pace will exhaust a limit before
it resets.

## What the app reads

- **Your Claude Code sign-in token**, read from the macOS Keychain item that
  Claude Code itself creates ("Claude Code-credentials"). The app only reads
  this item. It never writes to Keychain and never refreshes or changes the
  token.
- **Your usage numbers**, fetched from Anthropic's usage endpoint using that
  token, every five minutes or when you click Refresh.

## What the app stores

- The most recent usage readings, kept in the app's own Application Support
  folder on your Mac so the trend and pace projection survive a relaunch.
- Your notification and launch-at-login preferences, in the app's own
  preferences on your Mac.

## What the app sends

- The only network request the app makes is to Anthropic's usage endpoint,
  authenticated with your own Claude Code token, to fetch your own usage.
- The app has no analytics, no crash reporting, no advertising, and no
  servers of its own. Nothing is sent to The Portland Company or to any
  third party.

## Data sharing and sale

The app does not collect, share, or sell personal data. The Portland Company
never receives any data from the app.

## Deleting your data

Quit the app and delete it. Remove
`~/Library/Application Support/Claude Usage Trend Tracker` and the app's
preferences file (`com.theportlandcompany.ClaudeMeter`) if you want the cached
readings gone too.

## Contact

Questions: open an issue on the support page,
https://github.com/The-Portland-Company/tpc-claude-usage-trend-tracker/issues,
or email spencerdhill@protonmail.com.
