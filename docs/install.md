# Installing Claude Meter

Claude Meter is a menu bar app that shows your Claude Code plan usage (the same
bars `/usage` shows) and warns you when your pace will hit a limit before it
resets.

## Install on this Mac

```
scripts/build-local.sh
```

That builds a Release app signed with the Apple Development certificate, copies
it to `/Applications/Claude Meter.app`, and launches it.

## First launch

1. **Keychain prompt** — "Claude Meter wants to use your confidential information
   stored in Claude Code-credentials". Click **Always Allow**. The app reads the
   sign-in token Claude Code already stores; it never writes to Keychain and never
   refreshes the token itself.
2. **Notifications prompt** — click **Allow** so pace and threshold alerts can show.
3. The menu bar item shows the weekly percent and a trend arrow within a few
   seconds. Click it for all buckets, the pace verdict, and settings.

## What it shows

| Row | Source |
| --- | --- |
| 5-hour session | `limits[kind=session]` |
| Week · all models | `limits[kind=weekly_all]` — also the menu bar number |
| Week · Fable | `limits[kind=weekly_scoped]` |
| Overage credits | `extra_usage` |

Projection is a straight line from the window start (reset minus 5h or 7d) to
now, extended to the reset.

## Notifications

- Over pace: once per bucket per window, re-arms if you drop back under pace.
- 75% and 90% crossings: once each per bucket per window.
- Weekly reset (on by default), 5-hour reset (off by default).
- Stale data for more than 2 hours: one reminder to open Claude Code so it
  refreshes the sign-in.

## If the numbers stop updating

Claude Code refreshes the sign-in token whenever it runs; the token lasts about
8 hours. If you have not used Claude Code for longer than that, Claude Meter
shows the last good reading with a yellow "stale" banner. Open any Claude Code
session and the next poll (every 5 minutes, or click Refresh) catches up.

## Debug switches

- `CLAUDE_METER_PACE_SCALE=5` — multiply percents before projecting, to force
  the over-pace notification for testing.

## Distribution to other Macs

Needs a Developer ID Application certificate and notarization credentials on
this Mac, which do not exist yet. See `docs/release.md`.
