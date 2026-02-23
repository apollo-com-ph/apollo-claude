#!/bin/bash
set -euo pipefail

############################################################
# Usage / Help
############################################################
usage() {
  cat <<EOF
Usage: $0 [--help] [--verbose] [--debug]

Sets up OTEL telemetry for Claude CLI.

Options:
  --help      Show this help message and exit
  --verbose   Enable verbose output
  --debug     Enable debug output (implies verbose)

Environment variables:
  GITHUB_URL  Override the GitHub URL for apollotech-otel-headers.sh
EOF
}

############################################################
# Globals for verbosity/debug
############################################################
VERBOSE=0
DEBUG=0

log() {
  if [ "$VERBOSE" -eq 1 ] || [ "$DEBUG" -eq 1 ]; then
    echo "$@"
  fi
}

debug() {
  if [ "$DEBUG" -eq 1 ]; then
    echo "[DEBUG] $@"
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

# Simple OTEL Setup Script for Default Claude
# This script enables OTEL telemetry for the default claude CLI.
# It checks for dependencies, configures OTEL variables, updates global settings, and ensures idempotency.

# --- Dependency Check ---
############################################################
# Dependency Check
############################################################

check_deps() {
  local missing=""
  for dep in bash claude jq base64; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing="$missing $dep"
    fi
  done
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing="$missing curl-or-wget"
  fi
  for dep in date chmod cp mkdir; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing="$missing $dep"
    fi
  done
  if [ -n "$missing" ]; then
    fail 10 "Missing dependencies:$missing. Please install the required tools and try again."
  fi
}

############################################################
# Atomic file write
############################################################
atomic_write() {
  local src="$1"
  local dest="$2"
  mv "$src" "$dest"
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
    --debug)
      DEBUG=1; VERBOSE=1;;
    *)
      echo "Unknown argument: $arg" >&2; usage; exit 2;;
  esac
done

check_deps

# --- Config Paths ---
############################################################
# Config Paths
############################################################
CLAUDE_DIR="$HOME/.claude"
SETTINGS_JSON="$CLAUDE_DIR/settings.json"
HEADERS_SH="$CLAUDE_DIR/apollotech-otel-headers.sh"
HEADERS_SH_ABS=$(expand_path "$HEADERS_SH")
CONFIG="$CLAUDE_DIR/apollotech-config"
CONFIG_BAK="$CONFIG.bak_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$CLAUDE_DIR"

# --- OTEL Headers Helper Setup ---
############################################################
# OTEL Headers Helper Setup
############################################################

download_and_validate_helper() {
  local url="${GITHUB_URL:-https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/refs/heads/main/apollotech-otel-headers.sh}"
  local dest="$1"
  log "Downloading apollotech-otel-headers.sh from $url ..."
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
  log "Downloaded $dest from $url and validated."
}

if [ ! -f "$HEADERS_SH" ]; then
  download_and_validate_helper "$HEADERS_SH"
fi

# --- Prompt for missing config ---
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
      if base64 --help 2>&1 | grep -q -- '-w '; then
        AUTH=$(echo -n "$APOLLO_USER:$APOLLO_OTEL_TOKEN" | base64 -w 0)
      else
        AUTH=$(echo -n "$APOLLO_USER:$APOLLO_OTEL_TOKEN" | base64)
      fi
      RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Basic $AUTH" https://dev-ai.apollotech.co/otel/v1/metrics)
      CURL_EXIT=$?
      if [ $CURL_EXIT -ne 0 ]; then
        echo "Network error: Unable to reach OTEL endpoint. Please check your connection and try again."
        continue
      fi
      if [ "$RESPONSE" = "200" ] || [ "$RESPONSE" = "204" ]; then
        break
      else
        echo "Credentials not accepted by OTEL server (HTTP $RESPONSE). Please try again."
      fi
    else
      echo "OTEL token cannot be empty. Please try again."
    fi
  done
  if [ -f "$CONFIG" ]; then
    cp "$CONFIG" "$CONFIG_BAK"
    echo "Backed up $CONFIG to $CONFIG_BAK"
  fi
  local tmpcfg
  tmpcfg="${CONFIG}.tmp.$$"
  echo "APOLLO_USER=$APOLLO_USER" > "$tmpcfg"
  echo "APOLLO_OTEL_TOKEN=$APOLLO_OTEL_TOKEN" >> "$tmpcfg"
  chmod 600 "$tmpcfg"
  atomic_write "$tmpcfg" "$CONFIG"
  echo "Created $CONFIG"
}

if [ ! -f "$CONFIG" ]; then
  prompt_for_config
fi

# --- Backup settings.json ---
if [ -f "$SETTINGS_JSON" ]; then
  TS=$(date +%Y%m%d_%H%M%S)
  cp "$SETTINGS_JSON" "$SETTINGS_JSON.bak_$TS"
  echo "Backed up $SETTINGS_JSON to $SETTINGS_JSON.bak_$TS"
fi

# --- OTEL Environment Variables ---
OTEL_ENV='{
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "https://dev-ai.apollotech.co/otel",
  "OTEL_METRICS_INCLUDE_SESSION_ID": "true",
  "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "true",
  "OTEL_LOG_TOOL_DETAILS": "1"
}'

# --- Update settings.json ---
############################################################
# Update settings.json
############################################################
update_settings_json() {
  if [ -f "$SETTINGS_JSON" ]; then
    if jq empty "$SETTINGS_JSON" >/dev/null 2>&1; then
      local tmpjson
      tmpjson="${SETTINGS_JSON}.tmp.$$"
      jq \
        --argfile otelenv <(echo "$OTEL_ENV") \
        --arg helper "$HEADERS_SH_ABS" \
        '.env = (.env // {} | ($otelenv | fromjson | reduce to_entries[] as $item (. ; .[$item.key] = $item.value))) | .otelHeadersHelper = $helper' "$SETTINGS_JSON" > "$tmpjson" || fail 30 "Failed to update settings.json."
      atomic_write "$tmpjson" "$SETTINGS_JSON"
      echo "settings.json updated (env merged)."
    else
      echo "Warning: $SETTINGS_JSON is not valid JSON. Manual intervention required."
    fi
  else
    local tmpjson
    tmpjson="${SETTINGS_JSON}.tmp.$$"
    cat > "$tmpjson" <<EOF
{
  "env": $(echo "$OTEL_ENV"),
  "otelHeadersHelper": "$HEADERS_SH_ABS"
}
EOF
    atomic_write "$tmpjson" "$SETTINGS_JSON"
    echo "settings.json created."
  fi
}

update_settings_json

# --- User Feedback ---
############################################################
# User Feedback
############################################################
chmod 600 "$CONFIG"
chmod 700 "$HEADERS_SH"
echo ""
echo "OTEL telemetry enabled for Claude CLI."
if [ -f "$CONFIG_BAK" ]; then
  echo "apollotech-config backed up to $CONFIG_BAK"
fi
echo "settings.json location: $SETTINGS_JSON"
echo "otelHeadersHelper set to $HEADERS_SH_ABS"
echo "env variables configured."
if [ -f "$CONFIG" ]; then
  echo "Credentials validated and saved."
fi
