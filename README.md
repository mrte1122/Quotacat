<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Quotacat icon">
</p>

<h1 align="center">Quotacat</h1>

<p align="center">
  Your GitHub quotas in the macOS menu bar: API rate limits, Actions minutes, and Copilot premium requests.
</p>

<p align="center">
  <a href="https://ko-fi.com/mrte90"><img src="https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=ko-fi&logoColor=white" alt="Support on Ko-fi"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license">
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

- Five menu-bar styles (progress bar, battery, radial, percentage, text only), monochrome mode,
  and a "show remaining" option
- Popover meters as horizontal bars or radial rings
- Notifications at 75%, 90% and 95%, and when a limit resets
- A refresh interval from 10 seconds to 5 minutes, plus refreshes on wake and when the network returns
- Daily usage charts for the month
- Launch at login
- A JSON cache file for shell prompts

## Download

**[⬇ Download Quotacat for macOS](https://github.com/mrte1122/Quotacat/releases/latest/download/Quotacat.zip)**
(macOS 14 or later, Apple silicon and Intel)

1. Unzip it and drag **Quotacat.app** into **Applications**.
2. Open it. Quotacat isn't notarized by Apple yet, so the first launch is blocked with a
   warning. Go to **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway**. Or run `xattr -dr com.apple.quarantine /Applications/Quotacat.app`.
3. Look for the gauges in your menu bar. Quotacat has no Dock icon.

You only need to do step 2 once; updates install without it.

## Updates

Quotacat checks GitHub for a new release once a day and shows an **Update** button in the
popover when one is available. Updates are signed: each release ships an Ed25519 signature, and
the app refuses any download that doesn't match the key built into it. You can also check from
**Settings → General → Check for Updates**, or turn automatic checks off.

## Build from source

Requires the Swift toolchain (Xcode, or just the Command Line Tools: `xcode-select --install`).

```bash
git clone https://github.com/mrte1122/Quotacat.git
cd Quotacat
./scripts/build-app.sh --install
open ~/Applications/Quotacat.app
```

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
- The daily update check is an anonymous request for this repo's latest release; no token or
  identifier is sent, and you can turn it off in Settings.
- There is no telemetry or analytics.
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
$Q --check-update             # print the latest release version
$Q --update                   # download, verify, and install the latest release
```

## Releasing (maintainers)

```bash
swift scripts/sign-update.swift keygen   # once; the key lives in ~/.config/quotacat, never in the repo
./scripts/release.sh 1.2.0 "What changed"
```

`release.sh` bumps `VERSION`, builds the universal app, signs `Quotacat.zip`, tags, pushes, and
creates the GitHub release.

## Design

See [DESIGN.md](DESIGN.md) for the data sources, pace math, and architecture. The interaction model
is inspired by [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker).

## Support

Quotacat is free. If it's useful to you, you can [buy me a coffee on Ko-fi](https://ko-fi.com/mrte90) ☕️
Bug reports and pull requests are welcome too.

## License

[MIT](LICENSE). Quotacat is an independent project and is not affiliated with or endorsed by
GitHub, Inc. "GitHub" and "Copilot" are trademarks of GitHub, Inc.
