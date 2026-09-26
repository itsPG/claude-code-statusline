#!/bin/bash
# Tests for statusline.sh

STATUSLINE_SH="$(dirname "$(realpath "$0")")/statusline.sh"
PASS=0; FAIL=0

# Track temp files for cleanup
TMPFILES=()
cleanup_tests() {
    for f in "${TMPFILES[@]}"; do rm -f "$f"; done
    [ -n "$TEST_RUNTIME_DIR" ] && rm -rf "$TEST_RUNTIME_DIR"
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

assert_absent() {  # fail if <path> exists — for injection canaries
    local desc="$1" path="$2"
    if [ -e "$path" ]; then
        echo "  ✗ $desc (canary $path was created)"; ((FAIL++))
    else
        echo "  ✓ $desc"; ((PASS++))
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

# Extract make_bar (and the num helper it depends on) from statusline.sh and source them
eval "$(awk '/^num\(\)/,/^\}/' "$STATUSLINE_SH")"
eval "$(awk '/^make_bar\(\)/,/^\}/' "$STATUSLINE_SH")"

run_make_bar() {
    BAR_STR=""; BAR_COLOR=""
    make_bar "$1"
}

count_char() {
    local char="$1" str="$2"
    echo -n "$str" | grep -o "$char" | wc -l | tr -d ' '
}

# pct=0 → 6 empty blocks
run_make_bar 0
assert_eq "pct=0: all empty" "░░░░░░" "$BAR_STR"

# pct=100 → 6 full blocks
run_make_bar 100
assert_eq "pct=100: all full" "▓▓▓▓▓▓" "$BAR_STR"

# pct=50 → 3 full blocks
run_make_bar 50
FULL_COUNT=$(count_char "▓" "$BAR_STR")
assert_eq "pct=50: 3 full blocks" "3" "$FULL_COUNT"

# pct=25 → 2 full blocks
run_make_bar 25
FULL_COUNT=$(count_char "▓" "$BAR_STR")
assert_eq "pct=25: 2 full blocks" "2" "$FULL_COUNT"

# Total bar length is always 6
for pct in 0 1 17 34 50 68 85 99 100; do
    run_make_bar $pct
    TOTAL=$(count_char "▓" "$BAR_STR")
    TOTAL=$((TOTAL + $(count_char "░" "$BAR_STR")))
    assert_eq "pct=$pct: total bar length 6" "6" "$TOTAL"
done

# Color thresholds
run_make_bar 0;   assert_eq "pct=0: blue"     "🔵" "$BAR_COLOR"
run_make_bar 19;  assert_eq "pct=19: blue"    "🔵" "$BAR_COLOR"
run_make_bar 20;  assert_eq "pct=20: green"   "🟢" "$BAR_COLOR"
run_make_bar 49;  assert_eq "pct=49: green"   "🟢" "$BAR_COLOR"
run_make_bar 50;  assert_eq "pct=50: yellow"  "🟡" "$BAR_COLOR"
run_make_bar 69;  assert_eq "pct=69: yellow"  "🟡" "$BAR_COLOR"
run_make_bar 70;  assert_eq "pct=70: orange"  "🟠" "$BAR_COLOR"
run_make_bar 84;  assert_eq "pct=84: orange"  "🟠" "$BAR_COLOR"
run_make_bar 85;  assert_eq "pct=85: red"     "🔴" "$BAR_COLOR"
run_make_bar 100; assert_eq "pct=100: red"    "🔴" "$BAR_COLOR"

echo ""
echo "-- Edge cases --"
run_make_bar 1
assert_contains "pct=1: has filled block" "▓" "$BAR_STR"

# ── Unit tests: num (arithmetic injection guard) ─────────────────────────────
echo ""
echo "=== Unit tests: num ==="
assert_eq "num strips decimal"        "46" "$(num 46.0)"
assert_eq "num plain integer"         "42" "$(num 42)"
assert_eq "num leading zero (octal)"  "8"  "$(num 08)"
assert_eq "num empty → 0"             "0"  "$(num '')"
assert_eq "num non-numeric → 0"       "0"  "$(num 'abc')"
# Digit-free canary path, so the expected output is exactly 0 (num keeps digits)
rm -f /tmp/statusline-num-canary
# shellcheck disable=SC2016  # the payload must stay a literal string
assert_eq "num neutralizes injection" "0"  "$(num 'x[$(touch /tmp/statusline-num-canary)]')"
assert_absent "num did not execute payload" "/tmp/statusline-num-canary"

# ── Integration tests ─────────────────────────────────────────────────────────
echo ""
echo "=== Integration tests ==="

# Isolate from the real ~/.claude: no settings.json effort, lock file in a temp dir.
# Per-test env args come after the defaults, so they can still override them.
TEST_RUNTIME_DIR=$(mktemp -d /tmp/test-runtime-XXXX)
run_statusline() {
    local json="$1"; shift
    echo "$json" | env SETTINGS_FILE=/dev/null XDG_RUNTIME_DIR="$TEST_RUNTIME_DIR" "$@" \
        CREDENTIALS_FILE=/dev/null bash "$STATUSLINE_SH" 2>/dev/null
}

# Test 1 — model + context window
echo ""
echo "-- Test 1: model + context window --"
OUT=$(run_statusline '{"model": "claude-sonnet-4-6", "context_window": {"used_percentage": 34.5}}' \
    USAGE_FILE=/dev/null)
assert_contains "model name" "Snt 4.6" "$OUT"
assert_contains "34%" "34%" "$OUT"

# Test 2 — Opus model + git branch
echo ""
echo "-- Test 2: Opus model + git branch --"
REPO_DIR="$(dirname "$(realpath "$0")")"
GIT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null)
OUT=$(run_statusline "{\"model\": \"claude-opus-4-6\", \"context_window\": {\"used_percentage\": 0}, \"workspace\": {\"current_dir\": \"$REPO_DIR\"}}" \
    USAGE_FILE=/dev/null)
assert_contains "Opus 4.6" "Opus 4.6" "$OUT"
assert_not_contains "no git branch" "🌿" "$OUT"

# Test 3 — Legacy cache with session + week_all
echo ""
echo "-- Test 3: legacy cache --"
USAGE_TMP=$(mktemp /tmp/test-usage-XXXX.json); TMPFILES+=("$USAGE_TMP")
cat > "$USAGE_TMP" <<'JSON'
{"timestamp":"2026-02-21T10:00:00+00:00","source":"/usage","metrics":{"session":{"percent_used":46.0,"percent_remaining":54.0,"resets":null},"week_all":{"percent_used":59.0,"percent_remaining":41.0,"resets":null}}}
JSON
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_TMP" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "session 46%" "46%" "$OUT"
assert_contains "week_all 59%" "59%" "$OUT"

# Test 4 — API cache with ISO 8601 resets_at
echo ""
echo "-- Test 4: API cache with ISO 8601 --"
USAGE_API=$(mktemp /tmp/test-usage-api-XXXX.json); TMPFILES+=("$USAGE_API")
FUTURE=$(date -d "+3 hours" -Iseconds 2>/dev/null || date -v+3H -Iseconds 2>/dev/null)
cat > "$USAGE_API" <<JSON
{"timestamp":"2026-02-21T10:00:00Z","source":"api","metrics":{"session":{"percent_used":35.0,"percent_remaining":65.0,"resets_at":"$FUTURE"},"week_all":{"percent_used":22.0,"percent_remaining":78.0,"resets_at":"2026-04-02T13:00:00+00:00"},"week_sonnet":{"percent_used":15.0,"percent_remaining":85.0,"resets_at":"2026-04-02T13:00:00+00:00"}}}
JSON
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_API" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "API session 35%" "35%" "$OUT"
assert_contains "API week_all 22%" "22%" "$OUT"
assert_not_contains "API sonnet hidden" "15%" "$OUT"
assert_contains "has countdown" "h" "$OUT"

# Test 5 — Stale cache shows ⚠
echo ""
echo "-- Test 5: stale cache --"
USAGE_STALE=$(mktemp /tmp/test-usage-stale-XXXX.json); TMPFILES+=("$USAGE_STALE")
echo '{"timestamp":"2026-02-21T09:00:00+00:00","source":"api","metrics":{"session":{"percent_used":30.0,"percent_remaining":70.0,"resets_at":null}}}' > "$USAGE_STALE"
_stale_ts=$(date -v-30M +%Y%m%d%H%M.%S 2>/dev/null || date -d '30 minutes ago' +%Y%m%d%H%M.%S 2>/dev/null)
touch -t "$_stale_ts" "$USAGE_STALE"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_STALE" REFRESH_INTERVAL=300)
assert_contains "stale cache shows ⚠" "⚠" "$OUT"

# Test 6 — Fresh cache does NOT show ⚠
echo ""
echo "-- Test 6: fresh cache no ⚠ --"
USAGE_FRESH=$(mktemp /tmp/test-usage-fresh-XXXX.json); TMPFILES+=("$USAGE_FRESH")
echo '{"timestamp":"2026-02-21T10:00:00+00:00","source":"api","metrics":{"session":{"percent_used":20.0,"percent_remaining":80.0,"resets_at":null}}}' > "$USAGE_FRESH"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_FRESH" REFRESH_INTERVAL=300)
assert_not_contains "fresh cache no ⚠" "⚠" "$OUT"

# Test 7 — REFRESH_INTERVAL=0 never shows ⚠
echo ""
echo "-- Test 7: REFRESH_INTERVAL=0 no stale indicator --"
touch -t "$_stale_ts" "$USAGE_STALE"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_STALE" REFRESH_INTERVAL=0)
assert_not_contains "interval=0 no ⚠" "⚠" "$OUT"

# Test 8 — week_sonnet-only cache hides sonnet (only week_all is shown)
echo ""
echo "-- Test 8: week_sonnet --"
USAGE_SNT=$(mktemp /tmp/test-usage-snt-XXXX.json); TMPFILES+=("$USAGE_SNT")
echo '{"timestamp":"2026-02-21T10:00:00+00:00","source":"api","metrics":{"week_sonnet":{"percent_used":72.0,"percent_remaining":28.0,"resets_at":null}}}' > "$USAGE_SNT"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_SNT" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_not_contains "sonnet hidden" "72%" "$OUT"
assert_not_contains "Snt label hidden" "📅" "$OUT"

# Test 9 — Haiku model
echo ""
echo "-- Test 9: Haiku model --"
OUT=$(run_statusline '{"model":"claude-haiku-4-5-20251001","context_window":{"used_percentage":10}}' \
    USAGE_FILE=/dev/null)
assert_contains "Haiku 4" "Haiku 4" "$OUT"

# Test 10 — Default() unwrap
echo ""
echo "-- Test 10: Default() unwrap --"
OUT=$(run_statusline '{"model":{"display_name":"Default (Claude Sonnet 4.5)"},"context_window":{"used_percentage":0}}' \
    USAGE_FILE=/dev/null)
assert_contains "unwraps to Snt 4.5" "Snt 4.5" "$OUT"

# Test 11 — Context color at 0% / 100%
echo ""
echo "-- Test 11: context colors --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' USAGE_FILE=/dev/null)
assert_contains "0% blue" "🔵" "$OUT"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":100}}' USAGE_FILE=/dev/null)
assert_contains "100% red" "🔴" "$OUT"

# Test 12 — Missing usage file
echo ""
echo "-- Test 12: no cache --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":20}}' \
    USAGE_FILE=/tmp/nonexistent-xxxxx.json)
assert_not_contains "no ⏳" "⏳" "$OUT"
assert_not_contains "no 📅" "📅" "$OUT"

# Test 13 — Branch emoji absent
echo ""
echo "-- Test 13: branch emoji --"
OUT=$(run_statusline "{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":0},\"workspace\":{\"current_dir\":\"$REPO_DIR\"}}" \
    USAGE_FILE=/dev/null)
assert_not_contains "🌿 absent" "🌿" "$OUT"

# Test 14 — All metrics together
echo ""
echo "-- Test 14: all metrics --"
USAGE_ALL=$(mktemp /tmp/test-usage-all-XXXX.json); TMPFILES+=("$USAGE_ALL")
echo '{"timestamp":"2026-02-21T10:00:00+00:00","source":"api","metrics":{"session":{"percent_used":30.0,"percent_remaining":70.0,"resets_at":null},"week_all":{"percent_used":60.0,"percent_remaining":40.0,"resets_at":null},"week_sonnet":{"percent_used":45.0,"percent_remaining":55.0,"resets_at":null}}}' > "$USAGE_ALL"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":10}}' \
    USAGE_FILE="$USAGE_ALL" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1)
assert_contains "session 30%" "30%" "$OUT"
assert_contains "week 60%" "60%" "$OUT"
assert_not_contains "sonnet hidden" "45%" "$OUT"
assert_contains "separator" "│" "$OUT"

# Test 15 — Parenthetical stripped
echo ""
echo "-- Test 15: strip parenthetical --"
OUT=$(run_statusline '{"model":{"display_name":"Claude Opus 4.6 (some info)"},"context_window":{"used_percentage":0}}' \
    USAGE_FILE=/dev/null)
assert_contains "Opus 4.6" "Opus 4.6" "$OUT"
assert_not_contains "no parens" "(some info)" "$OUT"

# Test 16 — Cost + duration
echo ""
echo "-- Test 16: cost + duration --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":20},"cost":{"total_cost_usd":1.234,"total_duration_ms":3720000}}' \
    USAGE_FILE=/dev/null)
assert_contains "cost shown" '$1.23' "$OUT"
assert_contains "duration shown" "⏱" "$OUT"
assert_contains "duration value" "1h2m" "$OUT"

# Test 17 — No cost when zero
echo ""
echo "-- Test 17: no cost when zero --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":20},"cost":{"total_cost_usd":0,"total_duration_ms":0}}' \
    USAGE_FILE=/dev/null)
assert_not_contains "no dollar" '$' "$OUT"
assert_not_contains "no timer" "⏱" "$OUT"

# Test 18 — 1M context label
echo ""
echo "-- Test 18: 1M context label --"
OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":30,"context_window_size":1000000}}' \
    USAGE_FILE=/dev/null)
assert_contains "1M label" "1M" "$OUT"
assert_not_contains "no Ctx label" "Ctx" "$OUT"

# Test 19 — Regular context stays "Ctx"
echo ""
echo "-- Test 19: Ctx label for 200k --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":30,"context_window_size":200000}}' \
    USAGE_FILE=/dev/null)
assert_contains "Ctx label" "Ctx" "$OUT"

# Test 20 — 1M context stricter color thresholds
echo ""
echo "-- Test 20: 1M context colors --"
OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":10,"context_window_size":1000000}}' USAGE_FILE=/dev/null)
assert_contains "1M 10% blue" "🔵" "$OUT"

OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":15,"context_window_size":1000000}}' USAGE_FILE=/dev/null)
assert_contains "1M 15% green" "🟢" "$OUT"

OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":35,"context_window_size":1000000}}' USAGE_FILE=/dev/null)
assert_contains "1M 35% yellow" "🟡" "$OUT"

OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":45,"context_window_size":1000000}}' USAGE_FILE=/dev/null)
assert_contains "1M 45% orange" "🟠" "$OUT"

OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":55,"context_window_size":1000000}}' USAGE_FILE=/dev/null)
assert_contains "1M 55% red" "🔴" "$OUT"

OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":75,"context_window_size":1000000}}' USAGE_FILE=/dev/null)
assert_contains "1M 75% purple" "🟣" "$OUT"

# Test 21 — 2M context label + stricter colors
echo ""
echo "-- Test 21: 2M context --"
OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":30,"context_window_size":2000000}}' USAGE_FILE=/dev/null)
assert_contains "2M label" "2M" "$OUT"
assert_not_contains "2M no Ctx" "Ctx" "$OUT"

OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":55,"context_window_size":2000000}}' USAGE_FILE=/dev/null)
assert_contains "2M 55% red" "🔴" "$OUT"

OUT=$(run_statusline '{"model":"claude-opus-4-6","context_window":{"used_percentage":75,"context_window_size":2000000}}' USAGE_FILE=/dev/null)
assert_contains "2M 75% purple" "🟣" "$OUT"

# Verify regular context is NOT affected by 1M override
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":75,"context_window_size":200000}}' USAGE_FILE=/dev/null)
assert_contains "200k 75% orange" "🟠" "$OUT"
assert_not_contains "200k 75% no purple" "🟣" "$OUT"

# Test 22 — Per-account cache isolation
echo ""
echo "-- Test 22: per-account cache --"
CRED_A=$(mktemp /tmp/test-cred-a-XXXX.json); TMPFILES+=("$CRED_A")
CRED_B=$(mktemp /tmp/test-cred-b-XXXX.json); TMPFILES+=("$CRED_B")
echo '{"claudeAiOauth":{"accessToken":"token-aaa"}}' > "$CRED_A"
echo '{"claudeAiOauth":{"accessToken":"token-bbb"}}' > "$CRED_B"

CACHE_DIR=$(mktemp -d /tmp/test-cache-XXXX); TMPFILES+=("$CACHE_DIR")
HASH_A=$(echo -n "token-aaa" | sha256sum | cut -c1-8)
HASH_B=$(echo -n "token-bbb" | sha256sum | cut -c1-8)
CACHE_A="$CACHE_DIR/usage-${HASH_A}.json"
CACHE_B="$CACHE_DIR/usage-${HASH_B}.json"

# Seed cache for account A with 40%, account B with 80%
echo '{"timestamp":"2026-02-21T10:00:00Z","source":"api","metrics":{"session":{"percent_used":40.0,"percent_remaining":60.0,"resets_at":null}}}' > "$CACHE_A"
echo '{"timestamp":"2026-02-21T10:00:00Z","source":"api","metrics":{"session":{"percent_used":80.0,"percent_remaining":20.0,"resets_at":null}}}' > "$CACHE_B"

OUT_A=$(echo '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' | \
    env USAGE_FILE="$CACHE_DIR/usage.json" CREDENTIALS_FILE="$CRED_A" REFRESH_INTERVAL=999999 bash "$STATUSLINE_SH" 2>/dev/null)
assert_contains "account A sees 40%" "40%" "$OUT_A"
assert_not_contains "account A no 80%" "80%" "$OUT_A"

OUT_B=$(echo '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' | \
    env USAGE_FILE="$CACHE_DIR/usage.json" CREDENTIALS_FILE="$CRED_B" REFRESH_INTERVAL=999999 bash "$STATUSLINE_SH" 2>/dev/null)
assert_contains "account B sees 80%" "80%" "$OUT_B"
assert_not_contains "account B no 40%" "40%" "$OUT_B"

rm -rf "$CACHE_DIR"

# Test 23 — Extra usage displayed
echo ""
echo "-- Test 23: extra usage display --"
USAGE_EXTRA=$(mktemp /tmp/test-usage-extra-XXXX.json); TMPFILES+=("$USAGE_EXTRA")
echo '{"timestamp":"2026-02-21T10:00:00Z","source":"api","metrics":{"session":{"percent_used":50.0,"percent_remaining":50.0,"resets_at":null},"extra":{"percent_used":20.5,"used_credits":410.0,"monthly_limit":2000}}}' > "$USAGE_EXTRA"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_EXTRA" REFRESH_INTERVAL=999999 SHOW_EXTRA=1)
assert_contains "extra icon" "💳" "$OUT"
assert_contains "extra 20%" "20%" "$OUT"
assert_contains "extra used dollars" '$4.10' "$OUT"
assert_contains "extra limit dollars" '$20' "$OUT"

# Test 24 — SHOW_EXTRA=0 hides extra usage
echo ""
echo "-- Test 24: SHOW_EXTRA=0 hides extra --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE="$USAGE_EXTRA" REFRESH_INTERVAL=999999 SHOW_EXTRA=0)
assert_not_contains "extra hidden" "💳" "$OUT"

# Test 25 — Injection regression: malicious cache value must not execute
echo ""
echo "-- Test 25: arithmetic injection neutralized --"
CANARY="/tmp/statusline-pwned-$$"; rm -f "$CANARY"
USAGE_EVIL=$(mktemp /tmp/test-usage-evil-XXXX.json); TMPFILES+=("$USAGE_EVIL")
printf '{"source":"api","metrics":{"session":{"percent_used":"x[$(touch %s)]","resets_at":null},"week_all":{"percent_used":"x[$(touch %s)]","resets_at":null}}}' "$CANARY" "$CANARY" > "$USAGE_EVIL"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":42},"cost":{"total_duration_ms":"x[$(touch '"$CANARY"')]"}}' \
    USAGE_FILE="$USAGE_EVIL" REFRESH_INTERVAL=999999)
assert_absent "payload did not execute" "$CANARY"
assert_contains "ctx still rendered" "42%" "$OUT"
rm -f "$CANARY"

# Test 26 — "|" in workspace path must not shift later fields (effort.level)
echo ""
echo "-- Test 26: pipe in workspace path keeps effort --"
OUT=$(run_statusline '{"model":{"display_name":"Opus 4.7"},"context_window":{"used_percentage":42},"workspace":{"current_dir":"/tmp/a|b"},"effort":{"level":"high"}}' \
    USAGE_FILE=/dev/null)
assert_contains "effort kept" "Opus 4.7/hi" "$OUT"
OUT=$(run_statusline '{"model":{"display_name":"Foo|Bar"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":1.5}}' \
    USAGE_FILE=/dev/null)
assert_contains "ctx still 42%" "42%" "$OUT"
assert_contains "cost still parsed" '$1.50' "$OUT"

# Test 27 — OSC injection: control bytes stripped from model name
echo ""
echo "-- Test 27: OSC injection stripped --"
# Write the JSON to a file so the shell never handles the raw ESC byte.
OSC_TMP=$(mktemp /tmp/test-osc-XXXX.json); TMPFILES+=("$OSC_TMP")
printf '%s' '{"model":{"display_name":"\u001b]0;PWNED\u0007"},"context_window":{"used_percentage":42}}' > "$OSC_TMP"
OUT=$(CREDENTIALS_FILE=/dev/null USAGE_FILE=/dev/null SETTINGS_FILE=/dev/null bash "$STATUSLINE_SH" < "$OSC_TMP" 2>/dev/null)
assert_not_contains "no ESC byte in output" "$(printf '\x1b')" "$OUT"
assert_contains "context pct still rendered" "42%" "$OUT"
# C1 CSI (U+009B) and CR must be stripped too, independent of bash version / locale
printf '%s' '{"model":{"display_name":"X\u009b2J\rY"},"context_window":{"used_percentage":42}}' > "$OSC_TMP"
OUT=$(CREDENTIALS_FILE=/dev/null USAGE_FILE=/dev/null SETTINGS_FILE=/dev/null bash "$STATUSLINE_SH" < "$OSC_TMP" 2>/dev/null)
assert_contains "C1 CSI and CR stripped" "X2JY │" "$OUT"

# Test 28 — Non-numeric cost is ignored
echo ""
echo "-- Test 28: non-numeric cost ignored --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0},"cost":{"total_cost_usd":"abc"}}' \
    USAGE_FILE=/dev/null)
assert_not_contains "no cost segment" '$' "$OUT"

# Test 29 — effortLevel fallback from SETTINGS_FILE when stdin has no effort
echo ""
echo "-- Test 29: effort fallback from settings.json --"
SETTINGS_TMP=$(mktemp /tmp/test-settings-XXXX.json); TMPFILES+=("$SETTINGS_TMP")
echo '{"effortLevel":"max"}' > "$SETTINGS_TMP"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE=/dev/null SETTINGS_FILE="$SETTINGS_TMP")
assert_contains "settings max → /mx" "Snt 4.6/mx" "$OUT"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0},"effort":{"level":"low"}}' \
    USAGE_FILE=/dev/null SETTINGS_FILE="$SETTINGS_TMP")
assert_contains "stdin effort wins over settings" "Snt 4.6/lo" "$OUT"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0}}' \
    USAGE_FILE=/dev/null SETTINGS_FILE=/dev/null)
assert_not_contains "no effort suffix when absent" "Snt 4.6/" "$OUT"

# Portable helpers (GNU coreutils on Linux / BSD on macOS)
touch_ago() {  # <minutes> <file> — set mtime N minutes in the past
    local ts
    ts=$(date -d "$1 minutes ago" '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-"$1"M '+%Y%m%d%H%M.%S')
    touch -t "$ts" "$2"
}
epoch_in() {  # <±N hours> → Unix epoch seconds, N hours from now
    date -d "$1 hours" +%s 2>/dev/null || date -v"${1}"H +%s
}

# Test 30 — Native stdin rate_limits are preferred over the cache, and never stale
echo ""
echo "-- Test 30: native stdin rate_limits preferred --"
USAGE_OLD=$(mktemp /tmp/test-usage-old-XXXX.json); TMPFILES+=("$USAGE_OLD")
echo '{"source":"api","metrics":{"session":{"percent_used":88.0,"percent_remaining":12.0,"resets_at":null}}}' > "$USAGE_OLD"
touch_ago 60 "$USAGE_OLD"   # stale cache that must be ignored
FUTURE_EPOCH=$(epoch_in +2)
OUT=$(run_statusline "{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":0},\"rate_limits\":{\"five_hour\":{\"used_percentage\":12.7,\"resets_at\":$FUTURE_EPOCH}}}" \
    USAGE_FILE="$USAGE_OLD" REFRESH_INTERVAL=300)
assert_contains "uses stdin 12% with countdown" "⏳ 🔵 12% ↻ " "$OUT"   # exact minutes depend on timing
assert_not_contains "ignores cache 88%" "88%" "$OUT"
assert_not_contains "stdin source never stale" "⚠" "$OUT"

# Test 31 — stdin session WITHOUT resets_at keeps the live %, must not zero it
echo ""
echo "-- Test 31: stdin session without resets_at --"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0},"rate_limits":{"five_hour":{"used_percentage":42}}}' \
    USAGE_FILE=/dev/null REFRESH_INTERVAL=999999)
assert_contains "stdin pct kept without resets_at" "⏳ 🟢 42%" "$OUT"
assert_not_contains "no countdown without resets_at" "↻" "$OUT"

# Test 32 — Session resets to 0% once stdin resets_at is in the past
echo ""
echo "-- Test 32: stdin session reset to 0% after window rolls over --"
PAST_EPOCH=$(epoch_in -1)
OUT=$(run_statusline "{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":0},\"rate_limits\":{\"five_hour\":{\"used_percentage\":75,\"resets_at\":$PAST_EPOCH}}}" \
    USAGE_FILE=/dev/null REFRESH_INTERVAL=999999)
assert_not_contains "stale 75% suppressed" "75%" "$OUT"
assert_contains "session shows 0% after reset" "⏳ 🔵 0%" "$OUT"

# Test 33 — stdin seven_day shown with SHOW_WEEKLY=1, hidden with SHOW_WEEKLY=0
echo ""
echo "-- Test 33: stdin seven_day --"
WEEK_EPOCH_IN=$(epoch_in +50)
STDIN_7D="{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":0},\"rate_limits\":{\"five_hour\":{\"used_percentage\":10},\"seven_day\":{\"used_percentage\":37,\"resets_at\":$WEEK_EPOCH_IN}}}"
OUT=$(run_statusline "$STDIN_7D" USAGE_FILE=/dev/null SHOW_WEEKLY=1)
assert_contains "seven_day 37% with day countdown" "📅 🟢 37% ↻ 2d" "$OUT"
OUT=$(run_statusline "$STDIN_7D" USAGE_FILE=/dev/null SHOW_WEEKLY=0)
assert_not_contains "weekly hidden with SHOW_WEEKLY=0" "📅" "$OUT"

# Test 34 — Per-window fallback: stdin has five_hour only → weekly + extra from cache
echo ""
echo "-- Test 34: missing stdin window falls back to cache --"
USAGE_MIX=$(mktemp /tmp/test-usage-mix-XXXX.json); TMPFILES+=("$USAGE_MIX")
echo '{"source":"api","metrics":{"session":{"percent_used":88.0,"resets_at":null},"week_all":{"percent_used":61.0,"resets_at":null},"extra":{"percent_used":20.5,"used_credits":410.0,"monthly_limit":2000}}}' > "$USAGE_MIX"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":0},"rate_limits":{"five_hour":{"used_percentage":12}}}' \
    USAGE_FILE="$USAGE_MIX" REFRESH_INTERVAL=999999 SHOW_WEEKLY=1 SHOW_EXTRA=1)
assert_contains "session from stdin" "⏳ 🔵 12%" "$OUT"
assert_contains "weekly from cache" "📅 🟡 61%" "$OUT"
assert_contains "extra from cache" "💳 🟢 20%" "$OUT"

# Test 35 — API is called only when stdin can't cover the displayed metrics
echo ""
echo "-- Test 35: API call gating --"
GATE_DIR=$(mktemp -d /tmp/test-gate-XXXX)
cat > "$GATE_DIR/curl" <<'FAKE'
#!/bin/bash
touch "$GATE_MARKER"
echo '{"five_hour":{"utilization":50.0,"resets_at":null}}'
FAKE
printf '#!/bin/bash\necho "2.1.0 (Claude Code)"\n' > "$GATE_DIR/claude"
chmod +x "$GATE_DIR/curl" "$GATE_DIR/claude"
echo '{"claudeAiOauth":{"accessToken":"test-token"}}' > "$GATE_DIR/creds.json"
run_gated() {  # <stdin json> <extra env...> → 1 if the fake curl ran, else 0
    local json="$1"; shift
    rm -f "$GATE_DIR"/usage*.json "$GATE_DIR/called"
    echo "$json" | env PATH="$GATE_DIR:$PATH" GATE_MARKER="$GATE_DIR/called" XDG_RUNTIME_DIR="$GATE_DIR" \
        CREDENTIALS_FILE="$GATE_DIR/creds.json" USAGE_FILE="$GATE_DIR/usage.json" REFRESH_INTERVAL=0 \
        "$@" bash "$STATUSLINE_SH" >/dev/null 2>&1
    [ -e "$GATE_DIR/called" ] && echo 1 || echo 0
}
STDIN_BOTH="{\"model\":\"claude-sonnet-4-6\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":10},\"seven_day\":{\"used_percentage\":20}}}"
STDIN_5H='{"model":"claude-sonnet-4-6","rate_limits":{"five_hour":{"used_percentage":10}}}'
assert_eq "stdin covers all, SHOW_EXTRA=0 → no API" "0" "$(run_gated "$STDIN_BOTH" SHOW_WEEKLY=1 SHOW_EXTRA=0)"
assert_eq "SHOW_EXTRA=1 still needs API"            "1" "$(run_gated "$STDIN_BOTH" SHOW_WEEKLY=1 SHOW_EXTRA=1)"
assert_eq "stdin lacks seven_day → API"             "1" "$(run_gated "$STDIN_5H" SHOW_WEEKLY=1 SHOW_EXTRA=0)"
assert_eq "no weekly wanted, five_hour only → no API" "0" "$(run_gated "$STDIN_5H" SHOW_WEEKLY=0 SHOW_EXTRA=0)"
assert_eq "no stdin rate_limits → API"              "1" "$(run_gated '{"model":"claude-sonnet-4-6"}' SHOW_WEEKLY=0 SHOW_EXTRA=0)"
rm -rf "$GATE_DIR"

# Test 36 — US byte / newline in the workspace path must not shift later fields
echo ""
echo "-- Test 36: control chars in workspace path --"
OUT=$(run_statusline '{"model":{"display_name":"Opus 4.7"},"context_window":{"used_percentage":42},"workspace":{"current_dir":"/tmp/a\u001fb"},"effort":{"level":"high"}}' \
    USAGE_FILE=/dev/null)
assert_eq "US in cwd: effort kept, no phantom session" "Opus 4.7/hi │ 🟢 Ctx 42%" "$OUT"
OUT=$(run_statusline '{"model":{"display_name":"Opus 4.7"},"context_window":{"used_percentage":42},"workspace":{"current_dir":"/tmp/a\nb"},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":30}}}' \
    USAGE_FILE=/dev/null)
assert_eq "newline in cwd: effort + session kept" "Opus 4.7/hi │ 🟢 Ctx 42% │ ⏳ 🟢 30%" "$OUT"

# Test 37 — Malformed rate_limits must not wipe the other fields
echo ""
echo "-- Test 37: malformed rate_limits --"
OUT=$(run_statusline '{"model":{"display_name":"Opus 4.7"},"context_window":{"used_percentage":42},"effort":{"level":"high"},"rate_limits":"n/a"}' \
    USAGE_FILE=/dev/null)
assert_eq "string rate_limits ignored" "Opus 4.7/hi │ 🟢 Ctx 42%" "$OUT"
OUT=$(run_statusline '{"model":{"display_name":"Opus 4.7"},"context_window":{"used_percentage":42},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":{"x":1}}}}' \
    USAGE_FILE=/dev/null)
assert_contains "object resets_at keeps other fields" "Opus 4.7/hi │ 🟢 Ctx 42%" "$OUT"

# Test 38 — Negative percentage clamps to 0
echo ""
echo "-- Test 38: negative percentage --"
assert_eq "num negative → 0" "0" "$(num -20)"
OUT=$(run_statusline '{"model":"claude-sonnet-4-6","context_window":{"used_percentage":-20}}' USAGE_FILE=/dev/null)
assert_contains "ctx -20 → 0%" "🔵 Ctx 0%" "$OUT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
