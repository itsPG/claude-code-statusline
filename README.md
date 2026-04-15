# claude-code-statusline

**Know your Claude Code rate limits in real time.** No more guessing when your session or weekly quota resets — see your actual usage data live in the status bar.

```
Opus 4.6 │ 🟢 Ctx 42% │ ⏳ 🟡 35% ↻ 2h30m │ 📅 🔵 17% ↻ 2d │ 💳 🟢 20% $4.10/$20 │ $0.42 ⏱ 1h4m
```

## Why?

Claude Code has rate limits but no built-in way to see them while you work. The `/usage` command exists, but you have to stop what you're doing to check it manually.

This script **fetches your usage via API every 2 minutes** and displays the results directly in your status line — session and weekly rate limits with reset countdowns, all at a glance.

## What you get

Color-coded indicators: 🔵 under 20% │ 🟢 20-50% │ 🟡 50-70% │ 🟠 70-85% │ 🔴 over 85%

For **1M/2M context windows**, thresholds are stricter: 🔵 <12% │ 🟢 <29% │ 🟡 <41% │ 🟠 <50% │ 🔴 50-69% │ 🟣 >=70%

| Segment | Example | Description |
|---------|---------|-------------|
| **Model** | `Opus 4.6` | Active model. With effort set: `Opus 4.6/mx` |
| **Context** | `🟢 Ctx 42%` | Context window fill. Shows `1M`/`2M` for large context (with stricter color thresholds) |
| **Session** | `⏳ 🟡 35% ↻ 2h30m` | 5-hour session quota + countdown to reset |
| **Weekly** | `📅 🔵 17% ↻ 2d` | 7-day all-models quota + countdown to reset |
| **Extra** | `💳 🟢 20% $4.10/$20` | Pay-as-you-go extra usage (only shown when enabled on your account) |
| **Cost** | `$0.42 ⏱ 1h4m` | Session cost + wall-clock duration |

## How it works

```
Claude Code → JSON stdin → statusline.sh → formatted status string
                              ↓ (if cache > 120s old)
                         curl → Anthropic OAuth API → ~/.claude/usage-exact.json
```

Every 2 minutes (configurable), the script calls the Anthropic usage API with your OAuth token. The call takes ~200ms and runs inline — no background processes, no tmux, no scraping.

The OAuth token is read from `~/.claude/.credentials.json`, which Claude Code maintains automatically during active sessions. If the token is expired or the API is unreachable, the script silently falls back to cached data or displays without usage info.

### About the Usage API

The script uses `https://api.anthropic.com/api/oauth/usage`, an **undocumented** Anthropic endpoint discovered by the community. It returns session (5h) and weekly (7d) quota utilization as percentages with ISO 8601 reset timestamps.

This is not an official API — it could change without notice. There's an open feature request for official programmatic access: [anthropics/claude-code#13585](https://github.com/anthropics/claude-code/issues/13585).

If Anthropic removes this endpoint, the script degrades gracefully: you still get git, model, and context info — just no usage bars.

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/itsPG/claude-code-statusline/main/install.sh | bash
```

With custom refresh interval (e.g. every 2 minutes):

```bash
curl -fsSL https://raw.githubusercontent.com/itsPG/claude-code-statusline/main/install.sh | bash -s -- --refresh 120
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

Export in your shell profile or edit the top of `statusline.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `REFRESH_INTERVAL` | `120` | Seconds between API calls — **do not set to 0** (causes rate limiting) |
| `SHOW_WEEKLY` | `1` | Set to `0` to hide weekly quota |
| `SHOW_EXTRA` | `1` | Set to `0` to hide extra usage (pay-as-you-go) |
| `TIMEZONE` | *(system default)* | Override display timezone (e.g. `America/New_York`) |
| `USAGE_FILE` | `~/.claude/usage-exact.json` | Cache file base path (auto-suffixed with account hash) |
| `CREDENTIALS_FILE` | `~/.claude/.credentials.json` | OAuth credentials path |

## Testing

```bash
bash test_statusline.sh
```

## Troubleshooting

**Usage display frozen / not updating?**
You may have been rate-limited by the Anthropic API (e.g. `REFRESH_INTERVAL` was too low or set to `0`). Wait a few minutes, then test the API directly — a `rate_limit_error` response confirms it. Once the rate limit clears, the statusline resumes auto-updating.

> **Multiple Claude Code windows?** All windows share the same cache file (`~/.claude/usage-exact.json`). Whichever window renders first past the 60s mark will call the API and refresh the cache for all others. You won't get multiple simultaneous API calls from the same machine.

**Usage bars missing?**
Check that `~/.claude/.credentials.json` exists and contains a valid `claudeAiOauth.accessToken`. This file is created automatically when you log into Claude Code.

**Force a refresh:**
```bash
rm -f ~/.claude/usage-exact.json
```

**Check cached data:**
```bash
cat ~/.claude/usage-exact.json | jq .
```

**Test the API directly:**
```bash
TOKEN=$(jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)
curl -s "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
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
rm -f ~/.claude/usage-exact.json
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
- Per-account usage cache (supports switching between Anthropic accounts)
- Installer prompts before downloading from GitHub when local file is not found

## License

MIT
