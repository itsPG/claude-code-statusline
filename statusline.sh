#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# Claude Code — Status Line with real-time usage tracking
#
# Self-contained: everything is in this single file, no external scripts.
# Dependencies: bash, jq, curl
# License: MIT
#
# Default: 🌿 main★ │ Snt 4.6 │ 🟢 Ctx ▓▓▓░░ 42% │ ⏳ 🟡 ▓▓░░░ 35% ↻ 2h30m │ $0.12 1h4m
# ════════════════════════════════════════════════════════════════════════════

# ── Configuration (override via environment variables) ────────────────────────
TIMEZONE="${TIMEZONE:-}"                            # e.g. "America/New_York", empty = system default
REFRESH_INTERVAL="${REFRESH_INTERVAL:-60}"           # seconds between API calls
SHOW_WEEKLY="${SHOW_WEEKLY:-0}"                      # set to 1 to show weekly + sonnet quotas
USAGE_FILE="${USAGE_FILE:-$HOME/.claude/usage-exact.json}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"

# ── Helpers ───────────────────────────────────────────────────────────────────
tz_date() {
    local tz="$1"; shift
    if [ -n "$tz" ]; then TZ="$tz" date "$@"; else date "$@"; fi
}

format_remaining() {
    local secs="$1"
    [ "$secs" -le 0 ] 2>/dev/null && return
    local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
    if [ $h -gt 0 ]; then echo "${h}h${m}m"; else echo "${m}m"; fi
}

iso_to_epoch() {
    date -d "$1" +%s 2>/dev/null
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

# make_bar <percent> → sets BAR_COLOR and BAR_STR (5-block bar)
make_bar() {
    local pct="$1"
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    local filled=$(( (pct + 19) / 20 )); [ $filled -gt 5 ] && filled=5
    local empty=$(( 5 - filled ))
    BAR_STR=""
    local i
    for ((i=0; i<filled; i++)); do BAR_STR+="▓"; done
    for ((i=0; i<empty;  i++)); do BAR_STR+="░"; done
    if   [ "$pct" -lt 50 ]; then BAR_COLOR="🟢"
    elif [ "$pct" -lt 80 ]; then BAR_COLOR="🟡"
    else                         BAR_COLOR="🔴"
    fi
}

# ── Read JSON input from stdin ────────────────────────────────────────────────
JSON=$(cat)

# ── Model ─────────────────────────────────────────────────────────────────────
MODEL=$(echo "$JSON" | jq -r '.model.display_name // empty' 2>/dev/null \
    | sed 's/Default (\(.*\))/\1/' | sed 's/Claude //' | sed 's/ (.*//')
[ -z "$MODEL" ] && MODEL=$(echo "$JSON" | jq -r '.model // empty' 2>/dev/null)
case "$MODEL" in
  claude-sonnet-4-6*|Sonnet\ 4.6*) MODEL="Snt 4.6" ;;
  claude-sonnet-4-5*|Sonnet\ 4.5*) MODEL="Snt 4.5" ;;
  claude-opus-4-6*|Opus\ 4*)       MODEL="Opus 4.6" ;;
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
CTX_PERCENT=$(echo "$JSON" | jq -r '.context_window.used_percentage // 0' 2>/dev/null | cut -d. -f1)
CTX_PERCENT=${CTX_PERCENT:-0}
CTX_SIZE=$(echo "$JSON" | jq -r '.context_window.context_window_size // 0' 2>/dev/null)
CTX_LABEL="Ctx"
[ "$CTX_SIZE" -ge 900000 ] 2>/dev/null && CTX_LABEL="1M"

make_bar "$CTX_PERCENT"
CTX_COLOR="$BAR_COLOR" CTX_BAR="$BAR_STR"

# ── Session cost + duration ───────────────────────────────────────────────────
COST_STR="" DURATION_STR=""
COST_USD=$(echo "$JSON" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
DURATION_MS=$(echo "$JSON" | jq -r '.cost.total_duration_ms // empty' 2>/dev/null)
if [ -n "$COST_USD" ] && [ "$COST_USD" != "0" ] && [ "$COST_USD" != "null" ]; then
    COST_STR=$(printf '$%.2f' "$COST_USD" 2>/dev/null)
fi
if [ -n "$DURATION_MS" ] && [ "$DURATION_MS" != "0" ] && [ "$DURATION_MS" != "null" ]; then
    DURATION_STR=$(format_remaining $(( DURATION_MS / 1000 )))
fi

# ── Git branch ────────────────────────────────────────────────────────────────
CWD=$(echo "$JSON" | jq -r '.workspace.current_dir // ""' 2>/dev/null)
BRANCH="" DIRTY=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    BRANCH=$(git -C "$CWD" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$BRANCH" ] && git -C "$CWD" --no-optional-locks diff --quiet HEAD 2>/dev/null; then
        git -C "$CWD" --no-optional-locks ls-files --others --exclude-standard 2>/dev/null | read -r && DIRTY="★"
    else
        [ -n "$BRANCH" ] && DIRTY="★"
    fi
fi
[ -z "$BRANCH" ] && BRANCH="(no git)"
[ "${#BRANCH}" -gt 30 ] && BRANCH="${BRANCH:0:27}..."

# ── Refresh usage via Anthropic OAuth API ────────────────────────────────────
refresh_usage_api() {
    [ ! -f "$CREDENTIALS_FILE" ] && return 1
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    [ -z "$token" ] && return 1
    local resp
    resp=$(curl -s --max-time 3 \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
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
            week_all: {
                percent_used: .seven_day.utilization,
                percent_remaining: (100 - .seven_day.utilization),
                resets_at: .seven_day.resets_at
            },
            week_sonnet: (if .seven_day_sonnet then {
                percent_used: .seven_day_sonnet.utilization,
                percent_remaining: (100 - .seven_day_sonnet.utilization),
                resets_at: .seven_day_sonnet.resets_at
            } else null end)
        }
    }' > "${USAGE_FILE}.tmp" && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
}

[ "$(cache_age_sec)" -gt "$REFRESH_INTERVAL" ] && refresh_usage_api

# ── Read cached usage metrics ─────────────────────────────────────────────────
BLOCK_DISPLAY="" WEEK_SONNET_DISPLAY=""
NOW=$(date +%s)

if [ -f "$USAGE_FILE" ]; then
    CACHE_SOURCE=$(jq -r '.source // "legacy"' "$USAGE_FILE" 2>/dev/null)
    mapfile -t uvals < <(jq -r '
        (.metrics.session.percent_used     // ""),
        (.metrics.session.resets_at        // .metrics.session.resets // ""),
        (.metrics.week_all.percent_used    // ""),
        (.metrics.week_all.resets_at       // .metrics.week_all.resets // ""),
        (.metrics.week_sonnet.percent_used // "")
    ' "$USAGE_FILE" 2>/dev/null)

    if [ ${#uvals[@]} -ge 5 ]; then
        U_SESS_PCT="${uvals[0]}" U_SESS_RESETS="${uvals[1]}"
        U_WEEK_PCT="${uvals[2]}" U_WEEK_RESETS="${uvals[3]}"
        U_SONNET_PCT="${uvals[4]}"

        # Session block
        if [ -n "$U_SESS_PCT" ] && [ "$U_SESS_PCT" != "null" ]; then
            SESS_INT="${U_SESS_PCT%.*}"
            REMAIN_STR=""
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
                [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -gt "$NOW" ] && \
                    REMAIN_STR=$(format_remaining $(( RESET_EPOCH - NOW )))
            fi
            make_bar "$SESS_INT"
            if [ -n "$REMAIN_STR" ]; then
                BLOCK_DISPLAY="⏳ ${BAR_COLOR} ${BAR_STR} ${SESS_INT}% ↻ ${REMAIN_STR}"
            else
                BLOCK_DISPLAY="⏳ ${BAR_COLOR} ${BAR_STR} ${SESS_INT}%"
            fi
        fi

        # Weekly + Sonnet (opt-in)
        WEEK_INT="" WEEK_COLOR="" WEEK_RESET_LABEL="" SONNET_INT="" SONNET_COLOR=""
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
                [ -n "$WEEK_EPOCH" ] && \
                    WEEK_RESET_LABEL=$(tz_date "${TIMEZONE}" -d "@$WEEK_EPOCH" +"%a %Hh" 2>/dev/null \
                        | tr '[:upper:]' '[:lower:]')
            fi
            make_bar "$WEEK_INT"; WEEK_COLOR="$BAR_COLOR"
        fi
        if [ "$SHOW_WEEKLY" = "1" ] && [ -n "$U_SONNET_PCT" ] && [ "$U_SONNET_PCT" != "null" ]; then
            SONNET_INT="${U_SONNET_PCT%.*}"
            make_bar "$SONNET_INT"; SONNET_COLOR="$BAR_COLOR"
        fi
        if [ -n "$WEEK_INT" ] && [ -n "$SONNET_INT" ]; then
            WEEK_SONNET_DISPLAY="📅 ${WEEK_COLOR} ${WEEK_INT}% / Snt ${SONNET_COLOR} ${SONNET_INT}%"
            [ -n "$WEEK_RESET_LABEL" ] && WEEK_SONNET_DISPLAY+=" ↻ ${WEEK_RESET_LABEL}"
        elif [ -n "$WEEK_INT" ]; then
            WEEK_SONNET_DISPLAY="📅 ${WEEK_COLOR} ${WEEK_INT}%"
            [ -n "$WEEK_RESET_LABEL" ] && WEEK_SONNET_DISPLAY+=" ↻ ${WEEK_RESET_LABEL}"
        elif [ -n "$SONNET_INT" ]; then
            WEEK_SONNET_DISPLAY="Snt ${SONNET_COLOR} ${SONNET_INT}%"
        fi
    fi
fi

# ── Stale indicator ───────────────────────────────────────────────────────────
REFRESH_SUFFIX=""
if [ -f "$USAGE_FILE" ]; then
    AGE=$(cache_age_sec)
    [ "$AGE" -gt $(( REFRESH_INTERVAL * 5 )) ] && REFRESH_SUFFIX=" ⚠"
fi

# ── Assemble ──────────────────────────────────────────────────────────────────
PARTS=()
[ -n "$BRANCH" ] && PARTS+=("🌿 $BRANCH$DIRTY")
if [ -n "$MODEL" ] && [ -n "$EFFORT_LABEL" ]; then
    PARTS+=("$MODEL/$EFFORT_LABEL")
elif [ -n "$MODEL" ]; then
    PARTS+=("$MODEL")
fi
[ -n "$CTX_PERCENT" ]         && PARTS+=("$CTX_COLOR $CTX_LABEL $CTX_BAR ${CTX_PERCENT}%")
[ -n "$BLOCK_DISPLAY" ]       && PARTS+=("$BLOCK_DISPLAY")
[ -n "$WEEK_SONNET_DISPLAY" ] && PARTS+=("$WEEK_SONNET_DISPLAY")
# Cost + duration (only if non-zero)
if [ -n "$COST_STR" ] && [ -n "$DURATION_STR" ]; then
    PARTS+=("$COST_STR $DURATION_STR")
elif [ -n "$COST_STR" ]; then
    PARTS+=("$COST_STR")
fi

RESULT=""
for part in "${PARTS[@]}"; do
    [ -z "$RESULT" ] && RESULT="$part" || RESULT="$RESULT │ $part"
done

echo "${RESULT}${REFRESH_SUFFIX}"
