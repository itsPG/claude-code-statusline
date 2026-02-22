# claude-code-statusline

**Know your Claude Code rate limits in real time.** No more guessing when your session or weekly quota resets — see your actual `/usage` data live in the status bar.

```
🌿 main │ 🤖 Sonnet 4.6 │ 🟢 Ctx ▓▓░░░░░░ 34% │ ⏳ 🟡 ▓▓▓░░░░░ 46% → 19h00 (3h20m) │ 📅 🟡 42% / Snt 🔴 59% ↻ mon 14h 🔄 5m
```

## Why?

Claude Code has rate limits but no built-in way to see them while you work. The `/usage` command exists, but you have to stop what you're doing to check it manually.

This script **automatically scrapes `/usage` in the background** and displays the results directly in your status line — session rate limit, weekly quota, reset countdown, all updated every 10 minutes.

## What you get

All three metrics use color-coded progress bars: 🟢 under 50% | 🟡 50-80% | 🔴 over 80%

| Segment | Example | Description |
|---------|---------|-------------|
| **Session** | `⏳ 🟡 ▓▓▓░░░░░ 46% → 19h00 (3h20m)` | Rate limit usage, reset time, countdown |
| **Weekly + Sonnet** | `📅 🟡 42% / Snt 🔴 59% ↻ mon 14h` | Weekly quota + Sonnet-specific quota, next reset |
| **Context** | `🟢 Ctx ▓▓░░░░░░ 34%` | Context window usage |
| **Refresh timer** | `🔄 5m` | Minutes until next `/usage` scrape |
| **Model** | `🤖 Sonnet 4.6` | Active Claude model |
| **Branch** | `🌿 main` | Current git branch |

## How it works

Every 10 minutes (configurable), the script silently launches a **background tmux session**, opens Claude Code, runs `/usage`, parses the output, and caches the result. Your active session is never interrupted — the scraping happens in a completely separate process.

The cached data (`~/.claude/usage-exact.json`) is then read on each status line render to display up-to-date rate limit info. Timezone is automatically extracted from the `/usage` output for correct display regardless of your server's location.

A 🔄 countdown shows minutes until the next scrape. When it switches to ⚠, cached data is stale and a refresh is pending.

The background scraper has a global 120-second timeout to prevent zombie tmux sessions from accumulating.

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.sh | bash
```

With custom refresh interval (e.g. every 5 minutes — minimum recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.sh | bash -s -- --refresh 300
```

### Manual

```bash
git clone https://github.com/ohugonnot/claude-code-statusline.git
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
- `bash`, `jq`, `tmux`, `python3`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed

## Configuration

Edit the top of `statusline.sh` or export in your shell profile:

| Variable | Default | Description |
|----------|---------|-------------|
| `TIMEZONE` | *(auto-detected)* | Override display timezone (e.g. `America/New_York`) |
| `REFRESH_INTERVAL` | `600` | Seconds between `/usage` scrapes |

## Testing

```bash
bash test_statusline.sh
```

## Troubleshooting

**Usage bars missing on first launch?**
Normal — the background scraper needs ~30 seconds to fetch data. Send a message and wait.

**Force a refresh:**
```bash
rm -f ~/.claude/usage-exact.json /tmp/claude-usage-refresh.lock
```

**Background scraper stuck:**
```bash
rm -f /tmp/claude-usage-refresh.lock
tmux kill-session -t claude-usage-bg 2>/dev/null
```

**Check cached data:**
```bash
cat ~/.claude/usage-exact.json | python3 -m json.tool
```

## Uninstall

```bash
rm -f ~/.claude/hooks/statusline.sh
rm -f ~/.claude/usage-exact.json
# Remove the "statusLine" key from ~/.claude/settings.json
```

## License

MIT
