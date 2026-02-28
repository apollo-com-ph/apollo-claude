#!/usr/bin/env bash
set -euo pipefail

# build.sh — cross-compile safe-bash-hook for all supported platforms.
#
# Usage:
#   ./build.sh
#
# Outputs are written to hooks/safe-bash/dist/:
#   safe-bash-hook-linux-amd64
#   safe-bash-hook-linux-arm64
#   safe-bash-hook-macos-intel
#   safe-bash-hook-macos-apple-silicon
#
# Requirements:
#   - Rust toolchain with cross-compilation support
#   - cargo-zigbuild (recommended) OR cross (alternative)
#   - For macOS targets from Linux: zig (via cargo-zigbuild)
#
# Install cargo-zigbuild:
#   cargo install cargo-zigbuild
#   pip3 install ziglang  # or: brew install zig

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"

mkdir -p "$DIST_DIR"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$SCRIPT_DIR"

# Detect build tool
if command -v cargo-zigbuild >/dev/null 2>&1; then
  BUILD_CMD="cargo zigbuild"
elif command -v cross >/dev/null 2>&1; then
  BUILD_CMD="cross build"
else
  fail "Neither cargo-zigbuild nor cross found.
  Install one:
    cargo install cargo-zigbuild && pip3 install ziglang
    # or:
    cargo install cross"
fi

build_target() {
  local target="$1"
  local output_name="$2"

  info "Building for $target..."
  $BUILD_CMD --release --target "$target"
  local bin="${SCRIPT_DIR}/target/${target}/release/safe-bash-hook"
  if [ ! -f "$bin" ]; then
    fail "Binary not found after build: $bin"
  fi
  cp "$bin" "${DIST_DIR}/${output_name}"
  ok "Built: dist/${output_name}"
}

# Add required targets
info "Installing cross-compilation targets..."
rustup target add \
  x86_64-unknown-linux-gnu \
  aarch64-unknown-linux-gnu \
  x86_64-apple-darwin \
  aarch64-apple-darwin \
  2>/dev/null || true

build_target "x86_64-unknown-linux-gnu"  "safe-bash-hook-linux-amd64"
build_target "aarch64-unknown-linux-gnu" "safe-bash-hook-linux-arm64"
build_target "x86_64-apple-darwin"       "safe-bash-hook-macos-intel"
build_target "aarch64-apple-darwin"      "safe-bash-hook-macos-apple-silicon"

printf '\n'
printf '\033[1;32m✓ All targets built successfully!\033[0m\n\n'
ls -lh "${DIST_DIR}"/
printf '\n'
printf 'Upload these to a GitHub Release, then update RELEASE_BASE_URL in install-safe-bash-hook.sh.\n'
