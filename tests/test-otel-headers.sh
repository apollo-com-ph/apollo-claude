#!/usr/bin/env bash
# test-otel-headers.sh — end-to-end tests for apollotech-otel-headers.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

HEADERS_SCRIPT="$PROJECT_ROOT/apollotech-otel-headers.sh"

printf '\033[1;34m==>\033[0m Testing apollotech-otel-headers.sh\n\n'

TMPDIR_OTEL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_OTEL"' EXIT

# ---------------------------------------------------------------------------
# _make_home user token → prints fake_home path, sets up ~/.claude/apollotech-config
# ---------------------------------------------------------------------------
_make_home() {
  local user="$1"
  local token="$2"
  local fake_home="$TMPDIR_OTEL/home_$$_$RANDOM"
  mkdir -p "$fake_home/.claude"
  printf 'APOLLO_USER=%s\nAPOLLO_OTEL_TOKEN=%s\n' "$user" "$token" \
    > "$fake_home/.claude/apollotech-config"
  printf '%s' "$fake_home"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# 1. Valid config with SSH remote → correct X-Apollo-Repository
{
  fh="$(_make_home "test@example.com" "mytoken123")"
  repo="$fh/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "git@github.com:testorg/testrepo.git"
  out="$(cd "$repo" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  assert_eq 'SSH remote: X-Apollo-Repository correct' \
    "testorg/testrepo" \
    "$(printf '%s' "$out" | jq -r '."X-Apollo-Repository"')"
}

# 2. Valid config with HTTPS remote
{
  fh="$(_make_home "test@example.com" "mytoken123")"
  repo="$fh/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "https://github.com/testorg/testrepo.git"
  out="$(cd "$repo" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  assert_eq 'HTTPS remote: X-Apollo-Repository correct' \
    "testorg/testrepo" \
    "$(printf '%s' "$out" | jq -r '."X-Apollo-Repository"')"
}

# 3. Authorization header format: Basic <base64>
{
  fh="$(_make_home "test@example.com" "mytoken123")"
  repo="$fh/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "git@github.com:testorg/testrepo.git"
  out="$(cd "$repo" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  assert_eq 'Authorization starts with Basic' \
    "Basic" \
    "$(printf '%s' "$out" | jq -r '.Authorization' | cut -d' ' -f1)"
}

# 4. Base64 correctness
{
  expected_b64="$(printf 'test@example.com:secret123' | base64 -w0 2>/dev/null \
    || printf 'test@example.com:secret123' | base64 | tr -d '\n')"
  fh="$(_make_home "test@example.com" "secret123")"
  repo="$fh/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "git@github.com:org/repo.git"
  out="$(cd "$repo" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  assert_eq 'Base64 encoding correct' \
    "Basic $expected_b64" \
    "$(printf '%s' "$out" | jq -r '.Authorization')"
}

# 5. Git repo with no origin remote → falls back to git root directory basename
{
  fh="$(_make_home "u" "t")"
  repo="$fh/my-project-name"; mkdir -p "$repo"
  git -C "$repo" init -q
  # No remote added
  out="$(cd "$repo" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  assert_eq 'no remote → falls back to dir basename' \
    "my-project-name" \
    "$(printf '%s' "$out" | jq -r '."X-Apollo-Repository"')"
}

# 6. Not in git repo → falls back to CWD basename
{
  fh="$(_make_home "u" "t")"
  work="$fh/my-cwd-name"; mkdir -p "$work"
  out="$(cd "$work" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  assert_eq 'non-git dir → CWD basename as repo' \
    "my-cwd-name" \
    "$(printf '%s' "$out" | jq -r '."X-Apollo-Repository"')"
}

# 7. Missing config file → exit 1
{
  fh="$TMPDIR_OTEL/home_$$_$RANDOM"; mkdir -p "$fh/.claude"
  # No config file written
  exit_code=0
  HOME="$fh" bash "$HEADERS_SCRIPT" >/dev/null 2>&1 || exit_code=$?
  assert_eq 'missing config → exit 1' "1" "$exit_code"
}

# 8. Config with empty APOLLO_USER → exit 1
{
  fh="$TMPDIR_OTEL/home_$$_$RANDOM"; mkdir -p "$fh/.claude"
  printf 'APOLLO_USER=\nAPOLLO_OTEL_TOKEN=token\n' > "$fh/.claude/apollotech-config"
  exit_code=0
  HOME="$fh" bash "$HEADERS_SCRIPT" >/dev/null 2>&1 || exit_code=$?
  assert_eq 'empty APOLLO_USER → exit 1' "1" "$exit_code"
}

# 9. Config with empty APOLLO_OTEL_TOKEN → exit 1
{
  fh="$TMPDIR_OTEL/home_$$_$RANDOM"; mkdir -p "$fh/.claude"
  printf 'APOLLO_USER=user@example.com\nAPOLLO_OTEL_TOKEN=\n' > "$fh/.claude/apollotech-config"
  exit_code=0
  HOME="$fh" bash "$HEADERS_SCRIPT" >/dev/null 2>&1 || exit_code=$?
  assert_eq 'empty APOLLO_OTEL_TOKEN → exit 1' "1" "$exit_code"
}

# 10. Repo name with only valid chars preserved (no stripping needed)
{
  fh="$(_make_home "u" "t")"
  repo="$fh/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "https://github.com/org/repo-name_123.git"
  out="$(cd "$repo" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  assert_eq 'repo name with valid chars preserved' \
    "org/repo-name_123" \
    "$(printf '%s' "$out" | jq -r '."X-Apollo-Repository"')"
}

# 11. Output is valid JSON
{
  fh="$(_make_home "test@example.com" "mytoken123")"
  repo="$fh/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "git@github.com:org/repo.git"
  out="$(cd "$repo" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  assert_exit 'output is valid JSON' 0 jq -e . <<< "$out"
}

# 12. Valid remote → X-Apollo-Repository field present in output
{
  fh="$(_make_home "u" "t")"
  repo="$fh/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "git@github.com:org/repo.git"
  out="$(cd "$repo" && HOME="$fh" bash "$HEADERS_SCRIPT" 2>/dev/null)"
  has_repo="$(printf '%s' "$out" | jq 'has("X-Apollo-Repository")')"
  assert_eq 'valid remote → X-Apollo-Repository field present' "true" "$has_repo"
}

test_summary
