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
eval "$(awk '/^make_bar\(\)/,/^\}/' "$STATUSLINE_SH")"

run_make_bar() {
    BAR_STR=""; BAR_COLOR=""
    make_bar "$1"
}

# Count unicode characters (no python dependency)
count_char() {
    local char="$1" str="$2"
    echo -n "$str" | grep -o "$char" | wc -l
}

# pct=0 → 5 empty blocks
run_make_bar 0
assert_eq "pct=0: BAR_STR is 5 empty blocks" "░░░░░" "$BAR_STR"

# pct=100 → 5 full blocks
run_make_bar 100
assert_eq "pct=100: BAR_STR is 5 full blocks" "▓▓▓▓▓" "$BAR_STR"

# pct=50 → 3 full blocks
run_make_bar 50
FULL_COUNT=$(count_char "▓" "$BAR_STR")
EMPTY_COUNT=$(count_char "░" "$BAR_STR")
TOTAL=$((FULL_COUNT + EMPTY_COUNT))
assert_eq "pct=50: total bar length 5" "5" "$TOTAL"
assert_eq "pct=50: 3 full blocks" "3" "$FULL_COUNT"

# pct=25 → 2 full blocks
run_make_bar 25
FULL_COUNT=$(count_char "▓" "$BAR_STR")
assert_eq "pct=25: 2 full blocks" "2" "$FULL_COUNT"

# Total bar length is always 5
for pct in 0 1 20 50 75 99 100; do
    run_make_bar $pct
    TOTAL=$(count_char "▓" "$BAR_STR")
    TOTAL=$((TOTAL + $(count_char "░" "$BAR_STR")))
    assert_eq "pct=$pct: total bar length 5" "5" "$TOTAL"
done

# Color thresholds
run_make_bar 0
assert_eq "pct=0:   BAR_COLOR is green"  "🟢" "$BAR_COLOR"

run_make_bar 49
assert_eq "pct=49:  BAR_COLOR is green"  "🟢" "$BAR_COLOR"

run_make_bar 50
assert_eq "pct=50:  BAR_COLOR is yellow" "🟡" "$BAR_COLOR"

run_make_bar 79
assert_eq "pct=79:  BAR_COLOR is yellow" "🟡" "$BAR_COLOR"

run_make_bar 80
assert_eq "pct=80:  BAR_COLOR is red"    "🔴" "$BAR_COLOR"

run_make_bar 100
assert_eq "pct=100: BAR_COLOR is red"    "🔴" "$BAR_COLOR"

echo ""
echo "-- Edge cases: clamping --"
run_make_bar 0
assert_eq "pct=0: all empty" "░░░░░" "$BAR_STR"
assert_eq "pct=0: green" "🟢" "$BAR_COLOR"

run_make_bar 1
assert_contains "pct=1: has filled block" "▓" "$BAR_STR"

# ── Integration tests ─────────────────────────────────────────────────────────
echo ""
echo "=== Integration tests ==="

# Shared minimal JSON runner
run_statusline() {
    local json="$1"
    shift
    echo "$json" | env "$@" CREDENTIALS_FILE=/dev/null bash "$STATUSLINE_SH" 2>/dev/null
}

# Test 1 — model + context window
echo ""
echo "-- Test 1: model + context window --"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 34.5}}' \
    USAGE_FILE=/dev/null)
assert_contains "contains model name" "Snt 4.6" "$OUT"
assert_contains "contains '34%'" "34%" "$OUT"

# Test 2 — Opus model + git branch
echo ""
echo "-- Test 2: Opus model + git branch --"
REPO_DIR="$(dirname "$(realpath "$0")")"
GIT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null)
OUT=$(run_statusline "{\"model\": \"claude-opus-4-6\", \"context_window\": {\"used_percentage\": 0}, \"workspace\": {\"current_dir\": \"$REPO_DIR\"}}" \
    USAGE_FILE=/dev/null)
assert_contains "contains 'Opus 4.6'" "Opus 4.6" "$OUT"
if [ -n "$GIT_BRANCH" ]; then
    assert_contains "contains git branch '$GIT_BRANCH'" "$GIT_BRANCH" "$OUT"
else
    echo "  (skipped: not in a git repo or branch not detectable)"
fi

# Test 3 — Legacy usage cache: session + week_all displayed
echo ""
echo "-- Test 3: legacy cache with session + week_all --"
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
    USAGE_FILE="$USAGE_TMP" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains     "session 46% shown"            "46%" "$OUT"
assert_contains     "week_all 59% shown"           "59%" "$OUT"

# Test 4 — API format cache with ISO 8601 resets_at
echo ""
echo "-- Test 4: API cache with ISO 8601 resets_at --"
USAGE_API=$(mktemp /tmp/test-usage-api-XXXX.json)
TMPFILES+=("$USAGE_API")
# Use a future reset time
FUTURE=$(date -d "+3 hours" -Iseconds 2>/dev/null || date -v+3H -Iseconds 2>/dev/null)
cat > "$USAGE_API" <<JSON
{
  "timestamp": "2026-02-21T10:00:00Z",
  "source": "api",
  "metrics": {
    "session": {
      "percent_used": 35.0,
      "percent_remaining": 65.0,
      "resets_at": "$FUTURE"
    },
    "week_all": {
      "percent_used": 22.0,
      "percent_remaining": 78.0,
      "resets_at": "2026-04-02T13:00:00+00:00"
    },
    "week_sonnet": {
      "percent_used": 15.0,
      "percent_remaining": 85.0,
      "resets_at": "2026-04-02T13:00:00+00:00"
    }
  }
}
JSON
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE="$USAGE_API" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains     "API session 35% shown"        "35%" "$OUT"
assert_contains     "API week_all 22% shown"       "22%" "$OUT"
assert_contains     "API week_sonnet 15% shown"    "15%" "$OUT"
assert_contains     "has countdown"                "h"   "$OUT"

# Test 5 — Stale cache shows ⚠
echo ""
echo "-- Test 5: stale cache shows ⚠ --"
USAGE_STALE=$(mktemp /tmp/test-usage-stale-XXXX.json)
TMPFILES+=("$USAGE_STALE")
cat > "$USAGE_STALE" <<'JSON'
{
  "timestamp": "2026-02-21T09:00:00+00:00",
  "source": "api",
  "metrics": {
    "session": {
      "percent_used": 30.0,
      "percent_remaining": 70.0,
      "resets_at": null
    }
  }
}
JSON
touch -d '30 minutes ago' "$USAGE_STALE"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE="$USAGE_STALE" REFRESH_INTERVAL=300)
assert_contains "stale cache shows ⚠" "⚠" "$OUT"

# Test 6 — Fresh cache does NOT show ⚠
echo ""
echo "-- Test 6: fresh cache does NOT show ⚠ --"
USAGE_FRESH=$(mktemp /tmp/test-usage-fresh-XXXX.json)
TMPFILES+=("$USAGE_FRESH")
cat > "$USAGE_FRESH" <<'JSON'
{
  "timestamp": "2026-02-21T10:00:00+00:00",
  "source": "api",
  "metrics": {
    "session": {
      "percent_used": 20.0,
      "percent_remaining": 80.0,
      "resets_at": null
    }
  }
}
JSON
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE="$USAGE_FRESH" REFRESH_INTERVAL=300)
assert_not_contains "fresh cache does not show ⚠" "⚠" "$OUT"

# Test 7 — week_sonnet shown
echo ""
echo "-- Test 7: week_sonnet shown --"
USAGE_SNT=$(mktemp /tmp/test-usage-snt-XXXX.json)
TMPFILES+=("$USAGE_SNT")
cat > "$USAGE_SNT" <<'JSON'
{
  "timestamp": "2026-02-21T10:00:00+00:00",
  "source": "api",
  "metrics": {
    "week_sonnet": {
      "percent_used": 72.0,
      "percent_remaining": 28.0,
      "resets_at": null
    }
  }
}
JSON
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE="$USAGE_SNT" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "week_sonnet 72% shown" "72%" "$OUT"
assert_contains "week_sonnet Snt shown" "Snt" "$OUT"

# Test 8 — Haiku model detection
echo ""
echo "-- Test 8: Haiku model detection --"
OUT=$(run_statusline '{"model": "claude-haiku-4-5-20251001", "context_window": {"used_percentage": 10}}' \
    USAGE_FILE=/dev/null)
assert_contains "contains 'Haiku 4'" "Haiku 4" "$OUT"

# Test 9 — Display name with "Default (...)" wrapper
echo ""
echo "-- Test 9: display_name Default() unwrap --"
OUT=$(run_statusline '{"model": {"display_name": "Default (Claude Sonnet 4.5)"}, "context_window": {"used_percentage": 0}}' \
    USAGE_FILE=/dev/null)
assert_contains "unwraps Default() to 'Snt 4.5'" "Snt 4.5" "$OUT"

# Test 10 — Context bar at 0% is all empty blocks
echo ""
echo "-- Test 10: context bar at 0% --"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 0}}' \
    USAGE_FILE=/dev/null)
assert_contains "0% bar is all empty" "░░░░░" "$OUT"

# Test 11 — Context bar at 100% is all full blocks
echo ""
echo "-- Test 11: context bar at 100% --"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 100}}' \
    USAGE_FILE=/dev/null)
assert_contains "100% bar is all full" "▓▓▓▓▓" "$OUT"

# Test 12 — Missing usage file shows no usage data
echo ""
echo "-- Test 12: missing usage file shows no usage bars --"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 20}}' \
    USAGE_FILE=/tmp/nonexistent-file-xxxxx.json)
assert_not_contains "no usage bars without cache" "⏳" "$OUT"
assert_not_contains "no weekly bars without cache" "📅" "$OUT"

# Test 13 — Branch emoji always present
echo ""
echo "-- Test 13: branch emoji present --"
OUT=$(run_statusline "{\"model\": \"claude-sonnet-4-6\", \"context_window\": {\"used_percentage\": 0}, \"workspace\": {\"current_dir\": \"$REPO_DIR\"}}" \
    USAGE_FILE=/dev/null)
assert_contains "branch emoji present" "🌿" "$OUT"

# Test 14 — All three metrics displayed together
echo ""
echo "-- Test 14: session + week + sonnet all shown --"
USAGE_ALL=$(mktemp /tmp/test-usage-all-XXXX.json)
TMPFILES+=("$USAGE_ALL")
cat > "$USAGE_ALL" <<'JSON'
{
  "timestamp": "2026-02-21T10:00:00+00:00",
  "source": "api",
  "metrics": {
    "session": {"percent_used": 30.0, "percent_remaining": 70.0, "resets_at": null},
    "week_all": {"percent_used": 60.0, "percent_remaining": 40.0, "resets_at": null},
    "week_sonnet": {"percent_used": 45.0, "percent_remaining": 55.0, "resets_at": null}
  }
}
JSON
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 10}}' \
    USAGE_FILE="$USAGE_ALL" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains     "session 30%"              "30%" "$OUT"
assert_contains     "week_all 60% shown"       "60%" "$OUT"
assert_contains     "week_sonnet 45% shown"    "45%" "$OUT"
assert_contains     "separator present"        "│"   "$OUT"

# Test 15 — Display name parenthetical stripped
echo ""
echo "-- Test 15: display_name strips parenthetical --"
OUT=$(run_statusline '{"model": {"display_name": "Claude Opus 4.6 (some info)"}, "context_window": {"used_percentage": 0}}' \
    USAGE_FILE=/dev/null)
assert_contains "shows 'Opus 4.6'" "Opus 4.6" "$OUT"
assert_not_contains "strips parenthetical" "(some info)" "$OUT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
