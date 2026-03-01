#!/usr/bin/env bash
# test-lib.sh — shared assertion library for apollo-claude shell tests
#
# Source this file in every tests/test-*.sh:
#   source "$(dirname "$0")/test-lib.sh"
#
# Provides: assert_eq, assert_exit, assert_stdout_eq, assert_stdout_contains, test_summary
# Callers must declare PASS and FAIL before sourcing, or rely on the defaults here.

set -euo pipefail

# ---------------------------------------------------------------------------
# Counters (initialized here; callers may reset them)
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
_GREEN='\033[1;32m'
_RED='\033[1;31m'
_BLUE='\033[1;34m'
_RESET='\033[0m'

# ---------------------------------------------------------------------------
# _pass / _fail helpers
# ---------------------------------------------------------------------------
_pass() {
  local desc="$1"
  printf "  ${_GREEN}PASS${_RESET} %s\n" "$desc"
  PASS=$(( PASS + 1 ))
}

_fail() {
  local desc="$1"
  local msg="$2"
  printf "  ${_RED}FAIL${_RESET} %s\n    %s\n" "$desc" "$msg"
  FAIL=$(( FAIL + 1 ))
}

# ---------------------------------------------------------------------------
# assert_eq "description" "expected" "actual"
# ---------------------------------------------------------------------------
assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    _pass "$desc"
  else
    _fail "$desc" "expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"
  fi
}

# ---------------------------------------------------------------------------
# assert_exit "description" expected_exit_code command [args...]
# ---------------------------------------------------------------------------
assert_exit() {
  local desc="$1"
  local expected_exit="$2"
  shift 2
  local actual_exit=0
  "$@" >/dev/null 2>&1 || actual_exit=$?
  if [ "$actual_exit" -eq "$expected_exit" ]; then
    _pass "$desc"
  else
    _fail "$desc" "expected exit $expected_exit, got $actual_exit"
  fi
}

# ---------------------------------------------------------------------------
# assert_stdout_eq "description" "expected_stdout" command [args...]
# ---------------------------------------------------------------------------
assert_stdout_eq() {
  local desc="$1"
  local expected="$2"
  shift 2
  local actual
  actual="$("$@" 2>/dev/null)" || true
  if [ "$actual" = "$expected" ]; then
    _pass "$desc"
  else
    _fail "$desc" "expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"
  fi
}

# ---------------------------------------------------------------------------
# assert_stdout_contains "description" "needle" command [args...]
# ---------------------------------------------------------------------------
assert_stdout_contains() {
  local desc="$1"
  local needle="$2"
  shift 2
  local actual
  actual="$("$@" 2>/dev/null)" || true
  if printf '%s' "$actual" | grep -qF "$needle"; then
    _pass "$desc"
  else
    _fail "$desc" "stdout did not contain $(printf '%q' "$needle")"
  fi
}

# ---------------------------------------------------------------------------
# test_summary — print results and exit 1 if any failures
# ---------------------------------------------------------------------------
test_summary() {
  local total=$(( PASS + FAIL ))
  printf '\n'
  printf "${_BLUE}==>${_RESET} Results: %d/%d passed\n" "$PASS" "$total"
  if [ "$FAIL" -gt 0 ]; then
    printf "${_RED}error:${_RESET} %d test(s) failed\n" "$FAIL" >&2
    exit 1
  fi
  printf "${_GREEN}✓ All tests passed!${_RESET}\n"
}
