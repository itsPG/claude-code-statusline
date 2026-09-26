# claude-code-statusline

**Know your Claude Code rate limits in real time.** No more guessing when your session or weekly quota resets — see your actual usage data live in the status bar.

```
Opus 4.6 │ 🟢 Ctx 42% │ ⏳ 🟡 35% ↻ 2h30m │ 📅 🔵 17% ↻ 2d │ $0.42 ⏱ 1h4m
```

## Why?

Claude Code has rate limits but no built-in way to see them while you work. The `/usage` command exists, but you have to stop what you're doing to check it manually.

This script reads your session and weekly rate limits from the status line input Claude Code already provides (Claude Code 2.1.80+, Pro/Max plans), **falls back to the usage API every 2 minutes** for anything that input doesn't cover, and displays the results directly in your status line — rate limits with reset countdowns, all at a glance.

## What you get

Color-coded indicators: 🔵 under 20% │ 🟢 20-50% │ 🟡 50-70% │ 🟠 70-85% │ 🔴 85% and above

For **1M/2M context windows**, thresholds are stricter: 🔵 <12% │ 🟢 <29% │ 🟡 <41% │ 🟠 <50% │ 🔴 50-69% │ 🟣 >=70%

| Segment | Example | Description |
|---------|---------|-------------|
| **Model** | `Opus 4.6` | Active model. With effort set: `Opus 4.6/mx` |
| **Context** | `🟢 Ctx 42%` | Context window fill. Shows `1M`/`2M` for large context (with stricter color thresholds) |
| **Session** | `⏳ 🟡 35% ↻ 2h30m` | 5-hour session quota + countdown to reset |
| **Weekly** | `📅 🔵 17% ↻ 2d` | 7-day all-models quota + countdown to reset |
| **Fable** | `🔮 🟢 24%` | 7-day Fable quota, opt-in with `SHOW_FABLE=1`. Shares the weekly reset, so it shows its own countdown only when the 📅 segment is hidden |
| **Extra** | `💳 🟢 20% $4.10/$20` | Pay-as-you-go extra usage — opt-in with `SHOW_EXTRA=1`, and only shown when enabled on your account |
| **Cost** | `$0.42 ⏱ 1h4m` | Claude Code's client-side session cost estimate at list price (not your bill, not extra usage) + session duration |

## How it works

```
Claude Code → JSON stdin → statusline.sh → formatted status string
                              ↓ (only if needed and cache > 120s old)
                         curl → Anthropic OAuth API → ~/.claude/usage-exact-acct-<hash>.json
```

Session (5h) and weekly (7d) usage come from the `rate_limits` field Claude Code passes on stdin whenever it is present — always current, no network call. That field exists only on claude.ai Pro/Max plans, only after the first API response of a session, and each window may be absent independently.

The usage API is called (at most every 2 minutes, configurable) only when something shown isn't covered by stdin: a missing `rate_limits` window, the Fable weekly quota (opt-in `SHOW_FABLE=1`, API-only), or extra usage (opt-in `SHOW_EXTRA=1`, API-only). With the defaults and both windows on stdin, no API call is made at all, and the usage segments update on every status line render instead of every 2 minutes. The call takes ~200ms and runs inline — no background processes, no tmux, no scraping.

The OAuth token is read from `~/.claude/.credentials.json`, or on macOS from the Keychain entry `Claude Code-credentials` when that file doesn't exist — both are maintained by Claude Code. If the token is expired or the API is unreachable, the script silently falls back to cached data or displays without usage info.

### About the Usage API

The script uses `https://api.anthropic.com/api/oauth/usage`, an **undocumented** Anthropic endpoint discovered by the community. It returns session (5h) and weekly (7d) quota utilization as percentages with ISO 8601 reset timestamps, plus a `limits[]` list that includes per-model weekly quotas such as Fable (the only place the Fable quota appears — it isn't on Claude Code's stdin).

This is not an official API — it could change without notice. There's an open feature request for official programmatic access: [anthropics/claude-code#13585](https://github.com/anthropics/claude-code/issues/13585).

If Anthropic removes this endpoint, the script degrades gracefully: model, context, cost, and the stdin-provided session/weekly usage keep working — only Fable and extra usage disappear.

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/itsPG/claude-code-statusline/main/install.sh | bash
```

With a custom API refresh interval (e.g. every 5 minutes; default 120s):

```bash
curl -fsSL https://raw.githubusercontent.com/itsPG/claude-code-statusline/main/install.sh | bash -s -- --refresh 300
```

### Manual

```bash
git clone https://github.com/itsPG/claude-code-statusline.git
cd claude-code-statusline
bash install.sh
```

### Fully manual

```bash
mkdir -p ~/.claude/hooks
cp statusline.sh ~/.claude/hooks/statusline.sh
chmod +x ~/.claude/hooks/statusline.sh

# Add this key to ~/.claude/settings.json:
# "statusLine": { "type": "command", "command": "bash ~/.claude/hooks/statusline.sh" }
```

## Requirements

- Linux, WSL, or macOS
- `bash`, `jq`, `curl` (no tmux, no python)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed

> **Migrating from v1?** The old tmux+python scraper is no longer needed. Run `install.sh` to upgrade — it will clean up old tmux sessions and lock files automatically.

## Configuration

Set variables in the `statusLine` command in `~/.claude/settings.json`, e.g.

```json
{"statusLine": {"type": "command", "command": "SHOW_FABLE=1 bash ~/.claude/hooks/statusline.sh"}}
```

or export them in the environment Claude Code is started from, or edit the defaults at the top of `~/.claude/hooks/statusline.sh`. Note that re-running `install.sh` resets both the `statusLine` command and the installed script.

| Variable | Default | Description |
|----------|---------|-------------|
| `REFRESH_INTERVAL` | `120` | Seconds between API calls — **do not set to 0** (causes rate limiting) |
| `SHOW_WEEKLY` | `1` | Set to `0` to hide weekly quota |
| `SHOW_FABLE` | `0` | Set to `1` to show the Fable weekly quota (🔮) after the weekly one. Only the usage API has it (not Claude Code's stdin), so it costs an API call every `REFRESH_INTERVAL` |
| `SHOW_EXTRA` | `0` | Set to `1` to show extra usage (pay-as-you-go). Costs an API call every `REFRESH_INTERVAL` |
| `TIMEZONE` | *(system default)* | Override display timezone (e.g. `America/New_York`) |
| `USAGE_FILE` | `~/.claude/usage-exact.json` | Cache file base path (auto-suffixed with `-acct-<hash>` of your account + organization ID) |
| `CREDENTIALS_FILE` | `~/.claude/.credentials.json` | OAuth credentials path |
| `ACCOUNT_FILE` | `~/.claude.json` | Claude Code state file whose `oauthAccount` account/organization IDs key the cache |
| `SETTINGS_FILE` | `~/.claude/settings.json` | Read for `effortLevel` when Claude Code doesn't send `effort.level` |

## Testing

```bash
bash test_statusline.sh
bash test_install.sh
```

## Troubleshooting

**⚠ in place of the session color dot?**
The session value came from the API cache and the cache is older than 3× `REFRESH_INTERVAL`. It never appears when the session value comes from Claude Code's stdin. The Fable quota (always from the cache) gets the same ⚠ when the cache is that old.

**Usage display frozen / not updating?**
You may have been rate-limited by the Anthropic API (e.g. `REFRESH_INTERVAL` was too low or set to `0`). Wait a few minutes, then test the API directly — a `rate_limit_error` response confirms it. Once the rate limit clears, the statusline resumes auto-updating.

> **Multiple Claude Code windows?** All windows logged into the same account share the same cache file (`~/.claude/usage-exact-acct-<hash>.json`). Whichever window renders first once the cache is older than `REFRESH_INTERVAL` will call the API and refresh the cache for all others. You won't get multiple simultaneous API calls from the same machine.

**Usage segments missing?**
Session/weekly come from Claude Code's stdin on Pro/Max plans, but only after the first API response of a session. Before that (and for Fable / extra usage), the script needs an OAuth token: check that `~/.claude/.credentials.json` — or on macOS the Keychain entry `Claude Code-credentials` — contains `claudeAiOauth.accessToken`. Claude Code creates it when you log in. `bash debug_statusline.sh` checks all of this.

**Force a refresh:**
```bash
rm -f ~/.claude/usage-exact*.json
```

**Check cached data:**
```bash
jq . ~/.claude/usage-exact-acct-*.json
```

**Hundreds of `usage-exact-<8 hex>.json` files in `~/.claude`?**
Older versions keyed the cache on the OAuth access token, which rotates. Re-run `install.sh` to delete them; the cache is now keyed on your account.

**Test the API directly:**
```bash
TOKEN=$(jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)
# macOS without that file:
# TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w | jq -r '.claudeAiOauth.accessToken')
curl -s "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "User-Agent: claude-code/$(claude --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
  -H "anthropic-beta: oauth-2025-04-20" | jq .
```

**Migrating from v1 (tmux scraper)?**
Run `install.sh` — it cleans up old artifacts automatically. Or manually:
```bash
rm -f /tmp/claude-usage-refresh.lock /tmp/.claude-usage-scraper.sh
tmux kill-session -t claude-usage-bg 2>/dev/null
```

## Uninstall

```bash
rm -f ~/.claude/hooks/statusline.sh
rm -f ~/.claude/usage-exact*.json
# Remove the "statusLine" key from ~/.claude/settings.json
```

## Acknowledgements

Forked from [ohugonnot/claude-code-statusline](https://github.com/ohugonnot/claude-code-statusline). Changes in this fork:

- Removed git branch segment and progress bar graphics for a cleaner display
- Added 5-level color coding (🔵🟢🟡🟠🔴) instead of 3
- Stricter color thresholds for 1M/2M context windows, with 🟣 (purple) at >=70%
- Displays context window size label (`1M`/`2M`) when larger than 200k
- Weekly quota shown by default (`SHOW_WEEKLY=1`)
- Shorter default refresh interval (120s instead of 300s)
- Per-account usage cache (supports switching between Anthropic accounts), keyed on account + organization ID
- Optional Fable weekly quota segment (🔮, `SHOW_FABLE=1`)
- Extra usage (pay-as-you-go) segment, opt-in via `SHOW_EXTRA=1`
- Reads OAuth credentials from the macOS Keychain when `~/.claude/.credentials.json` is absent
- Effort label from Claude Code's stdin `effort.level` (incl. `xhigh`), falling back to `settings.json`

## License

MIT — see [LICENSE](LICENSE).
