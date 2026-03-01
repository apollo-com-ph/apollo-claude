#!/usr/bin/env bash
# test-version-gte.sh — tests for version_gte() extracted from setup-apollotech-otel-for-claude.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

printf '\033[1;34m==>\033[0m Testing version_gte()\n\n'

# Extract version_gte from the setup script
eval "$(sed -n '/^version_gte()/,/^}/p' "$PROJECT_ROOT/setup-apollotech-otel-for-claude.sh")"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

assert_exit "equal versions (1.6 >= 1.6)"       0 version_gte "1.6"   "1.6"
assert_exit "greater minor (1.7 >= 1.6)"         0 version_gte "1.7"   "1.6"
assert_exit "lesser minor (1.5 >= 1.6)"          1 version_gte "1.5"   "1.6"
assert_exit "greater major (2.0 >= 1.9.9)"       0 version_gte "2.0"   "1.9.9"
assert_exit "trailing zero equal (1.6.0 >= 1.6)" 0 version_gte "1.6.0" "1.6"
assert_exit "fewer fields equal (1.6 >= 1.6.0)"  0 version_gte "1.6"   "1.6.0"
assert_exit "zero major vs one (0.9 >= 1.0)"     1 version_gte "0.9"   "1.0"
assert_exit "numeric compare (1.10 >= 1.9)"      0 version_gte "1.10"  "1.9"
assert_exit "4-field greater (1.6.1.2 >= 1.6.1.1)" 0 version_gte "1.6.1.2" "1.6.1.1"
assert_exit "4-field lesser (1.6.1 >= 1.6.2)"   1 version_gte "1.6.1" "1.6.2"
assert_exit "both empty ('' >= '')"              0 version_gte ""      ""
assert_exit "non-empty >= empty (1.0 >= '')"     0 version_gte "1.0"   ""

test_summary
