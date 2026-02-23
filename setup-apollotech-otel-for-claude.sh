#!/bin/bash
set -euo pipefail

############################################################
# Usage / Help
############################################################
usage() {
  cat <<EOF
Usage: $0 [--help] [--verbose]

Sets up OTEL telemetry for all Claude Code usage (CLI, VS Code, JetBrains).

Options:
  --help      Show this help message and exit
  --verbose   Enable verbose output

Environment variables:
  GITHUB_URL  Override the GitHub URL for apollotech-otel-headers.sh
EOF
}

############################################################
# Logging helpers
############################################################
VERBOSE=0

info() {
  echo "$@"
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "$@"
  fi
}

fail() {
  local code="$1"; shift
  echo "Error: $@" >&2
  exit "$code"
}

expand_path() {
  case "$1" in
    ~*) echo "$HOME${1:1}" ;;
    *) echo "$1" ;;
  esac
}

############################################################
# Parse arguments
############################################################
for arg in "$@"; do
  case "$arg" in
    --help)
      usage; exit 0;;
    --verbose)
      VERBOSE=1;;
    *)
      echo "Unknown argument: $arg" >&2; usage; exit 2;;
  esac
done

############################################################
# Dependency Check
############################################################

# Compare two dot-separated version strings; returns 0 if $1 >= $2
version_gte() {
  local a="$1" b="$2"
  # Compare field by field
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

check_deps() {
  info "Checking dependencies..."
  local missing=""

  for dep in bash claude jq base64 grep; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing="$missing $dep"
    else
      log "  $dep: found ($(command -v "$dep"))"
    fi
  done

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing="$missing curl-or-wget"
  else
    command -v curl >/dev/null 2>&1 && log "  curl: found" || log "  wget: found"
  fi

  for dep in date chmod cp mkdir mv; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing="$missing $dep"
    else
      log "  $dep: found"
    fi
  done

  # Dependencies required by the installed apollotech-otel-headers.sh helper
  for dep in tr sed basename; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing="$missing $dep"
    else
      log "  $dep: found"
    fi
  done

  if [ -n "$missing" ]; then
    fail 10 "Missing dependencies:$missing. Please install the required tools and try again."
  fi

  # Version check: jq >= 1.6 (--argjson required)
  local jq_raw jq_ver
  jq_raw=$(jq --version 2>/dev/null || true)            # e.g. "jq-1.7.1"
  jq_ver="${jq_raw#jq-}"                                 # e.g. "1.7.1"
  if ! version_gte "$jq_ver" "1.6"; then
    fail 11 "jq >= 1.6 required (found $jq_raw). Please upgrade jq and try again."
  fi
  log "  jq: $jq_raw (>= 1.6 OK)"

  info "All dependencies satisfied."
}

############################################################
# Atomic file write
############################################################
atomic_write() {
  local src="$1"
  local dest="$2"
  mv "$src" "$dest"
}

check_deps

############################################################
# Config Paths
############################################################
CLAUDE_DIR="$HOME/.claude"
SETTINGS_JSON="$CLAUDE_DIR/settings.json"
HEADERS_SH="$CLAUDE_DIR/apollotech-otel-headers.sh"
HEADERS_SH_ABS=$(expand_path "$HEADERS_SH")
CONFIG="$CLAUDE_DIR/apollotech-config"
CONFIG_BAK="$CONFIG.bak_$(date +%Y%m%d_%H%M%S)"

info "Using config directory: $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR"

############################################################
# OTEL Headers Helper Setup
############################################################

download_and_validate_helper() {
  local url="${GITHUB_URL:-https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/refs/heads/main/apollotech-otel-headers.sh}"
  local dest="$1"
  info "Downloading apollotech-otel-headers.sh..."
  log "  URL: $url"
  local tmpfile
  tmpfile="${dest}.tmp.$$"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmpfile" || fail 20 "Failed to download $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$tmpfile" || fail 20 "Failed to download $url"
  else
    fail 11 "curl or wget required to download apollotech-otel-headers.sh."
  fi
  if [ ! -s "$tmpfile" ]; then
    rm -f "$tmpfile"
    fail 21 "Downloaded $dest is missing or empty."
  fi
  if ! grep -qE '^#!(\/bin\/bash|\/usr\/bin\/env bash)' "$tmpfile"; then
    rm -f "$tmpfile"
    fail 22 "Downloaded $dest does not have a valid bash shebang."
  fi
  if ! bash -n "$tmpfile"; then
    rm -f "$tmpfile"
    fail 23 "Downloaded $dest failed bash syntax check."
  fi
  chmod +x "$tmpfile"
  atomic_write "$tmpfile" "$dest"
  info "Headers helper installed: $dest"
}

if [ ! -f "$HEADERS_SH" ]; then
  download_and_validate_helper "$HEADERS_SH"
else
  info "Headers helper already present: $HEADERS_SH"
fi

############################################################
# Prompt for missing config
############################################################
prompt_for_config() {
  echo "APOLLO_USER and APOLLO_OTEL_TOKEN not found. Please enter credentials:"
  while true; do
    while true; do
      read -p "APOLLO_USER (email): " APOLLO_USER
      if [[ "$APOLLO_USER" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        break
      else
        echo "Invalid email format. Please try again."
      fi
    done
    read -s -p "APOLLO_OTEL_TOKEN: " APOLLO_OTEL_TOKEN
    echo
    if [ -n "$APOLLO_OTEL_TOKEN" ]; then
      info "Validating credentials against OTEL server..."
      if base64 --help 2>&1 | grep -q -- '-w '; then
        AUTH=$(echo -n "$APOLLO_USER:$APOLLO_OTEL_TOKEN" | base64 -w 0)
      else
        AUTH=$(echo -n "$APOLLO_USER:$APOLLO_OTEL_TOKEN" | base64)
      fi
      RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: Basic $AUTH" \
        -H "Content-Type: application/x-protobuf" \
        https://dev-ai.apollotech.co/otel/v1/logs)
      CURL_EXIT=$?
      if [ $CURL_EXIT -ne 0 ]; then
        echo "Network error: Unable to reach OTEL endpoint. Please check your connection and try again."
        continue
      fi
      log "  Server response: HTTP $RESPONSE"
      # 401/403 = bad credentials; anything else means auth passed
      if [ "$RESPONSE" = "401" ] || [ "$RESPONSE" = "403" ]; then
        echo "Credentials not accepted by OTEL server (HTTP $RESPONSE). Please try again."
      else
        info "Credentials validated (HTTP $RESPONSE)."
        break
      fi
    else
      echo "OTEL token cannot be empty. Please try again."
    fi
  done
  if [ -f "$CONFIG" ]; then
    cp "$CONFIG" "$CONFIG_BAK"
    info "Backed up existing config: $CONFIG_BAK"
  fi
  local tmpcfg
  tmpcfg="${CONFIG}.tmp.$$"
  echo "APOLLO_USER=$APOLLO_USER" > "$tmpcfg"
  echo "APOLLO_OTEL_TOKEN=$APOLLO_OTEL_TOKEN" >> "$tmpcfg"
  chmod 600 "$tmpcfg"
  atomic_write "$tmpcfg" "$CONFIG"
  info "Credentials saved: $CONFIG"
}

if [ ! -f "$CONFIG" ]; then
  if [ ! -t 0 ]; then
    echo ""
    echo "Error: credentials required but stdin is not a terminal (detected pipe or redirect)."
    echo ""
    echo "Download and run the script directly:"
    echo ""
    echo "  curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/setup-apollotech-otel-for-claude.sh -o /tmp/setup-apollotech-otel-for-claude.sh"
    echo "  bash /tmp/setup-apollotech-otel-for-claude.sh"
    echo "  rm /tmp/setup-apollotech-otel-for-claude.sh"
    echo ""
    exit 1
  fi
  prompt_for_config
else
  info "Config already present: $CONFIG"
fi

############################################################
# OTEL Environment Variables
############################################################
OTEL_ENV='{
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "https://dev-ai.apollotech.co/otel",
  "OTEL_LOG_TOOL_DETAILS": "1"
}'

############################################################
# Update settings.json
############################################################
update_settings_json() {
  if [ -f "$SETTINGS_JSON" ]; then
    info "Updating $SETTINGS_JSON..."
    if jq empty "$SETTINGS_JSON" >/dev/null 2>&1; then
      local tmpjson
      tmpjson="${SETTINGS_JSON}.tmp.$$"
      local bak
      bak="$SETTINGS_JSON.bak_$(date +%Y%m%d_%H%M%S)"
      cp "$SETTINGS_JSON" "$bak"
      info "Backed up settings.json: $bak"
      jq \
        --argjson otelenv "$OTEL_ENV" \
        --arg helper "$HEADERS_SH_ABS" \
        '.env = ((.env // {}) + $otelenv) | .otelHeadersHelper = $helper' "$SETTINGS_JSON" > "$tmpjson" || fail 30 "Failed to update settings.json."
      atomic_write "$tmpjson" "$SETTINGS_JSON"
      info "settings.json updated."
    else
      echo "Warning: $SETTINGS_JSON is not valid JSON. Manual intervention required." >&2
    fi
  else
    info "Creating $SETTINGS_JSON..."
    local tmpjson
    tmpjson="${SETTINGS_JSON}.tmp.$$"
    cat > "$tmpjson" <<EOF
{
  "env": $(echo "$OTEL_ENV"),
  "otelHeadersHelper": "$HEADERS_SH_ABS"
}
EOF
    atomic_write "$tmpjson" "$SETTINGS_JSON"
    info "settings.json created."
  fi
}

update_settings_json

############################################################
# Permissions
############################################################
info "Setting file permissions..."
chmod 600 "$CONFIG"
chmod 700 "$HEADERS_SH"
log "  $CONFIG: 600"
log "  $HEADERS_SH: 700"

############################################################
# Summary
############################################################
echo ""
echo "Setup complete. OTEL telemetry enabled for Claude CLI."
echo ""
echo "  Config:           $CONFIG"
echo "  Headers helper:   $HEADERS_SH_ABS"
echo "  settings.json:    $SETTINGS_JSON"
echo "  OTLP endpoint:    https://dev-ai.apollotech.co/otel"
echo ""
echo "Restart Claude Code (or start a new session) to apply."
