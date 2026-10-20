# Quotacat — Design

Quotacat puts your GitHub quotas in the macOS menu bar: API rate limits, Actions minutes,
and Copilot AI Credits, each with a reset countdown and a pace projection.

## Inspiration

The interaction model is borrowed from
[Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) (MIT), a menu-bar
monitor for Claude plan limits. Quotacat shares no code with it. It adopts these ideas:

- Usage windows with a reset time, drawn as progress bars with a **time marker** showing how far
  through the window you are.
- **Pace projection**: once at least 3% of a window has elapsed, usage is extrapolated to the
  end of the window and colored in six tiers. The tier thresholds match Claude Usage Tracker's
  statusline script:

  | Projected at reset | Tier | Color |
  |---|---|---|
  | < 50% | Comfortable | green |
  | < 75% | On track | teal |
  | < 90% | Warming up | yellow |
  | < 100% | Pressing | orange |
  | < 120% | Will hit limit | red |
  | ≥ 120% | Runaway | purple |

- **Menu-bar icon styles** (progress bar, battery, percentage, text only), monochrome mode,
  "show remaining" mode, and short metric labels. Quotacat adds a **radial** style: a ring gauge
  per metric, filled clockwise from 12 o'clock, with the time marker as a tick across the ring.
  The same ring is available for the popover cards (Settings → Appearance → Popover), with the
  percentage inside the ring.
- A **refresh interval slider** from 10s to 300s, plus refreshes on wake from sleep and when the
  network returns, both debounced.
- **Threshold notifications** at 75%, 90% and 95%, deduplicated per window, plus a notice when a
  limit resets.
- **Reusing an existing CLI login** instead of asking for a new credential.

## Data sources

| Metric | Window | Endpoint |
|---|---|---|
| REST API rate limit | 1 hour | `GET /rate_limit` → `resources.core` |
| GraphQL API rate limit | 1 hour | `GET /rate_limit` → `resources.graphql` |
| Search API rate limit | 1 minute | `GET /rate_limit` → `resources.search` |
| Actions minutes | calendar month (UTC) | `GET /users/{user}/settings/billing/usage?year&month` |
| Copilot AI Credits | calendar month (UTC) | `GET /users/{user}/settings/billing/ai_credit/usage?year&month` |
| Copilot premium requests (annual plans) | calendar month (UTC) | `GET /users/{user}/settings/billing/premium_request/usage?year&month` |

- `/rate_limit` does not count against your rate limit, so frequent refreshes are free.
- The billing endpoints need a classic token with the **`user` scope**, and an account on
  GitHub's enhanced billing platform. Quotacat reads `X-OAuth-Scopes` from `/user`; if `user` is
  missing it skips those calls and shows how to add the scope instead of failing.
- **Actions minutes** are weighted the way GitHub bills them. The plan's allowance is in standard
  Linux minutes, and the usage report applies it as a dollar discount. So allowance used =
  sum of `discountAmount` on private-repository minute rows / the Linux per-minute price (0.006).
  macOS minutes (about 10× the price) and Windows (2×) are weighted automatically, larger runners
  (never covered by the allowance) don't count, and public repositories (free) are excluded using
  the repository list. Overage is the sum of `netAmount`. The breakdown and daily chart show
  Linux-equivalent minutes (`grossAmount` / Linux price).
- **Included minutes** come from the plan (`GET /user` → `plan.name`, visible with the `user`
  scope): Free 2,000, Pro 3,000, Team 3,000, Enterprise 50,000. Can be overridden in Settings.
- **Actions budget** (entered in Settings; personal budgets aren't in the REST API, only
  organization ones): spent = sum of `netAmount` for the Actions product (minutes and storage).
  Runway = remaining dollars / each runner type's per-minute price seen this period. Projection =
  spent + (net spend over the last 7 days / 7) × days left; if that crosses the budget before the
  reset, the card shows the approximate run-out date. Once included minutes are used up, the
  headline percentage, menu-bar meter, colors and alerts follow the budget.
- **Copilot** moved to usage-based billing on June 1, 2026: AI Credits, metered in dollars by
  tokens per model (Pro includes $10/month, Pro+ $39). Quotacat sums `grossAmount` from the AI
  credit endpoint, broken down by model. Annual plans keep premium requests until renewal, so if
  there is premium-request usage and no credit usage, it shows requests instead.

## Pull requests

One GraphQL request fetches two searches: `is:pr is:open archived:false review-requested:<login>`
(which includes team review requests) and `... author:<login>`, each sorted oldest first, 30 results
with total counts. That costs about one point of the 5,000/hour GraphQL budget instead of two calls
against the 30/minute search limit. The lists refresh at most every 2 minutes, or immediately on a
manual refresh. Review-request notifications are seeded on the first fetch, so only requests that
arrive while Quotacat is running notify. Counts are also written to the shell cache file.

## GitHub Actions

- Watched repositories: those the token can see (owner, collaborator, org member) that were pushed
  in the last 30 days, up to 20, or an explicit list from Settings → Activity. The repository list
  refreshes every 30 minutes.
- For each, `GET /repos/{repo}/actions/runs?branch={default}&status=completed&per_page=30`. A
  workflow is failing when its most recent completed run concluded `failure`, `timed_out` or
  `startup_failure`; a later success clears it, and cancelled runs don't count.
- Requests carry `If-None-Match` with the last ETag. A `304 Not Modified` doesn't count against
  the rate limit (verified), so steady-state polling every 2 minutes is close to free.
- Notifications fire when a workflow starts failing and when it recovers, seeded silently on the
  first check. The failing count goes in the shell cache file as `actionsFailing`.

## Credentials

1. The GitHub CLI login, via `gh auth token`. GUI apps don't inherit your shell `PATH`, so the
   usual install locations are probed directly.
2. A personal access token saved in the macOS Keychain from Settings → Account.

The token is only sent to `api.github.com`. Quotacat has no telemetry or analytics. The only request it makes beyond your own API calls is the
anonymous daily update check described below.

## Updates

- Releases are GitHub Releases with two assets: `Quotacat.zip` (always that name, so
  `releases/latest/download/Quotacat.zip` is a permanent download link) and `Quotacat.zip.sig`.
- The signature is Ed25519 over the zip bytes. The private key stays on the maintainer's Mac
  (`~/.config/quotacat/update-signing-key`); the public key is compiled into `Updater.swift`.
- The app checks `GET /repos/mrte1122/Quotacat/releases/latest` 15 seconds after launch and then
  at most once a day, unauthenticated. A newer version shows an Update button and one notification.
- Installing downloads both assets, verifies the signature, unzips with `ditto`, checks the bundle
  identifier, version and code signature, swaps the bundle in place with
  `FileManager.replaceItemAt`, and relaunches through a detached `open`. Any failure leaves the
  installed app untouched and links to the releases page.
- Releases are signed with a Developer ID (hardened runtime) and notarized, with the ticket
  stapled, so first downloads pass Gatekeeper. Once the running app has a Developer ID team, the
  updater also requires the new bundle to come from the same team.
- The bundle is assembled and signed in `$TMPDIR`, not the repo: iCloud-synced folders like
  `~/Documents` add extended attributes that codesign rejects.

## Usage levels

The percentage label and the bar (when pace coloring is off) use three levels:
safe below 60%, moderate below 85%, critical above that.

## Shell integration

Every refresh writes `~/Library/Application Support/Quotacat/usage.json` (login, update time, and
each metric's used, limit, percent and reset time), so a shell prompt can show usage without
calling the API.

## Architecture

A SwiftPM executable with no third-party dependencies, wrapped into an `.app` bundle by
`scripts/build-app.sh`. It uses AppKit's `NSStatusItem` and `NSPopover` rather than SwiftUI's
`MenuBarExtra`, because `MenuBarExtra` renders its label as a template image and would lose the
status colors.

```
Sources/Quotacat/
  Entry.swift          @main; CLI modes (--selftest, --once, --snapshot, --launch-at-login)
  App.swift            AppDelegate: status item, popover, settings window
  Models.swift         MetricKind, UsageMetric, breakdown/daily types, cache file format
  UsageMath.swift      fractions, elapsed time, pace tiers, usage levels, countdowns, self-tests
  Settings.swift       UserDefaults keys and defaults
  Credentials.swift    gh CLI token lookup, Keychain storage
  GitHubClient.swift   REST calls, decoding, scope detection
  UsageStore.swift     refresh coordinator: timer, wake/network triggers, cache file, demo data
  Notifier.swift       threshold and reset notifications with per-window dedup
  Theme.swift          status and pace colors
  MenuBarIcon.swift    NSImage renderer for the five icon styles
  PopoverView.swift    dashboard cards (bars or radial meters), banner, breakdowns, daily charts
  SettingsView.swift   General / Appearance / Account / Quotas tabs
  Snapshot.swift       offscreen renders of the popover and icons (README screenshots)
  PullRequests.swift   PR models, GraphQL fetch and decoding
  PullRequestsView.swift  the Pull requests tab
  Actions.swift        workflow-run models, failing-workflow rule, ETag-caching fetcher
  ActionsView.swift    the Actions tab
  Updater.swift        release check, signature verification, in-place install and relaunch

scripts/
  build-app.sh         universal build, icon packing, ad-hoc signing, --install / --zip
  release.sh           version bump, signed zip, tag, push, GitHub release
  sign-update.swift    Ed25519 key generation and signing
  make-icon.swift      fallback icon renderer; clean-icon.swift cuts out a generated icon
```
