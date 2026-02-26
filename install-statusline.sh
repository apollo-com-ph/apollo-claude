#!/bin/bash
set -euo pipefail

# install-statusline.sh — installs the Claude Code statusline script
#
# Usage (curl | bash):
#   curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install-statusline.sh | bash
#
# What it does:
#   1. Checks required CLI tools are present
#   2. Downloads bin/recommended-statusline.sh to ~/.claude/hooks/statusline.sh
#   3. Merges the statusLine hook config into ~/.claude/settings.json

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GITHUB_RAW_URL="https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/bin/recommended-statusline.sh"
HOOKS_DIR="$HOME/.claude/hooks"
TARGET_SCRIPT="$HOOKS_DIR/statusline.sh"
SETTINGS_JSON="$HOME/.claude/settings.json"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Compare two dot-separated version strings; returns 0 if $1 >= $2
version_gte() {
  local a="$1" b="$2"
  while [ -n "$a" ] || [ -n "$b" ]; do
    local a_field b_field
    a_field="${a%%.*}"; a="${a#"$a_field"}"; a="${a#.}"
    b_field="${b%%.*}"; b="${b#"$b_field"}"; b="${b#.}"
    a_field="${a_field:-0}"; b_field="${b_field:-0}"
    [ "$a_field" -gt "$b_field" ] && return 0
    [ "$a_field" -lt "$b_field" ] && return 1
  done
  return 0  # equal
}

# ---------------------------------------------------------------------------
# Step 1: Dependency checks
# ---------------------------------------------------------------------------

info "Checking dependencies..."

if ! command -v claude >/dev/null 2>&1; then
  fail "claude is not installed or not in PATH.

  Install Claude Code first:
    https://docs.anthropic.com/en/docs/claude-code/getting-started

  Then re-run this installer."
fi
ok "claude found: $(command -v claude)"

# curl is required both for this installer and by the statusline script at runtime
if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required but not found.

  Install curl:
    Linux (apt):  sudo apt install curl
    macOS:        brew install curl"
fi
ok "curl found: $(command -v curl)"

# jq is required for settings.json merge and by the statusline script at runtime
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but not found.

  Install jq:
    Linux (apt):  sudo apt install jq
    macOS:        brew install jq"
fi

jq_raw=$(jq --version 2>/dev/null || true)
jq_ver="${jq_raw#jq-}"
if ! version_gte "$jq_ver" "1.6"; then
  fail "jq >= 1.6 required (found $jq_raw). Please upgrade jq and try again."
fi
ok "jq found: $jq_raw (>= 1.6)"

# Runtime dependencies of the statusline script
_missing=""
for cmd in awk date basename dirname sed tail; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    _missing="${_missing} ${cmd}"
  fi
done
if [ -n "$_missing" ]; then
  fail "Missing required utilities:${_missing}

  Install them:
    Linux (apt):  sudo apt install coreutils
    macOS:        brew install coreutils"
fi
ok "runtime utilities found (awk, date, basename, dirname, sed, tail)"

info "All dependencies satisfied."

# ---------------------------------------------------------------------------
# Step 2: Download + validate statusline script
# ---------------------------------------------------------------------------

info "Downloading statusline script..."

tmpfile=$(mktemp /tmp/statusline.XXXXXX)
trap 'rm -f "$tmpfile"' EXIT

curl -fsSL "$GITHUB_RAW_URL" -o "$tmpfile" \
  || fail "Failed to download statusline script from $GITHUB_RAW_URL"

if [ ! -s "$tmpfile" ]; then
  fail "Downloaded statusline script is empty."
fi

if ! grep -qE '^#!(\/bin\/bash|\/usr\/bin\/env bash)' "$tmpfile"; then
  fail "Downloaded statusline script does not have a valid bash shebang."
fi

if ! bash -n "$tmpfile"; then
  fail "Downloaded statusline script failed bash syntax check."
fi

ok "Statusline script downloaded and validated."

# ---------------------------------------------------------------------------
# Step 3: Install to ~/.claude/hooks/
# ---------------------------------------------------------------------------

info "Installing statusline script to $TARGET_SCRIPT..."

mkdir -p "$HOOKS_DIR"
mv "$tmpfile" "$TARGET_SCRIPT"
trap - EXIT  # file moved — no longer need cleanup
chmod +x "$TARGET_SCRIPT"

ok "Installed: $TARGET_SCRIPT"

# ---------------------------------------------------------------------------
# Step 4: Merge statusLine config into ~/.claude/settings.json
# ---------------------------------------------------------------------------

info "Updating $SETTINGS_JSON..."

STATUS_LINE_CONFIG='{"type": "command", "command": "~/.claude/hooks/statusline.sh"}'

if [ -f "$SETTINGS_JSON" ]; then
  if jq empty "$SETTINGS_JSON" >/dev/null 2>&1; then
    tmpjson="${SETTINGS_JSON}.tmp.$$"
    bak="${SETTINGS_JSON}.bak_$(date +%Y%m%d_%H%M%S)"
    cp "$SETTINGS_JSON" "$bak"
    ok "Backed up settings.json: $bak"
    jq --argjson statusline "$STATUS_LINE_CONFIG" \
      '.statusLine = $statusline' "$SETTINGS_JSON" > "$tmpjson" \
      || fail "Failed to update settings.json."
    mv "$tmpjson" "$SETTINGS_JSON"
    ok "settings.json updated."
  else
    warn "settings.json is not valid JSON — skipping merge. Fix it manually and re-run."
  fi
else
  tmpjson="${SETTINGS_JSON}.tmp.$$"
  jq -n --argjson statusline "$STATUS_LINE_CONFIG" \
    '{statusLine: $statusline}' > "$tmpjson" \
    || fail "Failed to create settings.json."
  mv "$tmpjson" "$SETTINGS_JSON"
  ok "settings.json created."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m✓ Statusline installed successfully!\033[0m\n\n'
printf 'Installed:\n'
printf '  Script:        %s\n' "$TARGET_SCRIPT"
printf '  settings.json: %s (statusLine key set)\n' "$SETTINGS_JSON"
printf '\n'
printf 'To test:\n'
printf "  echo '{\"model\":{\"display_name\":\"Claude-3\"},\"context_window\":{\"used_percentage\":42},\"cost\":{\"total_cost_usd\":0.12},\"workspace\":{\"project_dir\":\"%s\"}}' | %s\n" "$HOME/projects/example" "$TARGET_SCRIPT"
printf '\n'
printf 'Restart Claude Code (or start a new session) to activate the statusline.\n\n'
