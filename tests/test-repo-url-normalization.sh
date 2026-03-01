#!/usr/bin/env bash
# test-repo-url-normalization.sh — tests for the sed regex that normalizes git remote URLs
# from apollotech-otel-headers.sh line 41:
#   sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|; s|\.git$||'
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

printf '\033[1;34m==>\033[0m Testing git remote URL normalization\n\n'

# The exact sed command under test
normalize_url() {
  printf '%s\n' "$1" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|; s|\.git$||'
}

assert_eq 'SSH with .git'       "org/repo"           "$(normalize_url "git@github.com:org/repo.git")"
assert_eq 'SSH without .git'    "org/repo"           "$(normalize_url "git@github.com:org/repo")"
assert_eq 'HTTPS with .git'     "org/repo"           "$(normalize_url "https://github.com/org/repo.git")"
assert_eq 'HTTPS without .git'  "org/repo"           "$(normalize_url "https://github.com/org/repo")"
assert_eq 'enterprise SSH'      "team/project"       "$(normalize_url "git@github.company.com:team/project.git")"
assert_eq 'nested HTTPS path'   "subgroup/repo"      "$(normalize_url "https://gitlab.com/group/subgroup/repo.git")"
assert_eq 'ssh:// protocol URL' "org/repo"           "$(normalize_url "ssh://git@github.com/org/repo.git")"
assert_eq 'empty string'        ""                   "$(normalize_url "")"

test_summary
