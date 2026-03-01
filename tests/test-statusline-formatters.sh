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
assert_eq '9.99 < 10 → $10.0'     '$10.0' "$(format_cost 9.99)"
assert_eq '42.7 → $43 (space-padded)' '$43 ' "$(format_cost 42.7)"
assert_eq '150 >= 100 → $150'     '$150' "$(format_cost 150)"

# ---------------------------------------------------------------------------
# format_project_dir — last 2 path components
# ---------------------------------------------------------------------------
printf '\nformat_project_dir:\n'
assert_eq 'normal 2 components'    "projects/apollo-claude" "$(format_project_dir "/home/user/projects/apollo-claude")"
assert_eq 'single under root'      "root"                   "$(format_project_dir "/root")"
assert_eq 'root itself'            "/"                      "$(format_project_dir "/")"
assert_eq 'empty → empty'          ""                       "$(format_project_dir "")"
assert_eq 'home dir'               "home/jessie"            "$(format_project_dir "/home/jessie")"

test_summary
