#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# Claude Code — Status Line with real-time usage tracking
#
# Self-contained: everything is in this single file, no external scripts.
# Dependencies: bash, jq, curl
# License: MIT
#
# Default: Snt 4.6 │ 🟢 Ctx 42% │ ⏳ 🟡 35% ↻ 2h30m │ 📅 🔵 17% ↻ 2D14H │ $0.12 ⏱ 1h4m
# ════════════════════════════════════════════════════════════════════════════

# ── Configuration (override via environment variables) ────────────────────────
TIMEZONE="${TIMEZONE:-}"                            # e.g. "America/New_York", empty = system default
REFRESH_INTERVAL="${REFRESH_INTERVAL:-120}"           # seconds between API calls (0 = every render, risks rate limiting)
SHOW_WEEKLY="${SHOW_WEEKLY:-1}"                      # set to 0 to hide weekly + sonnet quotas
SHOW_EXTRA="${SHOW_EXTRA:-1}"                        # set to 0 to hide extra usage (pay-as-you-go)
USAGE_FILE="${USAGE_FILE:-$HOME/.claude/usage-exact.json}"
# ── Resolve per-account cache (hash token → separate cache per account) ──────
_CREDENTIALS_CUSTOM="${CREDENTIALS_FILE+set}"   # was CREDENTIALS_FILE explicitly set?
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
ACCOUNT_TOKEN=""
if [ -f "$CREDENTIALS_FILE" ]; then
    ACCOUNT_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
fi
# Fallback: macOS Keychain — only when using the default credentials path
if [ -z "$ACCOUNT_TOKEN" ] && [ "${_CREDENTIALS_CUSTOM}" != "set" ] && command -v security &>/dev/null; then
    _keychain_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if [ -n "$_keychain_json" ]; then
        ACCOUNT_TOKEN=$(echo "$_keychain_json" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
fi
if [ -n "$ACCOUNT_TOKEN" ]; then
    if command -v sha256sum &>/dev/null; then
        ACCOUNT_HASH=$(echo -n "$ACCOUNT_TOKEN" | sha256sum | cut -c1-8)
    elif command -v shasum &>/dev/null; then
        ACCOUNT_HASH=$(echo -n "$ACCOUNT_TOKEN" | shasum -a 256 | cut -c1-8)
    fi
    [ -n "$ACCOUNT_HASH" ] && USAGE_FILE="${USAGE_FILE%.json}-${ACCOUNT_HASH}.json"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
tz_date() {
    local tz="$1"; shift
    if [ -n "$tz" ]; then TZ="$tz" date "$@"; else date "$@"; fi
}

format_remaining() {
    local secs="$1"
    [ "$secs" -le 0 ] 2>/dev/null && return
    local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
    if [ $h -gt 0 ]; then echo "${h}h${m}m"
    elif [ $m -gt 0 ]; then echo "${m}m"
    else echo "<1m"
    fi
}

# Cross-platform ISO 8601 → epoch (GNU date -d || BSD date -j)
iso_to_epoch() {
    local iso="$1"
    date -d "$iso" +%s 2>/dev/null && return
    # macOS/BSD fallback: parse datetime as UTC, then apply timezone offset
    local tz_sign tz_h tz_m tz_adj=0
    tz_sign=$(echo "$iso" | sed -n 's/.*T[0-9:.]*\([+-]\)[0-9][0-9]:[0-9][0-9]$/\1/p')
    tz_h=$(echo "$iso"    | sed -n 's/.*T[0-9:.]*[+-]\([0-9][0-9]\):[0-9][0-9]$/\1/p')
    tz_m=$(echo "$iso"    | sed -n 's/.*T[0-9:.]*[+-][0-9][0-9]:\([0-9][0-9]\)$/\1/p')
    if [ -n "$tz_sign" ] && [ -n "$tz_h" ]; then
        tz_adj=$(( 10#$tz_h * 3600 + 10#${tz_m:-0} * 60 ))
        [ "$tz_sign" = "+" ] && tz_adj=$(( -tz_adj ))
    fi
    local core="${iso%[+-][0-9][0-9]:*}"
    core="${core%Z}"
    core="${core%%.*}"
    local epoch
    epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$core" +%s 2>/dev/null) || return 1
    echo $(( epoch + tz_adj ))
}

file_mtime() {
    if stat --version &>/dev/null; then
        stat -c %Y "$1" 2>/dev/null || echo 0
    else
        stat -f %m "$1" 2>/dev/null || echo 0
    fi
}

cache_age_sec() {
    [ ! -f "$USAGE_FILE" ] && echo 999999 && return
    local age=$(( $(date +%s) - $(file_mtime "$USAGE_FILE") ))
    [ "$age" -lt 0 ] && age=0
    echo "$age"
}

# make_bar <percent> → sets BAR_COLOR and BAR_STR (6-block bar)
make_bar() {
    local pct="$1"
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    local filled=$(( (pct + 16) / 17 )); [ $filled -gt 6 ] && filled=6
    local empty=$(( 6 - filled ))
    BAR_STR=""
    local i
    for ((i=0; i<filled; i++)); do BAR_STR+="▓"; done
    for ((i=0; i<empty;  i++)); do BAR_STR+="░"; done
    if   [ "$pct" -lt 20 ]; then BAR_COLOR="🔵"
    elif [ "$pct" -lt 50 ]; then BAR_COLOR="🟢"
    elif [ "$pct" -lt 70 ]; then BAR_COLOR="🟡"
    elif [ "$pct" -lt 85 ]; then BAR_COLOR="🟠"
    else                         BAR_COLOR="🔴"
    fi
}

# ── Read JSON input from stdin ────────────────────────────────────────────────
JSON=$(cat)

# ── Parse all stdin fields in a single jq call ───────────────────────────────
IFS='|' read -r J_MODEL_DISPLAY J_MODEL_RAW J_CTX_PCT J_CTX_SIZE J_COST J_DURATION J_CWD \
    < <(echo "$JSON" | jq -r '[
        (if .model | type == "object" then .model.display_name // "" else "" end),
        (if .model | type == "string" then .model else "" end),
        (.context_window.used_percentage // 0 | tostring | split(".")[0]),
        (.context_window.context_window_size // 0),
        (.cost.total_cost_usd // ""),
        (.cost.total_duration_ms // ""),
        (.workspace.current_dir // "")
    ] | join("|")' 2>/dev/null)

# ── Model ─────────────────────────────────────────────────────────────────────
MODEL="$J_MODEL_DISPLAY"
MODEL=$(echo "$MODEL" | sed 's/Default (\(.*\))/\1/' | sed 's/Claude //' | sed 's/ (.*//')
[ -z "$MODEL" ] && MODEL="$J_MODEL_RAW"
case "$MODEL" in
  claude-sonnet-4-6*|Sonnet\ 4.6*) MODEL="Snt 4.6" ;;
  claude-sonnet-4-5*|Sonnet\ 4.5*) MODEL="Snt 4.5" ;;
  claude-opus-4-6*|Opus\ 4.6*)     MODEL="Opus 4.6" ;;
  claude-opus-4-5*|Opus\ 4.5*)     MODEL="Opus 4.5" ;;
  claude-haiku-4*|Haiku\ 4*)       MODEL="Haiku 4"  ;;
esac

# ── Effort level (from settings.json — not yet in stdin JSON) ────────────────
EFFORT_LABEL=""
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    case "$(jq -r '.effortLevel // empty' "$SETTINGS_FILE" 2>/dev/null)" in
        low)    EFFORT_LABEL="lo" ;;
        medium) EFFORT_LABEL="md" ;;
        high)   EFFORT_LABEL="hi" ;;
        max)    EFFORT_LABEL="mx" ;;
    esac
fi

# ── Context window ────────────────────────────────────────────────────────────
CTX_PERCENT="${J_CTX_PCT:-0}"
CTX_LABEL="Ctx"
if   [ "$J_CTX_SIZE" -ge 1900000 ] 2>/dev/null; then CTX_LABEL="2M"
elif [ "$J_CTX_SIZE" -ge 900000 ]  2>/dev/null; then CTX_LABEL="1M"
fi

make_bar "$CTX_PERCENT"
CTX_COLOR="$BAR_COLOR" CTX_BAR="$BAR_STR"

# Large context (1M+): stricter thresholds — 50% of 1M is already 500K tokens
if [ "$CTX_LABEL" = "1M" ] || [ "$CTX_LABEL" = "2M" ]; then
    if   [ "$CTX_PERCENT" -lt 12 ]; then CTX_COLOR="🔵"
    elif [ "$CTX_PERCENT" -lt 29 ]; then CTX_COLOR="🟢"
    elif [ "$CTX_PERCENT" -lt 41 ]; then CTX_COLOR="🟡"
    elif [ "$CTX_PERCENT" -lt 50 ]; then CTX_COLOR="🟠"
    elif [ "$CTX_PERCENT" -lt 70 ]; then CTX_COLOR="🔴"
    else                                 CTX_COLOR="🟣"
    fi
fi

# ── Session cost + duration ───────────────────────────────────────────────────
COST_STR="" DURATION_STR=""
if [ -n "$J_COST" ] && [ "$J_COST" != "0" ] && [ "$J_COST" != "null" ]; then
    COST_STR=$(printf '$%.2f' "$J_COST" 2>/dev/null)
fi
if [ -n "$J_DURATION" ] && [ "$J_DURATION" != "0" ] && [ "$J_DURATION" != "null" ]; then
    DURATION_STR=$(format_remaining $(( J_DURATION / 1000 )))
fi


# ── Refresh usage via Anthropic OAuth API ────────────────────────────────────
refresh_usage_api() {
    [ -z "$ACCOUNT_TOKEN" ] && return 1
    local resp
    local _claude_ver
    _claude_ver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    resp=$(curl -s --max-time 3 \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $ACCOUNT_TOKEN" \
        -H "User-Agent: claude-code/${_claude_ver:-2.1.92}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null)
    echo "$resp" | jq -e '.five_hour.utilization' >/dev/null 2>&1 || return 1
    echo "$resp" | jq '{
        timestamp: (now | todate),
        source: "api",
        metrics: {
            session: {
                percent_used: .five_hour.utilization,
                percent_remaining: (100 - .five_hour.utilization),
                resets_at: .five_hour.resets_at
            },
            week_all: (if .seven_day then {
                percent_used: .seven_day.utilization,
                percent_remaining: (100 - .seven_day.utilization),
                resets_at: .seven_day.resets_at
            } else null end),
            week_sonnet: (if .seven_day_sonnet then {
                percent_used: .seven_day_sonnet.utilization,
                percent_remaining: (100 - .seven_day_sonnet.utilization),
                resets_at: .seven_day_sonnet.resets_at
            } else null end),
            extra: (if (.extra_usage.is_enabled // false) then {
                percent_used: .extra_usage.utilization,
                used_credits: .extra_usage.used_credits,
                monthly_limit: .extra_usage.monthly_limit
            } else null end)
        }
    }' > "${USAGE_FILE}.tmp" && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
}

LOCK_FILE="/tmp/statusline-refresh${ACCOUNT_HASH:+-$ACCOUNT_HASH}.lock"
if [ "$(cache_age_sec)" -gt "$REFRESH_INTERVAL" ]; then
    if command -v flock &>/dev/null; then
        ( flock -n 9 || exit 0; refresh_usage_api ) 9>"$LOCK_FILE"
    else
        # macOS: flock not available — remove stale lock then try to acquire
        if [ -f "$LOCK_FILE" ]; then
            _lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [ -z "$_lock_pid" ] || ! kill -0 "$_lock_pid" 2>/dev/null; then
                rm -f "$LOCK_FILE"
            fi
        fi
        if ( set -o noclobber; echo $$ > "$LOCK_FILE" ) 2>/dev/null; then
            refresh_usage_api
            rm -f "$LOCK_FILE"
        fi
    fi
fi

# ── Read cached usage metrics ─────────────────────────────────────────────────
BLOCK_DISPLAY="" WEEK_SONNET_DISPLAY=""
NOW=$(date +%s)

if [ -f "$USAGE_FILE" ]; then
    # Single jq call to read all cache fields
    IFS='|' read -r CACHE_SOURCE U_SESS_PCT U_SESS_RESETS U_WEEK_PCT U_WEEK_RESETS U_SONNET_PCT \
        U_EXTRA_PCT U_EXTRA_USED U_EXTRA_LIMIT \
        < <(jq -r '[
            (.source // "legacy"),
            (.metrics.session.percent_used     // ""),
            (.metrics.session.resets_at        // .metrics.session.resets // ""),
            (.metrics.week_all.percent_used    // ""),
            (.metrics.week_all.resets_at       // .metrics.week_all.resets // ""),
            (.metrics.week_sonnet.percent_used // ""),
            (.metrics.extra.percent_used       // ""),
            (.metrics.extra.used_credits       // ""),
            (.metrics.extra.monthly_limit      // "")
        ] | join("|")' "$USAGE_FILE" 2>/dev/null)

    if [ -n "$CACHE_SOURCE" ]; then
        # Session block
        if [ -n "$U_SESS_PCT" ] && [ "$U_SESS_PCT" != "null" ]; then
            SESS_INT="${U_SESS_PCT%.*}"
            REMAIN_STR=""
            RESET_EPOCH=""
            if [ -n "$U_SESS_RESETS" ] && [ "$U_SESS_RESETS" != "null" ]; then
                if [ "$CACHE_SOURCE" = "api" ]; then
                    RESET_EPOCH=$(iso_to_epoch "$U_SESS_RESETS")
                else
                    RESET_TZ=$(echo "$U_SESS_RESETS" | sed -n 's/.*(\([^)]*\)).*/\1/p')
                    [ -z "$RESET_TZ" ] && RESET_TZ="${TIMEZONE}"
                    RESET_TIME_STR=$(echo "$U_SESS_RESETS" | sed 's/ *([^)]*)//')
                    RESET_EPOCH=$(tz_date "${RESET_TZ}" -d "today $RESET_TIME_STR" +%s 2>/dev/null)
                    [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -le "$NOW" ] && \
                        RESET_EPOCH=$(tz_date "${RESET_TZ}" -d "tomorrow $RESET_TIME_STR" +%s 2>/dev/null)
                fi
                if [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -gt "$NOW" ]; then
                    REMAIN_STR=$(format_remaining $(( RESET_EPOCH - NOW )))
                elif [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -le "$NOW" ]; then
                    # Session has reset since last API call — usage is back to ~0%
                    SESS_INT=0
                fi
            fi
            make_bar "$SESS_INT"
            if [ -n "$REMAIN_STR" ]; then
                BLOCK_DISPLAY="⏳ ${BAR_COLOR} ${SESS_INT}% ↻ ${REMAIN_STR}"
            else
                BLOCK_DISPLAY="⏳ ${BAR_COLOR} ${SESS_INT}%"
            fi
        fi

        # Weekly + Sonnet (opt-in)
        WEEK_INT="" WEEK_COLOR="" WEEK_RESET_LABEL=""
        if [ "$SHOW_WEEKLY" = "1" ] && [ -n "$U_WEEK_PCT" ] && [ "$U_WEEK_PCT" != "null" ]; then
            WEEK_INT="${U_WEEK_PCT%.*}"
            if [ -n "$U_WEEK_RESETS" ] && [ "$U_WEEK_RESETS" != "null" ]; then
                if [ "$CACHE_SOURCE" = "api" ]; then
                    WEEK_EPOCH=$(iso_to_epoch "$U_WEEK_RESETS")
                else
                    WEEK_TZ=$(echo "$U_WEEK_RESETS" | sed -n 's/.*(\([^)]*\)).*/\1/p')
                    [ -z "$WEEK_TZ" ] && WEEK_TZ="${TIMEZONE}"
                    DATE_PART=$(echo "$U_WEEK_RESETS" | sed 's/ *([^)]*)//' | sed 's/,//')
                    WEEK_EPOCH=$(tz_date "${WEEK_TZ}" -d "$DATE_PART" +%s 2>/dev/null)
                fi
                if [ -n "$WEEK_EPOCH" ]; then
                    _NOW=$(date +%s)
                    _DIFF=$(( WEEK_EPOCH - _NOW ))
                    if [ "$_DIFF" -gt 0 ]; then
                        if [ "$_DIFF" -ge 86400 ]; then
                            WEEK_RESET_LABEL="$(( _DIFF / 86400 ))d"
                        else
                            WEEK_RESET_LABEL="$(( _DIFF / 3600 ))h"
                        fi
                    fi
                fi
            fi
            make_bar "$WEEK_INT"; WEEK_COLOR="$BAR_COLOR"
        fi
        if [ -n "$WEEK_INT" ]; then
            WEEK_SONNET_DISPLAY="📅 ${WEEK_COLOR} ${WEEK_INT}%"
            [ -n "$WEEK_RESET_LABEL" ] && WEEK_SONNET_DISPLAY+=" ↻ ${WEEK_RESET_LABEL}"
        fi

        # Extra usage (pay-as-you-go)
        EXTRA_DISPLAY=""
        if [ "$SHOW_EXTRA" = "1" ] && [ -n "$U_EXTRA_PCT" ] && [ "$U_EXTRA_PCT" != "null" ]; then
            EXTRA_INT="${U_EXTRA_PCT%.*}"
            make_bar "$EXTRA_INT"
            EXTRA_DISPLAY="💳 ${BAR_COLOR} ${EXTRA_INT}%"
            if [ -n "$U_EXTRA_USED" ] && [ -n "$U_EXTRA_LIMIT" ] && \
               [ "$U_EXTRA_USED" != "null" ] && [ "$U_EXTRA_LIMIT" != "null" ]; then
                EXTRA_USED_DOLLARS=$(printf '$%.2f' "$(echo "$U_EXTRA_USED / 100" | bc -l 2>/dev/null)" 2>/dev/null)
                EXTRA_LIMIT_DOLLARS=$(printf '$%.0f' "$(echo "$U_EXTRA_LIMIT / 100" | bc -l 2>/dev/null)" 2>/dev/null)
                [ -n "$EXTRA_USED_DOLLARS" ] && [ -n "$EXTRA_LIMIT_DOLLARS" ] && \
                    EXTRA_DISPLAY+=" ${EXTRA_USED_DOLLARS}/${EXTRA_LIMIT_DOLLARS}"
            fi
        fi
    fi
fi

# ── Stale indicator — replace color dot with ⚠ when cache is stale ──────────
IS_STALE=0
if [ -f "$USAGE_FILE" ] && [ "$REFRESH_INTERVAL" -gt 0 ] 2>/dev/null; then
    [ "$(cache_age_sec)" -gt $(( REFRESH_INTERVAL * 3 )) ] && IS_STALE=1
fi
[ "$IS_STALE" = 1 ] && [ -n "$BLOCK_DISPLAY" ] && \
    BLOCK_DISPLAY=$(echo "$BLOCK_DISPLAY" | sed -E 's/🔵|🟢|🟡|🟠|🔴/⚠/')

# ── Assemble ──────────────────────────────────────────────────────────────────
PARTS=()
if [ -n "$MODEL" ] && [ -n "$EFFORT_LABEL" ]; then
    PARTS+=("$MODEL/$EFFORT_LABEL")
elif [ -n "$MODEL" ]; then
    PARTS+=("$MODEL")
fi
[ -n "$CTX_PERCENT" ]         && PARTS+=("$CTX_COLOR $CTX_LABEL ${CTX_PERCENT}%")
[ -n "$BLOCK_DISPLAY" ]       && PARTS+=("$BLOCK_DISPLAY")
[ -n "$WEEK_SONNET_DISPLAY" ] && PARTS+=("$WEEK_SONNET_DISPLAY")
[ -n "$EXTRA_DISPLAY" ]       && PARTS+=("$EXTRA_DISPLAY")
# Cost + duration (only if non-zero)
if [ -n "$COST_STR" ] && [ -n "$DURATION_STR" ]; then
    PARTS+=("$COST_STR ⏱ $DURATION_STR")
elif [ -n "$COST_STR" ]; then
    PARTS+=("$COST_STR")
fi

RESULT=""
for part in "${PARTS[@]}"; do
    [ -z "$RESULT" ] && RESULT="$part" || RESULT="$RESULT │ $part"
done

echo "$RESULT"
