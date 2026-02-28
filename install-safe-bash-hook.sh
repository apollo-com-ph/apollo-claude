#!/bin/bash
set -euo pipefail

# install-safe-bash-hook.sh — installs the safe-bash-hook PreToolUse binary
#
# Usage (curl | bash):
#   curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install-safe-bash-hook.sh | bash
#
# What it does:
#   1. Checks required CLI tools are present
#   2. Detects OS + architecture, maps to the correct release artifact name
#   3. Downloads safe-bash-hook binary from GitHub Releases
#   4. Validates the binary (non-empty, executable format, not an HTML error page)
#   5. Installs to ~/.claude/hooks/safe-bash-hook (atomic: tmpfile -> mv)
#   6. Downloads initial safe-bash-patterns.json to ~/.claude/hooks/
#   7. Merges PreToolUse hook config into ~/.claude/settings.json

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GITHUB_RELEASES_BASE="https://github.com/apollo-com-ph/apollo-claude/releases/latest/download"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main"
HOOKS_DIR="$HOME/.claude/hooks"
BINARY_TARGET="$HOOKS_DIR/safe-bash-hook"
PATTERNS_TARGET="$HOOKS_DIR/safe-bash-patterns.json"
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

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required but not found.

  Install curl:
    Linux (apt):  sudo apt install curl
    macOS:        brew install curl"
fi
ok "curl found: $(command -v curl)"

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

info "All dependencies satisfied."

# ---------------------------------------------------------------------------
# Step 2: Detect OS + architecture
# ---------------------------------------------------------------------------

info "Detecting platform..."

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Linux)
    case "$arch" in
      x86_64)  artifact="safe-bash-hook-linux-amd64" ;;
      aarch64) artifact="safe-bash-hook-linux-arm64" ;;
      arm64)   artifact="safe-bash-hook-linux-arm64" ;;
      *) fail "Unsupported Linux architecture: $arch. Supported: x86_64, aarch64." ;;
    esac
    ;;
  Darwin)
    case "$arch" in
      x86_64)  artifact="safe-bash-hook-macos-intel" ;;
      arm64)   artifact="safe-bash-hook-macos-apple-silicon" ;;
      *) fail "Unsupported macOS architecture: $arch. Supported: x86_64, arm64." ;;
    esac
    ;;
  *)
    fail "Unsupported OS: $os. Supported: Linux, Darwin (macOS)."
    ;;
esac

DOWNLOAD_URL="${GITHUB_RELEASES_BASE}/${artifact}"
ok "Platform: $os/$arch → artifact: $artifact"

# ---------------------------------------------------------------------------
# Step 3: Download binary
# ---------------------------------------------------------------------------

info "Downloading $artifact..."

mkdir -p "$HOOKS_DIR"
tmpbin=$(mktemp /tmp/safe-bash-hook.XXXXXX)
trap 'rm -f "$tmpbin"' EXIT

curl -fsSL "$DOWNLOAD_URL" -o "$tmpbin" \
  || fail "Failed to download $artifact from $DOWNLOAD_URL"

# ---------------------------------------------------------------------------
# Step 4: Validate binary
# ---------------------------------------------------------------------------

info "Validating binary..."

if [ ! -s "$tmpbin" ]; then
  fail "Downloaded binary is empty."
fi

# Check it's not an HTML error page (GitHub 404 returns HTML)
if file "$tmpbin" 2>/dev/null | grep -qi "html"; then
  fail "Downloaded file appears to be HTML (likely a 404). Check that the release artifact exists at: $DOWNLOAD_URL"
fi

# Check for ELF (Linux) or Mach-O (macOS) magic bytes
first_bytes="$(xxd -l 4 "$tmpbin" 2>/dev/null | head -1 || od -A x -t x1z -v "$tmpbin" 2>/dev/null | head -1 || true)"
if [ -z "$first_bytes" ]; then
  # Fall back: just check it's executable-looking via file command
  file_type="$(file "$tmpbin" 2>/dev/null || true)"
  if ! echo "$file_type" | grep -qiE "(elf|mach-o|executable)"; then
    warn "Could not verify binary format (file command unavailable). Proceeding anyway."
  fi
fi

ok "Binary downloaded and validated."

# ---------------------------------------------------------------------------
# Step 5: Install binary to ~/.claude/hooks/
# ---------------------------------------------------------------------------

info "Installing binary to $BINARY_TARGET..."

mv "$tmpbin" "$BINARY_TARGET"
trap - EXIT  # file moved — no longer need cleanup
chmod +x "$BINARY_TARGET"

ok "Installed: $BINARY_TARGET"

# ---------------------------------------------------------------------------
# Step 6: Download initial patterns file
# ---------------------------------------------------------------------------

info "Downloading initial patterns file..."

tmppatterns=$(mktemp /tmp/safe-bash-patterns.XXXXXX)
trap 'rm -f "$tmppatterns"' EXIT

PATTERNS_URL="${GITHUB_RAW_BASE}/safe-bash-patterns.json"
if curl -fsSL "$PATTERNS_URL" -o "$tmppatterns" 2>/dev/null; then
  if [ -s "$tmppatterns" ] && jq empty "$tmppatterns" >/dev/null 2>&1; then
    mv "$tmppatterns" "$PATTERNS_TARGET"
    trap - EXIT
    ok "Patterns file installed: $PATTERNS_TARGET"
  else
    warn "Downloaded patterns file is empty or invalid JSON — skipping. The hook will use hardcoded patterns only."
    rm -f "$tmppatterns"
  fi
else
  warn "Could not download patterns file — skipping. The hook will use hardcoded patterns only."
  rm -f "$tmppatterns" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 7: Merge PreToolUse hook config into ~/.claude/settings.json
# ---------------------------------------------------------------------------

info "Updating $SETTINGS_JSON..."

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

# Also add deny-list entries to permissions (additive — does not remove existing entries)
DENY_LIST='[
  "Bash(rm -rf *)",
  "Bash(rm -r *)",
  "Bash(rmdir *)",
  "Bash(git push --force *)",
  "Bash(git push -f *)",
  "Bash(git reset --hard *)",
  "Bash(git clean *)",
  "Bash(git checkout -- *)",
  "Bash(git restore *)",
  "Bash(git branch -D *)",
  "Bash(gh api -X DELETE *)",
  "Bash(gh api -X PUT *)",
  "Bash(gh api -X POST *)",
  "Bash(chmod -R 777 *)",
  "Bash(> *)",
  "Bash(sed -i *)"
]'

if [ -f "$SETTINGS_JSON" ]; then
  if jq empty "$SETTINGS_JSON" >/dev/null 2>&1; then
    tmpjson="${SETTINGS_JSON}.tmp.$$"
    bak="${SETTINGS_JSON}.bak_$(date +%Y%m%d_%H%M%S)"
    cp "$SETTINGS_JSON" "$bak"
    ok "Backed up settings.json: $bak"

    # Merge hooks config and permission deny list (additive)
    jq --argjson hooks "$HOOK_CONFIG" \
       --argjson deny "$DENY_LIST" \
      '.hooks = ($hooks + (.hooks // {})) |
       .permissions.deny = ((.permissions.deny // []) + $deny | unique)' \
      "$SETTINGS_JSON" > "$tmpjson" \
      || fail "Failed to update settings.json."

    mv "$tmpjson" "$SETTINGS_JSON"
    ok "settings.json updated."
  else
    warn "settings.json is not valid JSON — skipping merge. Fix it manually and re-run."
  fi
else
  tmpjson="${SETTINGS_JSON}.tmp.$$"
  jq -n \
    --argjson hooks "$HOOK_CONFIG" \
    --argjson deny "$DENY_LIST" \
    '{hooks: $hooks, permissions: {deny: $deny}}' > "$tmpjson" \
    || fail "Failed to create settings.json."
  mv "$tmpjson" "$SETTINGS_JSON"
  ok "settings.json created."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m✓ safe-bash-hook installed successfully!\033[0m\n\n'
printf 'Installed:\n'
printf '  Binary:        %s\n' "$BINARY_TARGET"
if [ -f "$PATTERNS_TARGET" ]; then
  printf '  Patterns:      %s\n' "$PATTERNS_TARGET"
fi
printf '  settings.json: %s (PreToolUse hook + deny list merged)\n' "$SETTINGS_JSON"
printf '\n'
printf 'The hook inspects every Bash command before execution, blocking destructive\n'
printf 'compound commands that bypass the deny list (e.g. "git status && rm -rf /").\n'
printf '\n'
printf 'Restart Claude Code (or start a new session) to activate the hook.\n\n'
