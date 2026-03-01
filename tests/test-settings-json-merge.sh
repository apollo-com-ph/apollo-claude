#!/usr/bin/env bash
# test-settings-json-merge.sh — tests for jq merge logic in setup/install scripts
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

printf '\033[1;34m==>\033[0m Testing settings.json merge logic\n\n'

TMPDIR_JQ="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_JQ"' EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
OTEL_ENV='{
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "https://dev-ai.apollotech.co/otel",
  "OTEL_LOG_TOOL_DETAILS": "1"
}'
HELPER_PATH="/home/jessie/.claude/apollotech-otel-headers.sh"

HOOK_CONFIG='{
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        {
          "type": "command",
          "command": "~/.claude/hooks/safe-bash-hook"
        }
      ]
    }
  ]
}'

DENY_LIST='["Bash(rm -rf *)", "Bash(git push --force *)"]'

STATUS_LINE_CONFIG='{"type": "command", "command": "~/.claude/hooks/statusline.sh"}'

# ---------------------------------------------------------------------------
# 4a. Setup script merge
# ---------------------------------------------------------------------------
printf '4a: Setup script merge (.env + .otelHeadersHelper):\n'

# 4a-1: Empty {} → adds env and otelHeadersHelper
_cfg="$TMPDIR_JQ/settings_4a1.json"
printf '{}' > "$_cfg"
result="$(jq \
  --argjson otelenv "$OTEL_ENV" \
  --arg helper "$HELPER_PATH" \
  '.env = ((.env // {}) + $otelenv) | .otelHeadersHelper = $helper' "$_cfg")"

assert_eq '4a-1: empty {} → otelHeadersHelper set' \
  "$HELPER_PATH" \
  "$(printf '%s' "$result" | jq -r '.otelHeadersHelper')"

assert_eq '4a-1: empty {} → env.OTEL_LOG_TOOL_DETAILS set' \
  "1" \
  "$(printf '%s' "$result" | jq -r '.env.OTEL_LOG_TOOL_DETAILS')"

# 4a-2: Existing env with other keys → preserved
_cfg="$TMPDIR_JQ/settings_4a2.json"
printf '{"env":{"MY_CUSTOM_VAR":"hello"}}' > "$_cfg"
result="$(jq \
  --argjson otelenv "$OTEL_ENV" \
  --arg helper "$HELPER_PATH" \
  '.env = ((.env // {}) + $otelenv) | .otelHeadersHelper = $helper' "$_cfg")"

assert_eq '4a-2: existing env key preserved' \
  "hello" \
  "$(printf '%s' "$result" | jq -r '.env.MY_CUSTOM_VAR')"

assert_eq '4a-2: OTEL key also added' \
  "http/protobuf" \
  "$(printf '%s' "$result" | jq -r '.env.OTEL_EXPORTER_OTLP_PROTOCOL')"

# 4a-3: Existing otelHeadersHelper → overwritten
_cfg="$TMPDIR_JQ/settings_4a3.json"
printf '{"otelHeadersHelper":"/old/path/headers.sh"}' > "$_cfg"
result="$(jq \
  --argjson otelenv "$OTEL_ENV" \
  --arg helper "$HELPER_PATH" \
  '.env = ((.env // {}) + $otelenv) | .otelHeadersHelper = $helper' "$_cfg")"

assert_eq '4a-3: otelHeadersHelper overwritten' \
  "$HELPER_PATH" \
  "$(printf '%s' "$result" | jq -r '.otelHeadersHelper')"

# ---------------------------------------------------------------------------
# 4b. Safe-bash-hook merge
# ---------------------------------------------------------------------------
printf '\n4b: Safe-bash-hook merge (.hooks.PreToolUse + .permissions.deny):\n'

_jq_hook_merge() {
  local _file="$1"
  jq --argjson hooks "$HOOK_CONFIG" \
     --argjson deny "$DENY_LIST" \
    '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + $hooks.PreToolUse | unique_by(.hooks[0].command)) |
     .permissions.deny = ((.permissions.deny // []) + $deny | unique)' \
    "$_file"
}

# 4b-1: Empty {} → creates hooks.PreToolUse and permissions.deny
_cfg="$TMPDIR_JQ/settings_4b1.json"
printf '{}' > "$_cfg"
result="$(_jq_hook_merge "$_cfg")"

assert_eq '4b-1: PreToolUse has 1 entry' \
  "1" \
  "$(printf '%s' "$result" | jq '.hooks.PreToolUse | length')"

assert_eq '4b-1: deny has 2 entries' \
  "2" \
  "$(printf '%s' "$result" | jq '.permissions.deny | length')"

# 4b-2: Existing different hook → additive (2 total)
_cfg="$TMPDIR_JQ/settings_4b2.json"
printf '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"~/.claude/hooks/other-hook"}]}]}}' > "$_cfg"
result="$(_jq_hook_merge "$_cfg")"

assert_eq '4b-2: existing hook preserved → 2 total' \
  "2" \
  "$(printf '%s' "$result" | jq '.hooks.PreToolUse | length')"

# 4b-3: Duplicate hook entry → not duplicated (unique_by)
_cfg="$TMPDIR_JQ/settings_4b3.json"
# Pre-populate with the same safe-bash-hook entry
printf '%s' "$result" > "$_cfg"  # reuse result with 2 entries
result2="$(_jq_hook_merge "$_cfg")"

assert_eq '4b-3: safe-bash-hook not duplicated after re-merge' \
  "$(printf '%s' "$result" | jq '.hooks.PreToolUse | length')" \
  "$(printf '%s' "$result2" | jq '.hooks.PreToolUse | length')"

# 4b-4: Existing deny entries → additive, unique
_cfg="$TMPDIR_JQ/settings_4b4.json"
printf '{"permissions":{"deny":["Bash(rm -rf *)","Bash(custom *)"]}}' > "$_cfg"
result="$(_jq_hook_merge "$_cfg")"

# "Bash(rm -rf *)" appears in both existing and DENY_LIST → should be unique
assert_eq '4b-4: deny entries deduplicated' \
  "3" \
  "$(printf '%s' "$result" | jq '.permissions.deny | length')"

# ---------------------------------------------------------------------------
# 4c. Statusline merge
# ---------------------------------------------------------------------------
printf '\n4c: Statusline merge (.statusLine):\n'

# 4c-1: Empty {} → adds statusLine
_cfg="$TMPDIR_JQ/settings_4c1.json"
printf '{}' > "$_cfg"
result="$(jq --argjson statusline "$STATUS_LINE_CONFIG" '.statusLine = $statusline' "$_cfg")"

assert_eq '4c-1: statusLine.type set' \
  "command" \
  "$(printf '%s' "$result" | jq -r '.statusLine.type')"

# 4c-2: Existing statusLine → overwritten
_cfg="$TMPDIR_JQ/settings_4c2.json"
printf '{"statusLine":{"type":"command","command":"/old/statusline.sh"}}' > "$_cfg"
result="$(jq --argjson statusline "$STATUS_LINE_CONFIG" '.statusLine = $statusline' "$_cfg")"

assert_eq '4c-2: statusLine.command overwritten' \
  "~/.claude/hooks/statusline.sh" \
  "$(printf '%s' "$result" | jq -r '.statusLine.command')"

# 4c-3: Other keys preserved
_cfg="$TMPDIR_JQ/settings_4c3.json"
printf '{"model":"claude-opus-4-5","statusLine":{"type":"old"}}' > "$_cfg"
result="$(jq --argjson statusline "$STATUS_LINE_CONFIG" '.statusLine = $statusline' "$_cfg")"

assert_eq '4c-3: other keys preserved' \
  "claude-opus-4-5" \
  "$(printf '%s' "$result" | jq -r '.model')"

# ---------------------------------------------------------------------------
# 4d. New file creation via jq -n
# ---------------------------------------------------------------------------
printf '\n4d: New file creation (jq -n):\n'

# Setup script new file
result="$(jq -n \
  --argjson otelenv "$OTEL_ENV" \
  --arg helper "$HELPER_PATH" \
  '{env: $otelenv, otelHeadersHelper: $helper}')"

assert_eq '4d-1: setup new file has otelHeadersHelper' \
  "$HELPER_PATH" \
  "$(printf '%s' "$result" | jq -r '.otelHeadersHelper')"

# Safe-bash-hook new file
result="$(jq -n \
  --argjson hooks "$HOOK_CONFIG" \
  --argjson deny "$DENY_LIST" \
  '{hooks: $hooks, permissions: {deny: $deny}}')"

assert_eq '4d-2: hook new file has PreToolUse' \
  "1" \
  "$(printf '%s' "$result" | jq '.hooks.PreToolUse | length')"

# Statusline new file
result="$(jq -n --argjson statusline "$STATUS_LINE_CONFIG" '{statusLine: $statusline}')"

assert_eq '4d-3: statusline new file has statusLine' \
  "command" \
  "$(printf '%s' "$result" | jq -r '.statusLine.type')"

test_summary
