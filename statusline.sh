#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# Claude Code — Status Line with real-time usage tracking
#
# Self-contained: everything is in this single file, no external scripts.
# Dependencies: bash, jq, tmux, python3
# License: MIT
#
# Output format:
# 🌿 branch │ 🤖 model │ 🟢 Ctx: ▓▓░░░░░░ XX% │ ⏱ XX% → HHhMM (Xhm) │ 📅 ~XX% (mon 14h)
#
# Install: see README.md or run install.sh
# ════════════════════════════════════════════════════════════════════════════

# ── Configuration (override via environment variables) ────────────────────────
TIMEZONE="${TIMEZONE:-}"                           # e.g. "America/New_York", empty = system default
REFRESH_INTERVAL="${REFRESH_INTERVAL:-300}"         # seconds between usage scrapes (default: 5min)
USAGE_FILE="${USAGE_FILE:-$HOME/.claude/usage-exact.json}"
LOCK_FILE="${LOCK_FILE:-/tmp/claude-usage-refresh.lock}"
TMUX_SESSION="${TMUX_SESSION:-claude-usage-bg}"

# ── Read JSON input from stdin ────────────────────────────────────────────────
JSON=$(cat)

# ── Extract and normalize the model name ─────────────────────────────────────
MODEL=$(echo "$JSON" | jq -r '.model.display_name // empty' 2>/dev/null \
    | sed 's/Default (\(.*\))/\1/' | sed 's/Claude //' | sed 's/ (.*//')
[ -z "$MODEL" ] && MODEL=$(echo "$JSON" | jq -r '.model // empty' 2>/dev/null)
case "$MODEL" in
  claude-sonnet-4-6*) MODEL="Sonnet 4.6" ;;
  claude-sonnet-4-5*) MODEL="Sonnet 4.5" ;;
  claude-opus-4-6*)   MODEL="Opus 4.6"   ;;
  claude-opus-4-5*)   MODEL="Opus 4.5"   ;;
  claude-haiku-4*)    MODEL="Haiku 4"    ;;
  Sonnet\ 4.6*)       MODEL="Sonnet 4.6" ;;
  Sonnet\ 4.5*)       MODEL="Sonnet 4.5" ;;
  Opus\ 4*)           MODEL="Opus 4.6"   ;;
  Haiku\ 4*)          MODEL="Haiku 4"    ;;
esac

# ── Context window usage percentage ──────────────────────────────────────────
CTX_PERCENT=$(echo "$JSON" | jq -r '.context_window.used_percentage // 0' 2>/dev/null | cut -d. -f1)
CTX_PERCENT=${CTX_PERCENT:-0}

# ── Build the context usage progress bar (8 blocks) ──────────────────────────
FILLED=$(( CTX_PERCENT / 13 )); [ $FILLED -gt 8 ] && FILLED=8
EMPTY=$(( 8 - FILLED ))
BAR=""
for i in $(seq 1 $FILLED 2>/dev/null); do BAR="${BAR}▓"; done
for i in $(seq 1 $EMPTY  2>/dev/null); do BAR="${BAR}░"; done

# ── Color indicator based on context usage level ─────────────────────────────
if   [ "$CTX_PERCENT" -lt 50 ]; then COLOR="🟢"
elif [ "$CTX_PERCENT" -lt 80 ]; then COLOR="🟡"
else                                  COLOR="🔴"
fi

# ── Git branch for the current workspace ─────────────────────────────────────
CWD=$(echo "$JSON" | jq -r '.workspace.current_dir // ""' 2>/dev/null)
BRANCH=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    BRANCH=$(git -C "$CWD" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi
[ -z "$BRANCH" ] && BRANCH="(no git)"
[ ${#BRANCH} -gt 33 ] && BRANCH="${BRANCH:0:30}..."

# ── Helper: age in seconds of the usage cache file ───────────────────────────
cache_age_sec() {
    [ ! -f "$USAGE_FILE" ] && echo 999999 && return
    echo $(( $(date +%s) - $(date -r "$USAGE_FILE" +%s 2>/dev/null || echo 0) ))
}

# ── Helper: true if the lock file is older than 90 seconds (stale) ───────────
lock_stale() {
    [ ! -f "$LOCK_FILE" ] && return 1
    age=$(( $(date +%s) - $(date -r "$LOCK_FILE" +%s 2>/dev/null || echo 0) ))
    [ $age -gt 120 ]
}

# ── Background refresh: launch a hidden tmux session that runs /usage ─────────
# Triggered when the cache is older than REFRESH_INTERVAL and no lock is held.
if [ $(cache_age_sec) -gt "$REFRESH_INTERVAL" ]; then
    if [ ! -f "$LOCK_FILE" ] || lock_stale; then
        touch "$LOCK_FILE"
        (
            SESSION="$TMUX_SESSION"
            PANE="$SESSION:0"

            cleanup() {
                tmux kill-session -t "$SESSION" 2>/dev/null
                rm -f "$LOCK_FILE"
            }
            trap cleanup EXIT INT TERM

            # Start a fresh hidden tmux session
            tmux kill-session -t "$SESSION" 2>/dev/null
            tmux new-session -d -s "$SESSION" -x 220 -y 50 2>/dev/null || exit 1
            sleep 0.5

            # Resolve the full path to claude (tmux may not inherit the user's PATH)
            CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "claude")
            tmux send-keys -t "$PANE" "env -u CLAUDECODE $CLAUDE_BIN" Enter

            # Poll until Claude Code prompt is ready (up to 60s)
            for i in $(seq 1 60); do
                sleep 1
                content=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
                # Accept trust/folder prompt if it appears
                if echo "$content" | grep -qi "trust\|yes.*trust\|folder"; then
                    tmux send-keys -t "$PANE" "" Enter
                fi
                # Claude is ready when we see the prompt
                if echo "$content" | grep -qi "try\|claude code\|❯\|How can"; then
                    break
                fi
            done

            # Send /usage command and confirm selection
            tmux send-keys -t "$PANE" "/usage" Enter
            sleep 2
            tmux send-keys -t "$PANE" "" Enter

            # Poll until usage data appears (up to 30s)
            for i in $(seq 1 30); do
                sleep 1
                content=$(tmux capture-pane -t "$PANE" -p -S -300 2>/dev/null)
                if echo "$content" | grep -qi "% used"; then
                    break
                fi
            done

            RAW=$(tmux capture-pane -t "$PANE" -p -S -300 2>/dev/null)

            # Parse the /usage output with Python and write the JSON cache file
            python3 - <<PYEOF
import json, re, sys
from datetime import datetime, timezone

text = """$RAW"""
now = datetime.now(timezone.utc).isoformat()
result = {"timestamp": now, "source": "/usage", "metrics": {}}

blocks = re.findall(
    r'(Current session|Current week.*?|Sonnet only.*?)\n'
    r'.*?(\d+(?:\.\d+)?)\s*%\s*used'
    r'(?:\n.*?Resets\s+(.+?)(?:\n|\$))?',
    text, re.IGNORECASE | re.DOTALL
)
for label_raw, pct, resets in blocks:
    label = label_raw.strip().lower()
    pct_val = float(pct)
    if "session" in label:
        key = "session"
    elif "sonnet" in label:
        key = "week_sonnet"
    elif "week" in label:
        key = "week_all"
    else:
        key = re.sub(r'\W+', '_', label)
    result["metrics"][key] = {
        "percent_used": pct_val,
        "percent_remaining": round(100 - pct_val, 1),
        "resets": resets.strip() if resets else None,
    }

if result["metrics"]:
    with open("$USAGE_FILE", "w") as f:
        json.dump(result, f, indent=2)
PYEOF
        ) &>/dev/null &
        disown
    fi
fi

# ── Read cached usage metrics ─────────────────────────────────────────────────
BLOCK_DISPLAY=""
WEEK_DISPLAY=""

if [ -f "$USAGE_FILE" ]; then
    mapfile -t uvals < <(jq -r '
        (.metrics.session.percent_used     // ""),
        (.metrics.session.resets           // ""),
        (.metrics.week_all.percent_used    // ""),
        (.metrics.week_all.resets          // "")
    ' "$USAGE_FILE" 2>/dev/null)
    U_SESS_PCT="${uvals[0]}"
    U_SESS_RESETS="${uvals[1]}"
    U_WEEK_PCT="${uvals[2]}"
    U_WEEK_RESETS="${uvals[3]}"

    # ── Session block: "⏱ XX% → HHhMM (Xhm)" ────────────────────────────────
    if [ -n "$U_SESS_PCT" ] && [ "$U_SESS_PCT" != "null" ]; then
        SESS_INT="${U_SESS_PCT%.*}"
        RESET_TIME="" REMAIN_STR=""

        if [ -n "$U_SESS_RESETS" ] && [ "$U_SESS_RESETS" != "null" ]; then
            # Parse reset time; use TIMEZONE if set, otherwise rely on system default
            RESET_EPOCH=$(TZ=${TIMEZONE} date -d "today $U_SESS_RESETS" +%s 2>/dev/null)
            NOW=$(date +%s)
            # If the reset time has already passed today, shift to tomorrow
            [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -le "$NOW" ] && \
                RESET_EPOCH=$(TZ=${TIMEZONE} date -d "tomorrow $U_SESS_RESETS" +%s 2>/dev/null)
            if [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -gt "$NOW" ]; then
                RESET_TIME=$(TZ=${TIMEZONE} date -d "@$RESET_EPOCH" +"%Hh%M" 2>/dev/null)
                REMAIN=$(( RESET_EPOCH - NOW ))
                RH=$(( REMAIN / 3600 )); RM=$(( (REMAIN % 3600) / 60 ))
                [ $RH -gt 0 ] && REMAIN_STR="${RH}h${RM}m" || REMAIN_STR="${RM}m"
            fi
        fi

        if [ -n "$RESET_TIME" ] && [ -n "$REMAIN_STR" ]; then
            BLOCK_DISPLAY="⏱ ${SESS_INT}% → ${RESET_TIME} (${REMAIN_STR})"
        elif [ -n "$RESET_TIME" ]; then
            BLOCK_DISPLAY="⏱ ${SESS_INT}% → ${RESET_TIME}"
        else
            BLOCK_DISPLAY="⏱ ${SESS_INT}%"
        fi
    fi

    # ── Weekly block: "📅 ~XX% (mon 14h)" ────────────────────────────────────
    if [ -n "$U_WEEK_PCT" ] && [ "$U_WEEK_PCT" != "null" ]; then
        WEEK_INT="${U_WEEK_PCT%.*}"
        WEEK_RESET_LABEL=""

        if [ -n "$U_WEEK_RESETS" ] && [ "$U_WEEK_RESETS" != "null" ]; then
            # Strip timezone annotation from the reset string before parsing
            DATE_PART=$(echo "$U_WEEK_RESETS" | sed 's/ (Europe\/Paris)//' | sed 's/ (.*)//' | sed 's/,//')
            HOUR_RAW=$(echo "$DATE_PART" | grep -oP '\d+(?=pm|am)')
            AMPM=$(echo "$DATE_PART" | grep -oP '(am|pm)')
            DATE_NOTIME=$(echo "$DATE_PART" | sed 's/[0-9]*[ap]m//')
            # Convert 12-hour am/pm to 24-hour format
            if [ -n "$HOUR_RAW" ]; then
                if [ "$AMPM" = "pm" ] && [ "$HOUR_RAW" -lt 12 ]; then
                    HOUR_24=$(( HOUR_RAW + 12 ))
                elif [ "$AMPM" = "am" ] && [ "$HOUR_RAW" -eq 12 ]; then
                    HOUR_24=0
                else
                    HOUR_24=$HOUR_RAW
                fi
                DATE_PART="${DATE_NOTIME} $(printf '%02d' $HOUR_24):00"
            fi
            WEEK_EPOCH=$(TZ=${TIMEZONE} date -d "$DATE_PART" +%s 2>/dev/null)
            [ -n "$WEEK_EPOCH" ] && \
                WEEK_RESET_LABEL=$(TZ=${TIMEZONE} date -d "@$WEEK_EPOCH" +"%a %Hh" 2>/dev/null \
                    | tr '[:upper:]' '[:lower:]')
        fi

        [ -n "$WEEK_RESET_LABEL" ] \
            && WEEK_DISPLAY="📅 ~${WEEK_INT}% (${WEEK_RESET_LABEL})" \
            || WEEK_DISPLAY="📅 ~${WEEK_INT}%"
    fi
fi

# ── Assemble the final status line, joining parts with " │ " ─────────────────
PARTS=()
[ -n "$BRANCH" ]        && PARTS+=("🌿 $BRANCH")
[ -n "$MODEL" ]         && PARTS+=("🤖 $MODEL")
[ -n "$CTX_PERCENT" ]   && PARTS+=("$COLOR Ctx: $BAR ${CTX_PERCENT}%")
[ -n "$BLOCK_DISPLAY" ] && PARTS+=("$BLOCK_DISPLAY")
[ -n "$WEEK_DISPLAY" ]  && PARTS+=("$WEEK_DISPLAY")

RESULT=""
for part in "${PARTS[@]}"; do
    [ -z "$RESULT" ] && RESULT="$part" || RESULT="$RESULT │ $part"
done

echo "$RESULT"
