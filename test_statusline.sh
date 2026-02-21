#!/bin/bash
# Tests for statusline.sh

STATUSLINE_SH="$(dirname "$(realpath "$0")")/statusline.sh"
PASS=0; FAIL=0

# Track temp files for cleanup
TMPFILES=()
cleanup_tests() {
    for f in "${TMPFILES[@]}"; do rm -f "$f"; done
}
trap cleanup_tests EXIT INT TERM

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $desc"; ((PASS++))
    else
        echo "  ✗ $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        ((FAIL++))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $desc"; ((PASS++))
    else
        echo "  ✗ $desc"
        echo "    expected to contain: $needle"
        echo "    actual: $haystack"
        ((FAIL++))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $desc"; ((PASS++))
    else
        echo "  ✗ $desc"
        echo "    expected NOT to contain: $needle"
        echo "    actual: $haystack"
        ((FAIL++))
    fi
}

# ── Unit tests: make_bar ──────────────────────────────────────────────────────
echo ""
echo "=== Unit tests: make_bar ==="

# Extract make_bar function from statusline.sh and source it
# Use awk to extract just the function body (up to the closing brace)
eval "$(awk '/^make_bar\(\)/,/^\}/' "$STATUSLINE_SH")"

run_make_bar() {
    BAR_STR=""; BAR_COLOR=""
    make_bar "$1"
}

count_char() {
    # Count multibyte chars: pipe through python3 to count unicode chars
    local char="$1" str="$2"
    python3 -c "print('${str}'.count('${char}'))" 2>/dev/null || echo "0"
}

# pct=0 → 8 empty blocks
run_make_bar 0
assert_eq "pct=0: BAR_STR is 8 empty blocks" "░░░░░░░░" "$BAR_STR"

# pct=100 → 8 full blocks
run_make_bar 100
assert_eq "pct=100: BAR_STR is 8 full blocks" "▓▓▓▓▓▓▓▓" "$BAR_STR"

# pct=50 → 4 full + 4 empty
run_make_bar 50
FULL_COUNT=$(echo -n "$BAR_STR" | python3 -c "import sys; s=sys.stdin.buffer.read().decode('utf-8'); print(s.count('▓'))")
EMPTY_COUNT=$(echo -n "$BAR_STR" | python3 -c "import sys; s=sys.stdin.buffer.read().decode('utf-8'); print(s.count('░'))")
assert_eq "pct=50: 4 full blocks" "4" "$FULL_COUNT"
assert_eq "pct=50: 4 empty blocks" "4" "$EMPTY_COUNT"

# pct=25 → 2 full + 6 empty
run_make_bar 25
FULL_COUNT=$(echo -n "$BAR_STR" | python3 -c "import sys; s=sys.stdin.buffer.read().decode('utf-8'); print(s.count('▓'))")
EMPTY_COUNT=$(echo -n "$BAR_STR" | python3 -c "import sys; s=sys.stdin.buffer.read().decode('utf-8'); print(s.count('░'))")
assert_eq "pct=25: 2 full blocks" "2" "$FULL_COUNT"
assert_eq "pct=25: 6 empty blocks" "6" "$EMPTY_COUNT"

# Total bar length is always 8
run_make_bar 0
TOTAL=$(echo -n "$BAR_STR" | python3 -c "import sys; s=sys.stdin.buffer.read().decode('utf-8'); print(len(s))")
assert_eq "pct=0: total bar length 8" "8" "$TOTAL"

run_make_bar 100
TOTAL=$(echo -n "$BAR_STR" | python3 -c "import sys; s=sys.stdin.buffer.read().decode('utf-8'); print(len(s))")
assert_eq "pct=100: total bar length 8" "8" "$TOTAL"

run_make_bar 50
TOTAL=$(echo -n "$BAR_STR" | python3 -c "import sys; s=sys.stdin.buffer.read().decode('utf-8'); print(len(s))")
assert_eq "pct=50: total bar length 8" "8" "$TOTAL"

# Color thresholds
run_make_bar 0
assert_eq "pct=0:   BAR_COLOR is green"  "🟢" "$BAR_COLOR"

run_make_bar 49
assert_eq "pct=49:  BAR_COLOR is green"  "🟢" "$BAR_COLOR"

run_make_bar 50
assert_eq "pct=50:  BAR_COLOR is yellow" "🟡" "$BAR_COLOR"

run_make_bar 80
assert_eq "pct=80:  BAR_COLOR is red"    "🔴" "$BAR_COLOR"

run_make_bar 100
assert_eq "pct=100: BAR_COLOR is red"    "🔴" "$BAR_COLOR"

# ── Integration tests ─────────────────────────────────────────────────────────
echo ""
echo "=== Integration tests ==="

# Shared minimal JSON runner
run_statusline() {
    local json="$1"
    shift
    echo "$json" | env "$@" bash "$STATUSLINE_SH" 2>/dev/null
}

# Test 1 — model + context window
echo ""
echo "-- Test 1: model + context window --"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 34.5}}' \
    USAGE_FILE=/dev/null)
assert_contains "contains 'Sonnet 4.6'" "Sonnet 4.6" "$OUT"
assert_contains "contains '34%'" "34%" "$OUT"

# Test 2 — Opus model + git branch
echo ""
echo "-- Test 2: Opus model + git branch --"
REPO_DIR="/home/odilon/work/claude-code-statusline"
GIT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null)
OUT=$(run_statusline "{\"model\": \"claude-opus-4-6\", \"context_window\": {\"used_percentage\": 0}, \"workspace\": {\"current_dir\": \"$REPO_DIR\"}}" \
    USAGE_FILE=/dev/null)
assert_contains "contains 'Opus 4.6'" "Opus 4.6" "$OUT"
if [ -n "$GIT_BRANCH" ]; then
    assert_contains "contains git branch '$GIT_BRANCH'" "$GIT_BRANCH" "$OUT"
else
    echo "  (skipped: not in a git repo or branch not detectable)"
fi

# Test 3 — Usage cache: session + week_all displayed
echo ""
echo "-- Test 3: usage cache with session + week_all --"
USAGE_TMP=$(mktemp /tmp/test-usage-XXXX.json)
TMPFILES+=("$USAGE_TMP")
cat > "$USAGE_TMP" <<'JSON'
{
  "timestamp": "2026-02-21T10:00:00+00:00",
  "source": "/usage",
  "metrics": {
    "session": {
      "percent_used": 46.0,
      "percent_remaining": 54.0,
      "resets": null
    },
    "week_all": {
      "percent_used": 59.0,
      "percent_remaining": 41.0,
      "resets": null
    }
  }
}
JSON
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE="$USAGE_TMP" REFRESH_INTERVAL=999999)
assert_contains "session 46% shown"  "46%" "$OUT"
assert_contains "week_all 59% shown" "59%" "$OUT"

# Test 4 — Cache stale (30 minutes old, REFRESH_INTERVAL=300 → stale threshold 600s)
echo ""
echo "-- Test 4: stale cache shows ⚠ --"
USAGE_STALE=$(mktemp /tmp/test-usage-stale-XXXX.json)
TMPFILES+=("$USAGE_STALE")
cat > "$USAGE_STALE" <<'JSON'
{
  "timestamp": "2026-02-21T09:00:00+00:00",
  "source": "/usage",
  "metrics": {
    "session": {
      "percent_used": 30.0,
      "percent_remaining": 70.0,
      "resets": null
    }
  }
}
JSON
# Touch the file with a timestamp 30 minutes ago
touch -d '30 minutes ago' "$USAGE_STALE"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE="$USAGE_STALE" REFRESH_INTERVAL=300)
assert_contains "stale cache shows ⚠" "⚠" "$OUT"

# Test 5 — Fresh cache does NOT show ⚠
echo ""
echo "-- Test 5: fresh cache does NOT show ⚠ --"
USAGE_FRESH=$(mktemp /tmp/test-usage-fresh-XXXX.json)
TMPFILES+=("$USAGE_FRESH")
cat > "$USAGE_FRESH" <<'JSON'
{
  "timestamp": "2026-02-21T10:00:00+00:00",
  "source": "/usage",
  "metrics": {
    "session": {
      "percent_used": 20.0,
      "percent_remaining": 80.0,
      "resets": null
    }
  }
}
JSON
# File freshly created (now)
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE="$USAGE_FRESH" REFRESH_INTERVAL=300)
assert_not_contains "fresh cache does not show ⚠" "⚠" "$OUT"

# Test 6 — week_sonnet metric is shown with "Snt" suffix
echo ""
echo "-- Test 6: week_sonnet shown with Snt label --"
USAGE_SNT=$(mktemp /tmp/test-usage-snt-XXXX.json)
TMPFILES+=("$USAGE_SNT")
cat > "$USAGE_SNT" <<'JSON'
{
  "timestamp": "2026-02-21T10:00:00+00:00",
  "source": "/usage",
  "metrics": {
    "week_sonnet": {
      "percent_used": 72.0,
      "percent_remaining": 28.0,
      "resets": null
    }
  }
}
JSON
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE="$USAGE_SNT" REFRESH_INTERVAL=999999)
assert_contains "week_sonnet 72% shown"   "72%" "$OUT"
assert_contains "week_sonnet Snt label"   "Snt" "$OUT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
