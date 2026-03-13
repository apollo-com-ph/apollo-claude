#!/usr/bin/env bash
# test-statusline-formatters.sh — tests for format_* functions from bin/recommended-statusline.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

printf '\033[1;34m==>\033[0m Testing statusline formatter functions\n\n'

# ---------------------------------------------------------------------------
# Extract pure formatter functions from recommended-statusline.sh.
# We source only the functions, bypassing the script body (which reads stdin
# and spawns background processes). We define stubs for log/debug_log.
# ---------------------------------------------------------------------------
log() { :; }
debug_log() { :; }

# Extract each function via sed and eval
_src="$PROJECT_ROOT/bin/recommended-statusline.sh"

eval "$(sed -n '/^format_model()/,/^}/p' "$_src")"
eval "$(sed -n '/^format_percentage()/,/^}/p' "$_src")"
eval "$(sed -n '/^format_cost()/,/^}/p' "$_src")"
eval "$(sed -n '/^format_project_dir()/,/^}/p' "$_src")"
eval "$(sed -n '/^format_reset_time()/,/^}/p' "$_src")"
eval "$(sed -n '/^format_utilization()/,/^}/p' "$_src")"
SUSTAINABLE_RATE=14.28

# ---------------------------------------------------------------------------
# format_model — pads/truncates to exactly 10 chars
# ---------------------------------------------------------------------------
printf 'format_model:\n'
assert_eq 'short name padded to 10'    "Opus      " "$(format_model "Opus")"
assert_eq 'exact 10 chars'             "Claude-3.5" "$(format_model "Claude-3.5")"
assert_eq 'truncated to 10'            "Claude-3-O" "$(format_model "Claude-3-Opus-XL")"
assert_eq 'empty string → 10 spaces'   "          " "$(format_model "")"

# ---------------------------------------------------------------------------
# format_percentage — 2-digit zero-padded with %
# ---------------------------------------------------------------------------
printf '\nformat_percentage:\n'
assert_eq 'zero'           "00%" "$(format_percentage 0)"
assert_eq 'single digit'   "05%" "$(format_percentage 5)"
assert_eq 'normal'         "42%" "$(format_percentage 42)"
assert_eq 'rounds up 99.7' "100%" "$(format_percentage 99.7)"
assert_eq 'full 100'       "100%" "$(format_percentage 100)"

# ---------------------------------------------------------------------------
# format_cost — multiple code paths
# ---------------------------------------------------------------------------
printf '\nformat_cost:\n'
assert_eq 'zero → $0.0'            '$0.0' "$(format_cost 0)"
assert_eq '0.03 < 0.05 → $0.0'    '$0.0' "$(format_cost 0.03)"
assert_eq '0.15 < 1.0 → $0.2'     '$0.2' "$(format_cost 0.15)"
assert_eq '0.5 < 1.0 → $0.5'      '$0.5' "$(format_cost 0.5)"
assert_eq '0.95 rounds to $1.0'    '$1.0' "$(format_cost 0.95)"
assert_eq '3.45 < 10 → $3.5'      '$3.5' "$(format_cost 3.45)"  # printf %.1f rounds half-up
assert_eq '9.99 >= 9.95 → $10 '    '$10 '  "$(format_cost 9.99)"
assert_eq '42.7 → $43 (space-padded)' '$43 ' "$(format_cost 42.7)"
assert_eq '150 >= 100 → $150'     '$150' "$(format_cost 150)"

# ---------------------------------------------------------------------------
# format_project_dir — last 2 path components
# ---------------------------------------------------------------------------
printf '\nformat_project_dir:\n'
assert_eq 'normal 2 components'    "projects/apollo-claude" "$(format_project_dir "/home/user/projects/apollo-claude")"
assert_eq 'single under root'      "root"                   "$(format_project_dir "/root")"
assert_eq 'root itself'            ""                       "$(format_project_dir "/")"
assert_eq 'empty → empty'          ""                       "$(format_project_dir "")"
assert_eq 'home dir'               "home/jessie"            "$(format_project_dir "/home/jessie")"

# ---------------------------------------------------------------------------
# format_reset_time — converts ISO timestamp to human-readable delta
# ---------------------------------------------------------------------------
printf '\nformat_reset_time:\n'
assert_eq 'null → -----'              '-----' "$(format_reset_time null)"
assert_eq 'empty string → -----'      '-----' "$(format_reset_time "")"
assert_eq 'invalid timestamp → -----' '-----' "$(format_reset_time "not-a-date")"

# Past timestamp → 0h00m
_past=$(date -d "-1 hour" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null \
     || date -v-1H "+%Y-%m-%dT%H:%M:%S" 2>/dev/null \
     || echo "1970-01-01T00:00:00")
assert_eq 'past timestamp → 0h00m' '0h00m' "$(format_reset_time "$_past")"

# Future < 24h → XhXXm format
_future6h=$(date -d "+6 hours" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null \
         || date -v+6H "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
if [ -n "$_future6h" ]; then
    _rt=$(format_reset_time "$_future6h")
    if printf '%s' "$_rt" | grep -qE '^[0-9]+h[0-9]{2}m$'; then
        _pass 'future <24h → XhXXm format'
    else
        _fail 'future <24h → XhXXm format' "got: $_rt"
    fi
fi

# Future >= 24h → XdXXh format
_future2d=$(date -d "+2 days" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null \
         || date -v+2d "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
if [ -n "$_future2d" ]; then
    _rt=$(format_reset_time "$_future2d")
    if printf '%s' "$_rt" | grep -qE '^[0-9]+d[0-9]{2}h$'; then
        _pass 'future >=24h → XdXXh format'
    else
        _fail 'future >=24h → XdXXh format' "got: $_rt"
    fi
fi

# ---------------------------------------------------------------------------
# format_utilization — reads cache file, formats utilization display
# ---------------------------------------------------------------------------
printf '\nformat_utilization:\n'
_TMPDIR_UTIL="$(mktemp -d)"
trap 'rm -rf "$_TMPDIR_UTIL"' EXIT

# No cache file → placeholder
USAGE_CACHE_FILE="$_TMPDIR_UTIL/nonexistent-cache.json"
_util_line1=$(format_utilization | head -1)
assert_eq 'no cache file → placeholder' '(-- -----)' "$_util_line1"

# Empty cache file → placeholder
USAGE_CACHE_FILE="$_TMPDIR_UTIL/empty-cache.json"
touch "$USAGE_CACHE_FILE"
_util_line1=$(format_utilization | head -1)
assert_eq 'empty cache file → placeholder' '(-- -----)' "$_util_line1"

# Cache with null five_hour_utilization → placeholder
USAGE_CACHE_FILE="$_TMPDIR_UTIL/null-5h-cache.json"
printf '{"fetched_at":1000,"five_hour_utilization":null,"five_hour_resets_at":null,"seven_day_utilization":null,"seven_day_resets_at":null}' \
    > "$USAGE_CACHE_FILE"
_util_line1=$(format_utilization | head -1)
assert_eq 'null 5h util → placeholder' '(-- -----)' "$_util_line1"

# Cache with valid five_hour_utilization (60% used → 40% remaining)
_fut4h=$(date -d "+4 hours" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null \
      || date -v+4H "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
if [ -n "$_fut4h" ]; then
    USAGE_CACHE_FILE="$_TMPDIR_UTIL/valid-5h-cache.json"
    printf '{"fetched_at":1000,"five_hour_utilization":60,"five_hour_resets_at":"%s","seven_day_utilization":null,"seven_day_resets_at":null}' \
        "$_fut4h" > "$USAGE_CACHE_FILE"
    _util_line1=$(format_utilization | head -1)
    if printf '%s' "$_util_line1" | grep -qE '\( *40%'; then
        _pass 'valid 5h util (60% used) → shows 40% remaining'
    else
        _fail 'valid 5h util (60% used) → shows 40% remaining' "got: $_util_line1"
    fi
fi

test_summary
