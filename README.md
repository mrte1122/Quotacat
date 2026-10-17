<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Quotacat icon">
</p>

<h1 align="center">Quotacat</h1>

<p align="center">
  Your GitHub quotas in the macOS menu bar: API rate limits, Actions minutes, and Copilot premium requests.
</p>

<p align="center">
  <img src="docs/menubar-dark.png" height="28" alt="Menu bar icon">
</p>

<p align="center">
  <img src="docs/popover-dark.png" width="360" alt="Quotacat popover in dark mode">
  &nbsp;
  <img src="docs/popover-light.png" width="360" alt="Quotacat popover in light mode">
</p>

## What it shows

| Metric | Resets |
|---|---|
| REST API rate limit | hourly |
| GraphQL API rate limit | hourly |
| Search API rate limit | every minute |
| Actions minutes, by repository | monthly (UTC) |
| Copilot premium requests, by model | monthly (UTC) |

Each bar has a **time marker** for how far through the window you are, and a **pace projection**
that estimates where you'll be at reset: green when comfortable, through orange and red, to purple
when you're far ahead of your quota.

Also included:

- Four menu-bar styles (progress bar, battery, percentage, text only), monochrome mode, and a
  "show remaining" option
- Notifications at 75%, 90% and 95%, and when a limit resets
- A refresh interval from 10 seconds to 5 minutes, plus refreshes on wake and when the network returns
- Daily usage charts for the month
- Launch at login
- A JSON cache file for shell prompts

## Install

Requires macOS 14 or later and the Swift toolchain (Xcode or just the Command Line Tools:
`xcode-select --install`).

```bash
git clone https://github.com/mrte1122/Quotacat.git
cd Quotacat
./scripts/build-app.sh --install
open ~/Applications/Quotacat.app
```

The build is universal (Apple silicon and Intel) and ad-hoc signed.

> **Downloading a prebuilt release instead?** Releases aren't notarized by Apple, so macOS will
> say the app "can't be opened". Right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/Quotacat.app`.

## Sign in

Quotacat reuses your [GitHub CLI](https://cli.github.com) login, so if `gh auth status` works,
you're done. Alternatively, paste a personal access token in **Settings → Account**; it's stored
in the macOS Keychain.

Rate limits work with any token. **Actions minutes and Copilot premium requests** come from
GitHub's billing API, which needs the `user` scope:

```bash
gh auth refresh -h github.com -s user
```

GitHub doesn't tell the app your plan, so set your included Actions minutes and Copilot requests
in **Settings → Quotas**.

## Privacy

- Your token is only sent to `api.github.com`.
- There is no telemetry, analytics, or update check.
- Usage data stays on your Mac, in `~/Library/Application Support/Quotacat/usage.json`.

## Shell prompt

Each refresh writes the cache file above, so a prompt can show usage without calling the API:

```bash
jq -r '.metrics[] | select(.kind=="core") | "gh \(.percent)%"' \
  ~/Library/Application\ Support/Quotacat/usage.json
```

## Command-line modes

```bash
Q=~/Applications/Quotacat.app/Contents/MacOS/Quotacat
$Q --selftest                 # run the pace and countdown math checks
$Q --once                     # fetch once and print a summary (never prints your token)
$Q --snapshot DIR [--demo]    # render the popover and icons to PNGs; --demo uses sample data
$Q --launch-at-login on|off   # same as the Settings toggle
```

## Design

See [DESIGN.md](DESIGN.md) for the data sources, pace math, and architecture. The interaction model
is inspired by [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker).

## License

[MIT](LICENSE). Quotacat is an independent project and is not affiliated with or endorsed by
GitHub, Inc. "GitHub" and "Copilot" are trademarks of GitHub, Inc.
