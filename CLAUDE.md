# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Real-time status line for Claude Code that displays rate limit usage, session cost, model, effort, and context window in the status bar. Session/weekly usage comes from Claude Code's native stdin `rate_limits` when present; the Anthropic OAuth usage API (cached to JSON) fills anything stdin lacks, including extra usage. Renders color-coded indicators.

**Stack**: Bash, jq, curl. No build step, no external test framework.

## Commands

```bash
# Run tests
bash test_statusline.sh
bash test_install.sh   # installer, against a fake $HOME

# Manual test (pipe JSON to statusline)
echo '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":42}}' | bash statusline.sh

# Install locally
bash install.sh
bash install.sh --refresh 120  # custom interval
```

## Architecture

Single-purpose files:

- **statusline.sh** (core) — Claude Code status line hook. Reads JSON from stdin (model, context_window, cost, effort, rate_limits), outputs a formatted status string. Refreshes usage data via API only when needed and the cache is stale.
- **install.sh** — Copies `statusline.sh` to `~/.claude/hooks/`, updates `~/.claude/settings.json`, checks/installs dependencies, cleans up old tmux scraper artifacts.
- **test_statusline.sh** — Unit + integration tests with simple assert helpers (`assert_eq`, `assert_contains`, `assert_not_contains`, `assert_absent`).
- **test_install.sh** — Runs `install.sh` against a temp `$HOME` (fresh install, merge, invalid JSON, `--refresh` validation).
- **debug_statusline.sh** — Diagnostic script for a user's local setup.

### Data Flow

```
Claude Code → JSON stdin → statusline.sh → formatted status string
                              ↓ (if NEED_API and cache > REFRESH_INTERVAL old)
                         curl → api.anthropic.com/api/oauth/usage → ~/.claude/usage-exact-acct-<hash>.json
```

- **Native stdin first**: `rate_limits.five_hour` / `.seven_day` (Claude Code ≥ 2.1.80, Pro/Max only, present only after the first API response; each window may be absent; `resets_at` is Unix epoch seconds) are preferred over the cache, per window.
- **`NEED_API`**: the API is skipped only when stdin has `five_hour`, has `seven_day` (or `SHOW_WEEKLY≠1`), `SHOW_EXTRA≠1`, and `SHOW_FABLE≠1` — extra usage and the Fable weekly quota are API-only.
- **Per-account cache**: `<hash>` = first 8 hex of sha256(`accountUuid:organizationUuid`) from `~/.claude.json` → `.oauthAccount`, not the access token (tokens rotate; the old token-keyed `usage-exact-<8 hex>.json` files are orphans that `install.sh` deletes). No token or no `accountUuid` → the unsuffixed base path. Assumes Claude Code updates `oauthAccount` on `/login` account switches (not verified).
- **Stale ⚠** (cache older than 3× `REFRESH_INTERVAL`): on the session dot only when the session came from the cache; on the Fable dot always (Fable is cache-only). A past `resets_at` zeroes session and Fable.

### Key Design Decisions

- **Inline API call**: Usage data is fetched via a single `curl` call (~200ms) — no background processes, no tmux, no python. Fast enough to run inline on every status line render when cache is stale.
- **Untrusted input**: stdin/cache values reach bash arithmetic only through `num()` (blocks `x[$(cmd)]` array-subscript injection). jq stringifies every field, strips `[[:cntrl:]]` (C0 incl. US/newline, DEL, C1), and joins on US (0x1f) — so free text can't shift later fields or inject terminal escapes.
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
  "seven_day_sonnet": { "utilization": 10.0, "resets_at": "2026-04-02T13:00:00+00:00" },
  "extra_usage": { "is_enabled": true, "monthly_limit": 2000, "used_credits": 410.0, "utilization": 20.5 },
  "limits": [
    { "kind": "weekly_scoped", "group": "weekly", "percent": 24, "resets_at": "2026-10-01T07:59:59.611481+00:00",
      "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } }
  ]
}
```

Observed 2026-09-26: per-model weekly quotas are **not** in `seven_day_*` (`seven_day_opus` / `seven_day_sonnet` were `null`) and not on stdin `rate_limits`; the Fable quota exists only as the `limits[]` entry above (`model.id` is `null`, so match on `display_name`). `limits[]` also repeats `session` / `weekly_all`.

Tracked upstream: [anthropics/claude-code#13585](https://github.com/anthropics/claude-code/issues/13585)

### Configuration (env vars)

| Variable | Default | Notes |
|----------|---------|-------|
| `TIMEZONE` | system | Override for display (e.g. `America/New_York`) |
| `REFRESH_INTERVAL` | `120` | Seconds between API calls — do not set to 0 (rate limiting) |
| `SHOW_WEEKLY` | `1` | Set to `0` to hide weekly quota |
| `SHOW_EXTRA` | `0` | Set to `1` to show extra usage (pay-as-you-go). Off by default so session/weekly come purely from stdin with no API calls |
| `SHOW_FABLE` | `0` | Set to `1` to show the Fable weekly quota as a `🔮` segment after `📅` (API-only; countdown only when `📅` is hidden) |
| `USAGE_FILE` | `~/.claude/usage-exact.json` | Cache base path (suffixed `-acct-<hash>`) |
| `ACCOUNT_FILE` | `~/.claude.json` | Source of `oauthAccount.accountUuid` / `organizationUuid` for the cache key |
| `CREDENTIALS_FILE` | `~/.claude/.credentials.json` | OAuth token source |
| `SETTINGS_FILE` | `~/.claude/settings.json` | `effortLevel` fallback when stdin has no `effort.level` |

## Testing Patterns

Tests extract `num()` and `make_bar()` via awk and eval them for unit testing (sourcing the whole helper section would hit the macOS Keychain lookup). Integration tests pipe JSON through `statusline.sh` with overridden env vars (`USAGE_FILE`, `REFRESH_INTERVAL`, `CREDENTIALS_FILE=/dev/null`) to control behavior without triggering the real API. Temp files are tracked in `TMPFILES` array and cleaned via trap.

To add a test: create a temp JSON cache file, use `run_statusline` helper with appropriate env overrides, assert on stdout. `run_statusline` defaults `SETTINGS_FILE=/dev/null` and a temp `XDG_RUNTIME_DIR` so tests never read or write the real `~/.claude`. The suites call `bash` from `PATH`; to test macOS bash 3.2, prepend a dir with a `bash → /bin/bash` symlink.

API-call gating is tested with a fake `curl` / `claude` prepended to `PATH` that touches a marker file (see `run_gated`).
