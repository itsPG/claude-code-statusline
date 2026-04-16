#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# Claude Code Statusline — Diagnostic Script
#
# Usage: bash debug_statusline.sh
# ════════════════════════════════════════════════════════════════════════════

CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
USAGE_FILE_BASE="${USAGE_FILE:-$HOME/.claude/usage-exact.json}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-120}"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_FILE="$HOME/.claude/hooks/statusline.sh"

# ── ANSI colors ───────────────────────────────────────────────────────────────
R=$'\e[0m'
BOLD=$'\e[1m'
GREEN=$'\e[32m'
RED=$'\e[31m'
YELLOW=$'\e[33m'
DIM=$'\e[2m'

ISSUES=0

ok()   { printf "  ${GREEN}✓${R}  %-28s %s\n" "$1" "$2"; }
fail() { printf "  ${RED}✗${R}  %-28s ${RED}%s${R}\n" "$1" "$2"; (( ISSUES++ )); }
warn() { printf "  ${YELLOW}~${R}  %-28s ${YELLOW}%s${R}\n" "$1" "$2"; }
skip() { printf "  ${DIM}-${R}  %-28s ${DIM}%s${R}\n" "$1" "$2"; }
info() { printf "      ${DIM}%s${R}\n" "$1"; }

section() { printf "\n${BOLD}[%s]${R}\n" "$1"; }

# ── Header ────────────────────────────────────────────────────────────────────
echo "${BOLD}=== Claude Code Statusline Debug ===${R}"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Script: $0"

# ════════════════════════════════════════════════════════════════════════════
section "DEPS"
# ════════════════════════════════════════════════════════════════════════════

# jq
if command -v jq &>/dev/null; then
    ok "jq" "$(jq --version 2>/dev/null)"
else
    fail "jq" "not found — required for JSON parsing"
fi

# curl
if command -v curl &>/dev/null; then
    _curl_ver=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
    ok "curl" "$_curl_ver"
else
    fail "curl" "not found — required for API calls"
fi

# bc
if command -v bc &>/dev/null; then
    ok "bc" "present (extra usage dollar formatting)"
else
    warn "bc" "not found — extra usage dollar amounts will be blank"
fi

# sha256sum / shasum
if command -v sha256sum &>/dev/null; then
    ok "sha256sum" "found (GNU coreutils)"
elif command -v shasum &>/dev/null; then
    ok "shasum" "found (macOS — used as sha256sum fallback)"
else
    fail "sha256sum / shasum" "not found — per-account cache disabled"
fi

# flock
if command -v flock &>/dev/null; then
    ok "flock" "present"
else
    warn "flock" "not found (macOS) — using fallback lock (minor race window)"
fi

# ════════════════════════════════════════════════════════════════════════════
section "AUTH"
# ════════════════════════════════════════════════════════════════════════════

ACCOUNT_TOKEN=""
TOKEN_SOURCE=""

# 1. Credentials file
if [ -f "$CREDENTIALS_FILE" ]; then
    ok "credentials file" "$CREDENTIALS_FILE"
    if command -v jq &>/dev/null; then
        ACCOUNT_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
        if [ -n "$ACCOUNT_TOKEN" ]; then
            ok "token field" "present (.claudeAiOauth.accessToken)"
            TOKEN_SOURCE="credentials file"
        else
            fail "token field" ".claudeAiOauth.accessToken missing or empty in $CREDENTIALS_FILE"
        fi
    else
        skip "token field" "skipped (jq not available)"
    fi
else
    fail "credentials file" "not found: $CREDENTIALS_FILE"
fi

# 2. macOS Keychain fallback
if [ -z "$ACCOUNT_TOKEN" ] && command -v security &>/dev/null; then
    _keychain_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if [ -n "$_keychain_json" ]; then
        ACCOUNT_TOKEN=$(echo "$_keychain_json" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        if [ -n "$ACCOUNT_TOKEN" ]; then
            ok "keychain fallback" "token found in macOS Keychain"
            TOKEN_SOURCE="macOS Keychain"
        else
            fail "keychain fallback" "entry found but token field missing"
        fi
    else
        fail "keychain fallback" "no entry in macOS Keychain (Claude Code-credentials)"
    fi
elif [ -n "$ACCOUNT_TOKEN" ]; then
    skip "keychain fallback" "skipped (credentials file OK)"
else
    skip "keychain fallback" "security command not available"
fi

# 3. Token non-empty summary
if [ -n "$ACCOUNT_TOKEN" ]; then
    _tok_preview="${ACCOUNT_TOKEN:0:8}...${ACCOUNT_TOKEN: -4}"
    ok "token non-empty" "source: $TOKEN_SOURCE  (${_tok_preview})"
else
    fail "token non-empty" "no token found — API calls will be skipped"
fi

# 4. Hash
ACCOUNT_HASH=""
if [ -n "$ACCOUNT_TOKEN" ]; then
    if command -v sha256sum &>/dev/null; then
        ACCOUNT_HASH=$(echo -n "$ACCOUNT_TOKEN" | sha256sum | cut -c1-8)
    elif command -v shasum &>/dev/null; then
        ACCOUNT_HASH=$(echo -n "$ACCOUNT_TOKEN" | shasum -a 256 | cut -c1-8)
    fi
    if [ -n "$ACCOUNT_HASH" ]; then
        ok "token hash" "$ACCOUNT_HASH  (cache suffix)"
    else
        fail "token hash" "sha256 failed — cache will use base name"
    fi
else
    skip "token hash" "no token"
fi

# ════════════════════════════════════════════════════════════════════════════
section "CACHE"
# ════════════════════════════════════════════════════════════════════════════

# Resolve actual cache path (mirrors statusline.sh logic)
if [ -n "$ACCOUNT_HASH" ]; then
    USAGE_FILE="${USAGE_FILE_BASE%.json}-${ACCOUNT_HASH}.json"
else
    USAGE_FILE="$USAGE_FILE_BASE"
fi

info "expected path: $USAGE_FILE"

if [ -f "$USAGE_FILE" ]; then
    ok "cache file" "exists"

    # Age
    if stat --version &>/dev/null 2>&1; then
        _mtime=$(stat -c %Y "$USAGE_FILE" 2>/dev/null || echo 0)
    else
        _mtime=$(stat -f %m "$USAGE_FILE" 2>/dev/null || echo 0)
    fi
    _now=$(date +%s)
    _age=$(( _now - _mtime ))
    [ "$_age" -lt 0 ] && _age=0

    if [ "$_age" -gt $(( REFRESH_INTERVAL * 3 )) ]; then
        warn "cache age" "${_age}s  (stale — 3× REFRESH_INTERVAL=${REFRESH_INTERVAL}s, will show ⚠)"
    elif [ "$_age" -gt "$REFRESH_INTERVAL" ]; then
        warn "cache age" "${_age}s  (> REFRESH_INTERVAL=${REFRESH_INTERVAL}s — refresh will trigger)"
    else
        ok "cache age" "${_age}s  (< ${REFRESH_INTERVAL}s refresh interval)"
    fi

    # Valid JSON
    if command -v jq &>/dev/null; then
        if jq -e . "$USAGE_FILE" &>/dev/null; then
            ok "valid JSON" ""

            # Show fields
            IFS='|' read -r C_SRC C_SESS C_SESS_RESETS C_WEEK C_EXTRA_PCT C_EXTRA_USED C_EXTRA_LIMIT \
                < <(jq -r '[
                    (.source // "legacy"),
                    (.metrics.session.percent_used     // ""),
                    (.metrics.session.resets_at        // ""),
                    (.metrics.week_all.percent_used    // ""),
                    (.metrics.extra.percent_used       // ""),
                    (.metrics.extra.used_credits       // ""),
                    (.metrics.extra.monthly_limit      // "")
                ] | join("|")' "$USAGE_FILE" 2>/dev/null)

            info "source:       ${C_SRC:-unknown}"

            if [ -n "$C_SESS" ]; then
                _sess_line="five_hour ${C_SESS%.*}%"
                [ -n "$C_SESS_RESETS" ] && _sess_line+="  resets_at: $C_SESS_RESETS"
                info "$_sess_line"
            else
                info "five_hour:    (empty)"
            fi

            [ -n "$C_WEEK" ] && info "seven_day:    ${C_WEEK%.*}%" || info "seven_day:    (empty)"

            if [ -n "$C_EXTRA_PCT" ]; then
                _extra="${C_EXTRA_PCT%.*}%"
                if command -v bc &>/dev/null && [ -n "$C_EXTRA_USED" ] && [ -n "$C_EXTRA_LIMIT" ]; then
                    _used=$(printf '$%.2f' "$(echo "$C_EXTRA_USED / 100" | bc -l)" 2>/dev/null)
                    _limit=$(printf '$%.0f' "$(echo "$C_EXTRA_LIMIT / 100" | bc -l)" 2>/dev/null)
                    _extra+="  ${_used}/${_limit}"
                fi
                info "extra_usage:  $_extra"
            else
                info "extra_usage:  (none)"
            fi
        else
            fail "valid JSON" "cache file is not valid JSON — delete and retry"
        fi
    else
        skip "valid JSON" "skipped (jq not available)"
    fi
else
    warn "cache file" "not found (will be created on first successful API call)"
fi

# ════════════════════════════════════════════════════════════════════════════
section "API"
# ════════════════════════════════════════════════════════════════════════════

if ! command -v curl &>/dev/null; then
    fail "API checks" "skipped (curl not installed)"
else
    # DNS / reachability (GET, body discarded)
    _head_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "https://api.anthropic.com" 2>/dev/null)
    _curl_rc=$?
    if [ "$_curl_rc" -ne 0 ]; then
        fail "dns / reachability" "curl error $_curl_rc — check network"
    elif [ "$_head_code" -ge 200 ] && [ "$_head_code" -lt 600 ]; then
        ok "dns / reachability" "api.anthropic.com reachable (HTTP $_head_code)"
    else
        warn "dns / reachability" "unexpected HTTP $_head_code"
    fi

    # Live API call
    if [ -z "$ACCOUNT_TOKEN" ]; then
        skip "/api/oauth/usage" "skipped — no token"
    else
        _claude_ver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        _api_resp=$(curl -s --max-time 8 -w "\n%{http_code}" \
            "https://api.anthropic.com/api/oauth/usage" \
            -H "Authorization: Bearer $ACCOUNT_TOKEN" \
            -H "User-Agent: claude-code/${_claude_ver:-2.1.92}" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "Content-Type: application/json" 2>/dev/null)
        _curl_rc=$?
        _api_http=$(echo "$_api_resp" | tail -1)
        _api_body=$(echo "$_api_resp" | sed '$d')

        if [ "$_curl_rc" -ne 0 ]; then
            fail "/api/oauth/usage" "curl error $_curl_rc (timeout or network failure)"
        elif [ "$_api_http" = "200" ]; then
            if command -v jq &>/dev/null && echo "$_api_body" | jq -e '.five_hour.utilization' &>/dev/null; then
                ok "/api/oauth/usage" "HTTP 200 — data valid"
                IFS='|' read -r A_SESS A_WEEK A_EXTRA_PCT A_EXTRA_USED A_EXTRA_LIMIT \
                    < <(echo "$_api_body" | jq -r '[
                        (.five_hour.utilization  // ""),
                        (.seven_day.utilization  // ""),
                        (.extra_usage.utilization // ""),
                        (.extra_usage.used_credits // ""),
                        (.extra_usage.monthly_limit // "")
                    ] | join("|")' 2>/dev/null)
                [ -n "$A_SESS" ]  && info "five_hour:    ${A_SESS%.*}%"
                [ -n "$A_WEEK" ]  && info "seven_day:    ${A_WEEK%.*}%"
                if [ -n "$A_EXTRA_PCT" ]; then
                    _extra="${A_EXTRA_PCT%.*}%"
                    if command -v bc &>/dev/null && [ -n "$A_EXTRA_USED" ] && [ -n "$A_EXTRA_LIMIT" ]; then
                        _used=$(printf '$%.2f' "$(echo "$A_EXTRA_USED / 100" | bc -l)" 2>/dev/null)
                        _limit=$(printf '$%.0f' "$(echo "$A_EXTRA_LIMIT / 100" | bc -l)" 2>/dev/null)
                        _extra+="  ${_used}/${_limit}"
                    fi
                    info "extra_usage:  $_extra"
                fi
            else
                fail "/api/oauth/usage" "HTTP 200 but response missing .five_hour.utilization"
                info "raw response: $(echo "$_api_body" | head -c 300)"
            fi
        elif [ "$_api_http" = "401" ]; then
            fail "/api/oauth/usage" "HTTP 401 — token expired or invalid, run: claude /login"
        elif [ "$_api_http" = "404" ]; then
            fail "/api/oauth/usage" "HTTP 404 — endpoint removed or URL changed"
        elif [ "$_api_http" = "429" ]; then
            warn "/api/oauth/usage" "HTTP 429 — rate limited, try again later"
        else
            fail "/api/oauth/usage" "HTTP $_api_http — unexpected response"
            info "raw response: $(echo "$_api_body" | head -c 300)"
        fi
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
section "SETTINGS"
# ════════════════════════════════════════════════════════════════════════════

if [ -f "$SETTINGS_FILE" ]; then
    ok "settings.json" "exists"
    if command -v jq &>/dev/null; then
        _sl_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null)
        _sl_type=$(jq -r '.statusLine.type // empty' "$SETTINGS_FILE" 2>/dev/null)
        if [ -n "$_sl_cmd" ]; then
            if echo "$_sl_cmd" | grep -q "statusline"; then
                ok "statusLine config" "$_sl_cmd"
            else
                warn "statusLine config" "command doesn't mention statusline: $_sl_cmd"
            fi
        else
            fail "statusLine config" "missing .statusLine.command — run bash install.sh"
        fi
    else
        skip "statusLine config" "skipped (jq not available)"
    fi
else
    fail "settings.json" "not found: $SETTINGS_FILE — run bash install.sh"
fi

# Installed hook file
if [ -f "$HOOK_FILE" ]; then
    ok "hook file" "$HOOK_FILE"
else
    fail "hook file" "not found: $HOOK_FILE — run bash install.sh"
fi

info "REFRESH_INTERVAL: ${REFRESH_INTERVAL}s"
[ -n "$TIMEZONE" ] && info "TIMEZONE: $TIMEZONE" || info "TIMEZONE: (system default)"
info "SHOW_WEEKLY: ${SHOW_WEEKLY:-1}  SHOW_EXTRA: ${SHOW_EXTRA:-1}"

# ════════════════════════════════════════════════════════════════════════════
section "RENDER"
# ════════════════════════════════════════════════════════════════════════════

if [ -f "$HOOK_FILE" ]; then
    _render_out=$(echo '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":42}}' \
        | REFRESH_INTERVAL=999999 CREDENTIALS_FILE="$CREDENTIALS_FILE" bash "$HOOK_FILE" 2>/dev/null)
    _render_rc=$?
    if [ "$_render_rc" -eq 0 ] && [ -n "$_render_out" ]; then
        ok "render test" "exit $_render_rc"
        info "output: $_render_out"
    elif [ "$_render_rc" -eq 0 ] && [ -z "$_render_out" ]; then
        warn "render test" "exit 0 but output is empty"
    else
        fail "render test" "exit $_render_rc"
    fi
else
    skip "render test" "skipped — hook file not installed"
fi

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════
echo ""
if [ "$ISSUES" -eq 0 ]; then
    echo "${GREEN}${BOLD}=== All checks passed ===${R}"
else
    echo "${RED}${BOLD}=== $ISSUES issue(s) found ===${R}"
    echo "${DIM}Fix the ✗ items above and re-run this script.${R}"
fi
echo ""
