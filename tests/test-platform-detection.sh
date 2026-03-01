#!/usr/bin/env bash
# test-platform-detection.sh — tests for uname → artifact name mapping
# from install-safe-bash-hook.sh (lines 100-122)
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

printf '\033[1;34m==>\033[0m Testing platform detection (OS/arch → artifact)\n\n'

TMPDIR_PLAT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PLAT"' EXIT

# ---------------------------------------------------------------------------
# detect_artifact OS ARCH
# Replicates the exact platform detection logic from install-safe-bash-hook.sh
# (lines 100-122). Prints the artifact name and exits 0 on success, exits
# non-zero (with error message on stderr) on unsupported platform.
# ---------------------------------------------------------------------------
detect_artifact() {
  local os="$1"
  local arch="$2"
  local artifact=""

  case "$os" in
    Linux)
      case "$arch" in
        x86_64)  artifact="safe-bash-hook-linux-amd64" ;;
        aarch64) artifact="safe-bash-hook-linux-arm64" ;;
        arm64)   artifact="safe-bash-hook-linux-arm64" ;;
        *) printf 'Unsupported Linux architecture: %s\n' "$arch" >&2; return 1 ;;
      esac ;;
    Darwin)
      case "$arch" in
        x86_64) artifact="safe-bash-hook-macos-intel" ;;
        arm64)  artifact="safe-bash-hook-macos-apple-silicon" ;;
        *) printf 'Unsupported macOS architecture: %s\n' "$arch" >&2; return 1 ;;
      esac ;;
    *)
      printf 'Unsupported OS: %s\n' "$os" >&2; return 1 ;;
  esac

  printf '%s' "$artifact"
  return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

assert_eq  'Linux x86_64 → linux-amd64'                   "safe-bash-hook-linux-amd64"          "$(detect_artifact Linux x86_64)"
assert_eq  'Linux aarch64 → linux-arm64'                   "safe-bash-hook-linux-arm64"          "$(detect_artifact Linux aarch64)"
assert_eq  'Linux arm64 → linux-arm64'                     "safe-bash-hook-linux-arm64"          "$(detect_artifact Linux arm64)"
assert_eq  'Darwin x86_64 → macos-intel'                   "safe-bash-hook-macos-intel"          "$(detect_artifact Darwin x86_64)"
assert_eq  'Darwin arm64 → macos-apple-silicon'            "safe-bash-hook-macos-apple-silicon"  "$(detect_artifact Darwin arm64)"
assert_exit 'Linux armv7l → non-zero (unsupported)'        1 detect_artifact Linux armv7l
assert_exit 'FreeBSD x86_64 → non-zero (unsupported)'     1 detect_artifact FreeBSD x86_64

test_summary
