#!/usr/bin/env bash
# test-config-parsing.sh — tests for the IFS='=' read config-parsing loop
# from apollotech-otel-headers.sh (lines 15-27).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

printf '\033[1;34m==>\033[0m Testing config-parsing loop\n\n'

# ---------------------------------------------------------------------------
# Helper: parse_config CONFIG_FILE
# Replicates the exact parsing loop from apollotech-otel-headers.sh.
# Prints "USER=<value>" and "TOKEN=<value>" on separate lines.
# ---------------------------------------------------------------------------
parse_config() {
  local CONFIG_FILE="$1"
  local APOLLO_USER=""
  local APOLLO_OTEL_TOKEN=""

  while IFS='=' read -r key value; do
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }" ]] && continue
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "${key}" != APOLLO_* ]] && continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "${key}" in
      APOLLO_USER)       APOLLO_USER="${value}" ;;
      APOLLO_OTEL_TOKEN) APOLLO_OTEL_TOKEN="${value}" ;;
    esac
  done < "${CONFIG_FILE}"

  printf 'USER=%s\nTOKEN=%s\n' "$APOLLO_USER" "$APOLLO_OTEL_TOKEN"
}

# ---------------------------------------------------------------------------
# Helper: write a temp config file and run parse_config on it.
# Usage: parsed_output "$(printf 'line1\nline2\n')"
# ---------------------------------------------------------------------------
TMPDIR_PARSE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PARSE"' EXIT

run_parse() {
  local content="$1"
  local cfg="$TMPDIR_PARSE/config.$$"
  printf '%s\n' "$content" > "$cfg"
  parse_config "$cfg"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

assert_eq 'standard user' \
  'USER=foo@bar.com' \
  "$(run_parse $'APOLLO_USER=foo@bar.com\nAPOLLO_OTEL_TOKEN=secret123' | grep '^USER=')"

assert_eq 'standard token' \
  'TOKEN=secret123' \
  "$(run_parse $'APOLLO_USER=foo@bar.com\nAPOLLO_OTEL_TOKEN=secret123' | grep '^TOKEN=')"

assert_eq 'comments are skipped (user)' \
  'USER=foo@bar.com' \
  "$(run_parse $'# comment\nAPOLLO_USER=foo@bar.com\nAPOLLO_OTEL_TOKEN=secret' | grep '^USER=')"

assert_eq 'comments are skipped (token)' \
  'TOKEN=secret' \
  "$(run_parse $'# comment\nAPOLLO_USER=foo@bar.com\nAPOLLO_OTEL_TOKEN=secret' | grep '^TOKEN=')"

assert_eq 'blank lines skipped (user)' \
  'USER=foo@bar.com' \
  "$(run_parse $'APOLLO_USER=foo@bar.com\n\nAPOLLO_OTEL_TOKEN=secret' | grep '^USER=')"

assert_eq 'whitespace trimmed from key (user)' \
  'USER=foo@bar.com' \
  "$(run_parse $'  APOLLO_USER = foo@bar.com  ' | grep '^USER=')"

assert_eq 'non-APOLLO_ keys ignored' \
  'USER=foo' \
  "$(run_parse $'OTHER_KEY=ignored\nAPOLLO_USER=foo' | grep '^USER=')"

assert_eq 'non-APOLLO_ token still empty' \
  'TOKEN=' \
  "$(run_parse $'OTHER_KEY=ignored\nAPOLLO_USER=foo' | grep '^TOKEN=')"

# Value containing '=': IFS='=' read splits on first '=', rest goes to value
assert_eq 'value with = signs' \
  'TOKEN=abc=def=ghi' \
  "$(run_parse $'APOLLO_OTEL_TOKEN=abc=def=ghi' | grep '^TOKEN=')"

assert_eq 'malformed line (no =) → empty user' \
  'USER=' \
  "$(run_parse 'just some text' | grep '^USER=')"

assert_eq 'empty file → empty user' \
  'USER=' \
  "$(run_parse '' | grep '^USER=')"

assert_eq 'empty file → empty token' \
  'TOKEN=' \
  "$(run_parse '' | grep '^TOKEN=')"

test_summary
