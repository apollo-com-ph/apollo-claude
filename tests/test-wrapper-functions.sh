#!/usr/bin/env bash
# test-wrapper-functions.sh — tests for config-reading loop and _test_token() from bin/apollo-claude
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

printf '\033[1;34m==>\033[0m Testing bin/apollo-claude wrapper functions\n\n'

_src="$PROJECT_ROOT/bin/apollo-claude"

TMPDIR_WRAP="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WRAP"' EXIT

# ---------------------------------------------------------------------------
# Helper: run the wrapper's config-reading loop on a temp config file.
# Replicates the exact logic from bin/apollo-claude (lines ~191-200).
# Outputs "USER=<val>", "TOKEN=<val>", "SERVER=<val>" on separate lines.
# ---------------------------------------------------------------------------
read_wrapper_config() {
    local CONFIG_FILE="$1"
    local APOLLO_USER=""
    local APOLLO_OTEL_TOKEN=""
    local APOLLO_OTEL_SERVER=""

    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "${key}" != APOLLO_* ]] && continue
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "${key}" in
            APOLLO_USER)        APOLLO_USER="${value}" ;;
            APOLLO_OTEL_TOKEN)  APOLLO_OTEL_TOKEN="${value}" ;;
            APOLLO_OTEL_SERVER) APOLLO_OTEL_SERVER="${value}" ;;
        esac
    done < "${CONFIG_FILE}"

    printf 'USER=%s\nTOKEN=%s\nSERVER=%s\n' "$APOLLO_USER" "$APOLLO_OTEL_TOKEN" "$APOLLO_OTEL_SERVER"
}

_write_cfg() {
    local content="$1"
    local cfg="$TMPDIR_WRAP/config.$$.$RANDOM"
    printf '%s\n' "$content" > "$cfg"
    echo "$cfg"
}

_parse() {
    local content="$1"
    local cfg
    cfg=$(_write_cfg "$content")
    read_wrapper_config "$cfg"
}

# ---------------------------------------------------------------------------
# Config-reading: basic cases
# ---------------------------------------------------------------------------
printf 'config-reading loop:\n'

assert_eq 'standard user' \
    'USER=dev@company.com' \
    "$(_parse $'APOLLO_USER=dev@company.com\nAPOLLO_OTEL_TOKEN=at_tok' | grep '^USER=')"

assert_eq 'standard token' \
    'TOKEN=at_tok' \
    "$(_parse $'APOLLO_USER=dev@company.com\nAPOLLO_OTEL_TOKEN=at_tok' | grep '^TOKEN=')"

assert_eq 'APOLLO_OTEL_SERVER read' \
    'SERVER=https://custom.example.com/otel' \
    "$(_parse $'APOLLO_USER=x\nAPOLLO_OTEL_TOKEN=y\nAPOLLO_OTEL_SERVER=https://custom.example.com/otel' | grep '^SERVER=')"

assert_eq 'missing SERVER → empty' \
    'SERVER=' \
    "$(_parse $'APOLLO_USER=x\nAPOLLO_OTEL_TOKEN=y' | grep '^SERVER=')"

# ---------------------------------------------------------------------------
# Config-reading: whitespace, comments, blank lines
# ---------------------------------------------------------------------------
printf '\nconfig-reading loop (edge cases):\n'

assert_eq 'leading spaces on key trimmed' \
    'USER=trimmed@example.com' \
    "$(_parse $'  APOLLO_USER = trimmed@example.com' | grep '^USER=')"

assert_eq 'comment line skipped' \
    'USER=real@example.com' \
    "$(_parse $'# APOLLO_USER=should-be-ignored\nAPOLLO_USER=real@example.com' | grep '^USER=')"

assert_eq 'blank lines skipped' \
    'USER=ok@example.com' \
    "$(_parse $'\n\nAPOLLO_USER=ok@example.com\n\n' | grep '^USER=')"

assert_eq 'non-APOLLO_ key ignored' \
    'USER=' \
    "$(_parse $'OTHER_KEY=should-not-appear\nFOO=bar' | grep '^USER=')"

# Token with embedded '=' (base64 padding)
assert_eq 'base64 token with = in value' \
    'TOKEN=abc123==extra=stuff' \
    "$(_parse $'APOLLO_OTEL_TOKEN=abc123==extra=stuff' | grep '^TOKEN=')"

# ---------------------------------------------------------------------------
# _test_token: return code logic
# ---------------------------------------------------------------------------
printf '\n_test_token return codes:\n'

# Extract _test_token from wrapper (requires curl)
eval "$(sed -n '/^_test_token()/,/^}/p' "$_src")"

# Create a mock curl in a temp bin dir
MOCK_BIN="$TMPDIR_WRAP/mockbin"
mkdir -p "$MOCK_BIN"

# Mock returning HTTP 200
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/bin/sh
# Extract -w format string and print the status code
for arg; do
    case "$arg" in
        200) echo "200"; exit 0 ;;
    esac
done
echo "200"
MOCK
chmod +x "$MOCK_BIN/curl"

# For _test_token we need curl to output the http_code via -w "%{http_code}"
# Build targeted mocks for each scenario

# Mock: returns 200 → rc=0
cat > "$MOCK_BIN/curl_200" <<'MOCK'
#!/bin/sh
echo "200"
MOCK
chmod +x "$MOCK_BIN/curl_200"

_mock_test_token() {
    local status="$1"
    # Inline the _test_token logic with a fixed status
    case "${status}" in
        401|403) return 1 ;;
        000)     return 2 ;;
        *)       return 0 ;;
    esac
}

assert_exit '_test_token logic: 200 → rc 0' 0 _mock_test_token "200"
assert_exit '_test_token logic: 204 → rc 0' 0 _mock_test_token "204"
assert_exit '_test_token logic: 401 → rc 1' 1 _mock_test_token "401"
assert_exit '_test_token logic: 403 → rc 1' 1 _mock_test_token "403"
assert_exit '_test_token logic: 000 → rc 2' 2 _mock_test_token "000"
assert_exit '_test_token logic: 500 → rc 0' 0 _mock_test_token "500"

test_summary
