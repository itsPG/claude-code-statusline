#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# Claude Code — Status Line with real-time usage tracking
#
# Self-contained: everything is in this single file, no external scripts.
# Dependencies: bash, jq, tmux, python3
# License: MIT
#
# Output format:
# 🌿 branch │ 🤖 model │ 🟢 Ctx ▓▓░░░░░░ XX% │ 🟡 ▓▓▓░░░░░ XX% → HHhMM (Xhm) │ 🔴 ▓▓▓▓░░░░ XX% (mon 14h)
#
# Install: see README.md or run install.sh
# ════════════════════════════════════════════════════════════════════════════

# ── Configuration (override via environment variables) ────────────────────────
TIMEZONE="${TIMEZONE:-}"                           # e.g. "America/New_York", empty = system default
REFRESH_INTERVAL="${REFRESH_INTERVAL:-600}"         # seconds between usage scrapes (default: 10min)
USAGE_FILE="${USAGE_FILE:-$HOME/.claude/usage-exact.json}"
LOCK_FILE="${LOCK_FILE:-/tmp/claude-usage-refresh.lock}"
TMUX_SESSION="${TMUX_SESSION:-claude-usage-bg}"

# ── Helper: run date with optional timezone (empty = system default) ──────────
tz_date() {
    local tz="$1"; shift
    if [ -n "$tz" ]; then
        TZ="$tz" date "$@"
    else
        date "$@"
    fi
}

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

# ── Reusable helper: color emoji + 8-block progress bar for a given percent ───
# Usage: make_bar <percent>
# Sets global BAR_COLOR and BAR_STR
make_bar() {
    local pct="$1"
    local filled=$(( (pct * 8 + 99) / 100 )); [ $filled -gt 8 ] && filled=8
    local empty=$(( 8 - filled ))
    BAR_STR=""
    local i
    for ((i=0; i<filled; i++)); do BAR_STR="${BAR_STR}▓"; done
    for ((i=0; i<empty;  i++)); do BAR_STR="${BAR_STR}░"; done
    if   [ "$pct" -lt 50 ]; then BAR_COLOR="🟢"
    elif [ "$pct" -lt 80 ]; then BAR_COLOR="🟡"
    else                         BAR_COLOR="🔴"
    fi
}

# ── Build context bar ─────────────────────────────────────────────────────────
make_bar "$CTX_PERCENT"
CTX_COLOR="$BAR_COLOR"
CTX_BAR="$BAR_STR"

# ── Git branch for the current workspace ─────────────────────────────────────
CWD=$(echo "$JSON" | jq -r '.workspace.current_dir // ""' 2>/dev/null)
BRANCH=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    BRANCH=$(git -C "$CWD" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi
[ -z "$BRANCH" ] && BRANCH="(no git)"
[ ${#BRANCH} -gt 33 ] && BRANCH="${BRANCH:0:30}..."

# ── Helper: get file modification time as epoch seconds (Linux + macOS) ───────
file_mtime() {
    local f="$1"
    if stat --version &>/dev/null; then
        # GNU stat (Linux)
        stat -c %Y "$f" 2>/dev/null || echo 0
    else
        # BSD stat (macOS)
        stat -f %m "$f" 2>/dev/null || echo 0
    fi
}

# ── Helper: age in seconds of the usage cache file ───────────────────────────
cache_age_sec() {
    [ ! -f "$USAGE_FILE" ] && echo 999999 && return
    echo $(( $(date +%s) - $(file_mtime "$USAGE_FILE") ))
}

# ── Helper: true if a scraper is already running ──────────────────────────────
scraper_running() {
    # If the tmux session exists, a scraper is active
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null && return 0
    # If lock exists but tmux is dead, check if stale
    [ ! -f "$LOCK_FILE" ] && return 1
    local age=$(( $(date +%s) - $(file_mtime "$LOCK_FILE") ))
    [ $age -le 120 ]
}

# ── Background refresh: launch a hidden tmux session that runs /usage ─────────
# Triggered when the cache is older than REFRESH_INTERVAL and no scraper is active.
if [ $(cache_age_sec) -gt "$REFRESH_INTERVAL" ]; then
    if ! scraper_running; then
        touch "$LOCK_FILE"
        # Resolve claude path now (parent shell has the correct PATH)
        CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "claude")
        # Write the scraper to a temp file and launch it fully detached
        # (Claude Code kills child processes of hooks, so we need setsid)
        SCRAPER="/tmp/.claude-usage-scraper.sh"
        cat > "$SCRAPER" <<SCRAPER_EOF
#!/bin/bash
SESSION="$TMUX_SESSION"
PANE="\$SESSION:0"

cleanup() {
    kill \$WATCHDOG_PID 2>/dev/null
    tmux kill-session -t "\$SESSION" 2>/dev/null
    rm -f "$SCRAPER"
    # Keep lock file alive (touch it) so the hook doesn't relaunch immediately
    touch "$LOCK_FILE"
}
trap cleanup EXIT INT TERM

# Global timeout: kill this scraper after 120s to prevent zombie sessions
( sleep 120; kill \$\$ 2>/dev/null ) &
WATCHDOG_PID=\$!

tmux kill-session -t "\$SESSION" 2>/dev/null
tmux new-session -d -s "\$SESSION" -x 220 -y 50 2>/dev/null || exit 1
sleep 0.5

tmux send-keys -t "\$PANE" "env -u CLAUDECODE $CLAUDE_BIN" Enter

# Phase 1: Handle trust dialog if it appears (up to 15s)
for i in \$(seq 1 15); do
    sleep 1
    content=\$(tmux capture-pane -t "\$PANE" -p 2>/dev/null)
    if echo "\$content" | grep -qi "trust.*folder\|Yes.*trust"; then
        tmux send-keys -t "\$PANE" "" Enter
        sleep 2
        break
    fi
    # Skip if Claude loaded directly (no trust dialog)
    if echo "\$content" | grep -q "Claude Code v"; then
        break
    fi
done

# Phase 2: Wait for Claude to be fully ready (splash screen loaded)
for i in \$(seq 1 60); do
    sleep 1
    content=\$(tmux capture-pane -t "\$PANE" -p 2>/dev/null)
    # The splash box with model name means Claude is interactive
    if echo "\$content" | grep -qi "Opus\|Sonnet\|Haiku\|How can\|Try "; then
        # Extra wait to ensure the input prompt is active
        sleep 2
        break
    fi
done

# Send /usage command and confirm selection
tmux send-keys -t "\$PANE" "/usage" Enter
sleep 2
tmux send-keys -t "\$PANE" "" Enter

# Poll until usage data appears (up to 30s)
for i in \$(seq 1 30); do
    sleep 1
    content=\$(tmux capture-pane -t "\$PANE" -p -S -300 2>/dev/null)
    if echo "\$content" | grep -qi "% used"; then
        break
    fi
done

RAW=\$(tmux capture-pane -t "\$PANE" -p -S -300 2>/dev/null)

# Write raw output to temp file for Python to read (avoids quoting issues)
TMPRAW="/tmp/.claude-usage-raw.txt"
echo "\$RAW" > "\$TMPRAW"

python3 -c "
import json, re
from datetime import datetime, timezone

with open('\$TMPRAW') as f:
    text = f.read()

now = datetime.now(timezone.utc).isoformat()
result = {'timestamp': now, 'source': '/usage', 'metrics': {}}

blocks = re.findall(
    r'(Current session|Current week.*?|Sonnet only.*?)\n'
    r'.*?(\d+(?:\.\d+)?)\s*%\s*used'
    r'(?:\n.*?Resets\s+(.+?)(?:\n|$))?',
    text, re.IGNORECASE | re.DOTALL
)
for label_raw, pct, resets in blocks:
    label = label_raw.strip().lower()
    pct_val = float(pct)
    if 'session' in label:
        key = 'session'
    elif 'sonnet' in label:
        key = 'week_sonnet'
    elif 'week' in label:
        key = 'week_all'
    else:
        key = re.sub(r'\W+', '_', label)
    result['metrics'][key] = {
        'percent_used': pct_val,
        'percent_remaining': round(100 - pct_val, 1),
        'resets': resets.strip() if resets else None,
    }

if result['metrics']:
    with open('$USAGE_FILE', 'w') as f:
        json.dump(result, f, indent=2)
"
rm -f "\$TMPRAW"
SCRAPER_EOF
        chmod +x "$SCRAPER"
        nohup setsid "$SCRAPER" >/dev/null 2>&1 &
    fi
fi

# ── Read cached usage metrics ─────────────────────────────────────────────────
BLOCK_DISPLAY=""
WEEK_DISPLAY=""
SONNET_DISPLAY=""

if [ -f "$USAGE_FILE" ]; then
    mapfile -t uvals < <(jq -r '
        (.metrics.session.percent_used     // ""),
        (.metrics.session.resets           // ""),
        (.metrics.week_all.percent_used    // ""),
        (.metrics.week_all.resets          // ""),
        (.metrics.week_sonnet.percent_used // "")
    ' "$USAGE_FILE" 2>/dev/null)
    U_SESS_PCT="${uvals[0]}"
    U_SESS_RESETS="${uvals[1]}"
    U_WEEK_PCT="${uvals[2]}"
    U_WEEK_RESETS="${uvals[3]}"
    U_SONNET_PCT="${uvals[4]}"

    # ── Session block: "⏱ XX% → HHhMM (Xhm)" ────────────────────────────────
    if [ -n "$U_SESS_PCT" ] && [ "$U_SESS_PCT" != "null" ]; then
        SESS_INT="${U_SESS_PCT%.*}"
        RESET_TIME="" REMAIN_STR=""

        if [ -n "$U_SESS_RESETS" ] && [ "$U_SESS_RESETS" != "null" ]; then
            # Extract timezone from the reset string, e.g. "7pm (Europe/Paris)" → "Europe/Paris"
            RESET_TZ=$(echo "$U_SESS_RESETS" | grep -oP '\(([^)]+)\)' | tr -d '()')
            [ -z "$RESET_TZ" ] && RESET_TZ="${TIMEZONE}"
            RESET_TIME_STR=$(echo "$U_SESS_RESETS" | sed 's/ *([^)]*)//')
            RESET_EPOCH=$(tz_date "${RESET_TZ}" -d "today $RESET_TIME_STR" +%s 2>/dev/null)
            NOW=$(date +%s)
            # If the reset time has already passed today, shift to tomorrow
            [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -le "$NOW" ] && \
                RESET_EPOCH=$(tz_date "${RESET_TZ}" -d "tomorrow $RESET_TIME_STR" +%s 2>/dev/null)
            if [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -gt "$NOW" ]; then
                # Display in user's local timezone (or TIMEZONE if set)
                RESET_TIME=$(tz_date "${TIMEZONE}" -d "@$RESET_EPOCH" +"%Hh%M" 2>/dev/null)
                REMAIN=$(( RESET_EPOCH - NOW ))
                RH=$(( REMAIN / 3600 )); RM=$(( (REMAIN % 3600) / 60 ))
                [ $RH -gt 0 ] && REMAIN_STR="${RH}h${RM}m" || REMAIN_STR="${RM}m"
            fi
        fi

        make_bar "$SESS_INT"
        if [ -n "$RESET_TIME" ] && [ -n "$REMAIN_STR" ]; then
            BLOCK_DISPLAY="${BAR_COLOR} ${BAR_STR} ${SESS_INT}% → ${RESET_TIME} (${REMAIN_STR})"
        elif [ -n "$RESET_TIME" ]; then
            BLOCK_DISPLAY="${BAR_COLOR} ${BAR_STR} ${SESS_INT}% → ${RESET_TIME}"
        else
            BLOCK_DISPLAY="${BAR_COLOR} ${BAR_STR} ${SESS_INT}%"
        fi
    fi

    # ── Weekly block: "📅 ~XX% (mon 14h)" ────────────────────────────────────
    if [ -n "$U_WEEK_PCT" ] && [ "$U_WEEK_PCT" != "null" ]; then
        WEEK_INT="${U_WEEK_PCT%.*}"
        WEEK_RESET_LABEL=""

        if [ -n "$U_WEEK_RESETS" ] && [ "$U_WEEK_RESETS" != "null" ]; then
            # Extract timezone from reset string, e.g. "Feb 23, 2pm (Europe/Paris)"
            WEEK_TZ=$(echo "$U_WEEK_RESETS" | grep -oP '\(([^)]+)\)' | tr -d '()')
            [ -z "$WEEK_TZ" ] && WEEK_TZ="${TIMEZONE}"
            # Strip timezone annotation and let date parse directly (handles "Feb 23, 1:59pm")
            DATE_PART=$(echo "$U_WEEK_RESETS" | sed 's/ *([^)]*)//' | sed 's/,//')
            WEEK_EPOCH=$(tz_date "${WEEK_TZ}" -d "$DATE_PART" +%s 2>/dev/null)
            [ -n "$WEEK_EPOCH" ] && \
                WEEK_RESET_LABEL=$(tz_date "${TIMEZONE}" -d "@$WEEK_EPOCH" +"%a %Hh" 2>/dev/null \
                    | tr '[:upper:]' '[:lower:]')
        fi

        make_bar "$WEEK_INT"
        [ -n "$WEEK_RESET_LABEL" ] \
            && WEEK_DISPLAY="${BAR_COLOR} ${BAR_STR} ${WEEK_INT}% (${WEEK_RESET_LABEL})" \
            || WEEK_DISPLAY="${BAR_COLOR} ${BAR_STR} ${WEEK_INT}%"
    fi

    # ── Sonnet weekly block: "🟢 ▓▓░░░░░░ XX% Snt" ───────────────────────────
    if [ -n "$U_SONNET_PCT" ] && [ "$U_SONNET_PCT" != "null" ]; then
        SONNET_INT="${U_SONNET_PCT%.*}"
        make_bar "$SONNET_INT"
        SONNET_DISPLAY="${BAR_COLOR} ${BAR_STR} ${SONNET_INT}% Snt"
    fi
fi

# ── Stale cache indicator ─────────────────────────────────────────────────────
STALE_SUFFIX=""
if [ -f "$USAGE_FILE" ]; then
    AGE=$(cache_age_sec)
    if [ "$AGE" -gt $(( REFRESH_INTERVAL * 2 )) ]; then
        STALE_SUFFIX=" ⚠"
    fi
fi
[ -n "$BLOCK_DISPLAY"  ] && BLOCK_DISPLAY="${BLOCK_DISPLAY}${STALE_SUFFIX}"
[ -n "$WEEK_DISPLAY"   ] && WEEK_DISPLAY="${WEEK_DISPLAY}${STALE_SUFFIX}"
[ -n "$SONNET_DISPLAY" ] && SONNET_DISPLAY="${SONNET_DISPLAY}${STALE_SUFFIX}"

# ── Assemble the final status line, joining parts with " │ " ─────────────────
PARTS=()
[ -n "$BRANCH" ]          && PARTS+=("🌿 $BRANCH")
[ -n "$MODEL" ]           && PARTS+=("🤖 $MODEL")
[ -n "$CTX_PERCENT" ]     && PARTS+=("$CTX_COLOR Ctx $CTX_BAR ${CTX_PERCENT}%")
[ -n "$BLOCK_DISPLAY" ]   && PARTS+=("$BLOCK_DISPLAY")
[ -n "$SONNET_DISPLAY" ]  && PARTS+=("$SONNET_DISPLAY")
[ -n "$WEEK_DISPLAY" ]    && PARTS+=("$WEEK_DISPLAY")

RESULT=""
for part in "${PARTS[@]}"; do
    [ -z "$RESULT" ] && RESULT="$part" || RESULT="$RESULT │ $part"
done

echo "$RESULT"
