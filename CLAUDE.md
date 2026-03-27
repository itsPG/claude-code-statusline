# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Real-time status line for Claude Code that displays rate limit usage in the IDE status bar. Fetches usage data via the Anthropic OAuth API every 60 seconds, caches results to JSON, and renders color-coded progress bars.

**Stack**: Bash, jq, curl. No build step, no external test framework.

## Commands

```bash
# Run tests
bash test_statusline.sh

# Manual test (pipe JSON to statusline)
echo '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":42}}' | bash statusline.sh

# Install locally
bash install.sh
bash install.sh --refresh 120  # custom interval
```

## Architecture

Three files, single-purpose each:

- **statusline.sh** (core) — Claude Code status line hook. Reads JSON from stdin (model, context_window, workspace), outputs a formatted status string. Refreshes usage data via API when cache is stale.
- **install.sh** — Copies `statusline.sh` to `~/.claude/hooks/`, updates `~/.claude/settings.json`, checks/installs dependencies, cleans up old tmux scraper artifacts.
- **test_statusline.sh** — Unit + integration tests with simple assert helpers (`assert_eq`, `assert_contains`, `assert_not_contains`).

### Data Flow

```
Claude Code → JSON stdin → statusline.sh → formatted status string
                              ↓ (if cache > 60s old)
                         curl → api.anthropic.com/api/oauth/usage → ~/.claude/usage-exact.json
```

### Key Design Decisions

- **Inline API call**: Usage data is fetched via a single `curl` call (~200ms) — no background processes, no tmux, no python. Fast enough to run inline on every status line render when cache is stale.
- **Atomic cache writes**: Uses `tmp + mv` to prevent partial reads of the cache file.
- **Backward compatible**: Reads both the old tmux-scraped cache format (`resets` text) and the new API format (`resets_at` ISO 8601).
- **Cross-platform**: GNU stat (Linux) vs BSD stat (macOS) detection in `file_mtime()`. Avoids `grep -P` (not available on macOS).
- **Graceful degradation**: If the API call fails (expired token, network issue, endpoint removed), the script silently falls back to cached data or displays without usage info.

### Usage API

The script uses `https://api.anthropic.com/api/oauth/usage`, an undocumented Anthropic endpoint. Authentication is via Bearer token from `~/.claude/.credentials.json` (maintained by Claude Code). The endpoint returns:

```json
{
  "five_hour": { "utilization": 18.0, "resets_at": "2026-03-27T10:00:00+00:00" },
  "seven_day": { "utilization": 17.0, "resets_at": "2026-04-02T13:00:00+00:00" },
  "seven_day_sonnet": { "utilization": 10.0, "resets_at": "2026-04-02T13:00:00+00:00" }
}
```

Tracked upstream: [anthropics/claude-code#13585](https://github.com/anthropics/claude-code/issues/13585)

### Configuration (env vars)

| Variable | Default | Notes |
|----------|---------|-------|
| `TIMEZONE` | system | Override for display (e.g. `America/New_York`) |
| `REFRESH_INTERVAL` | `60` | Seconds between API calls |
| `SHOW_WEEKLY` | `0` | Set to `1` to show weekly + Sonnet quotas |
| `USAGE_FILE` | `~/.claude/usage-exact.json` | Cache location |
| `CREDENTIALS_FILE` | `~/.claude/.credentials.json` | OAuth token source |

## Testing Patterns

Tests extract `make_bar()` via awk and eval it for unit testing. Integration tests pipe JSON through `statusline.sh` with overridden env vars (`USAGE_FILE`, `REFRESH_INTERVAL`, `CREDENTIALS_FILE=/dev/null`) to control behavior without triggering the real API. Temp files are tracked in `TMPFILES` array and cleaned via trap.

To add a test: create a temp JSON cache file, use `run_statusline` helper with appropriate env overrides, assert on stdout.
