#!/usr/bin/env sh
# install_otel.sh — configure global OTEL telemetry for all Claude Code usage
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install_otel.sh | sh
#
# What it does:
#   1. Checks dependencies (bash, jq, curl/wget, base64)
#   2. Collects credentials (or reuses existing ~/.apollo-claude/config)
#   3. Creates ~/.apollo-claude/otel-headers.sh (auth helper for Claude Code)
#   4. Merges OTEL env vars into ~/.claude/settings.json
#
# This enables telemetry for ALL Claude Code usage: bare `claude` CLI,
# VS Code plugin, and JetBrains plugin — no wrapper needed.

set -eu

CONFIG_DIR="${HOME}/.apollo-claude"
CONFIG_FILE="${CONFIG_DIR}/config"
HEADERS_HELPER="${CONFIG_DIR}/otel-headers.sh"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_SETTINGS="${CLAUDE_DIR}/settings.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# HTTP helpers (prefer curl, fall back to wget)
# ---------------------------------------------------------------------------

_test_token() {
    _server="$1"; _user="$2"; _token="$3"
    _status=""
    if command -v curl >/dev/null 2>&1; then
        _status="$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            --connect-timeout 5 --max-time 10 \
            -u "${_user}:${_token}" \
            "${_server}/v1/metrics" 2>/dev/null)" || true
    elif command -v wget >/dev/null 2>&1; then
        _status="$(wget --spider -q -S --timeout=10 \
            --user="${_user}" --password="${_token}" \
            -O /dev/null "${_server}/v1/metrics" 2>&1 \
            | grep -m1 'HTTP/' | grep -oE '[0-9]{3}' || echo "000")"
    else
        return 0  # can't test, assume OK
    fi
    # 401/403 = bad credentials; 000 = network error; anything else = auth OK
    case "${_status}" in
        401|403) return 1 ;;
        000)     return 2 ;;
        *)       return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 1: Pre-flight — check dependencies
# ---------------------------------------------------------------------------

info "Checking dependencies..."

if ! command -v bash >/dev/null 2>&1; then
    die "bash is not installed. The OTEL headers helper requires bash."
fi
ok "bash found: $(command -v bash)"

if command -v claude >/dev/null 2>&1; then
    ok "claude found: $(command -v claude)"
else
    warn "claude not found — settings.json will be created but Claude Code must be installed before telemetry works"
fi

if command -v curl >/dev/null 2>&1; then
    ok "curl found"
elif command -v wget >/dev/null 2>&1; then
    ok "wget found"
else
    die "Neither curl nor wget found. Install one and retry."
fi

if ! command -v jq >/dev/null 2>&1; then
    die "jq is not installed. Install it first:

  macOS:   brew install jq
  Ubuntu:  sudo apt install jq
  Fedora:  sudo dnf install jq

Then re-run this installer."
fi
ok "jq found: $(command -v jq)"

if ! command -v base64 >/dev/null 2>&1; then
    die "base64 is not installed."
fi
ok "base64 found"

# ---------------------------------------------------------------------------
# Step 2: Collect or reuse credentials
# ---------------------------------------------------------------------------

APOLLO_USER=""
APOLLO_OTEL_TOKEN=""
APOLLO_OTEL_SERVER=""

if [ -f "${CONFIG_FILE}" ]; then
    info "Found existing config at ${CONFIG_FILE}, reusing credentials..."
    while IFS='=' read -r key value; do
        # trim whitespace from key
        key="$(echo "${key}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # skip comments and blank lines
        case "${key}" in
            ''|'#'*) continue ;;
        esac
        # trim whitespace from value
        value="$(echo "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "${key}" in
            APOLLO_USER)        APOLLO_USER="${value}" ;;
            APOLLO_OTEL_TOKEN)  APOLLO_OTEL_TOKEN="${value}" ;;
            APOLLO_OTEL_SERVER) APOLLO_OTEL_SERVER="${value}" ;;
        esac
    done < "${CONFIG_FILE}"
    if [ -n "${APOLLO_USER}" ] && [ -n "${APOLLO_OTEL_TOKEN}" ]; then
        ok "Credentials loaded: APOLLO_USER=${APOLLO_USER}"
    else
        warn "Config file exists but missing credentials, prompting..."
        APOLLO_USER=""
        APOLLO_OTEL_TOKEN=""
    fi
fi

if [ -z "${APOLLO_USER}" ] || [ -z "${APOLLO_OTEL_TOKEN}" ]; then
    printf '\n'
    printf 'apollo-claude OTEL setup\n'
    printf '========================\n'
    printf 'Get your credentials from your team lead.\n\n'

    _default_user=""
    if command -v git >/dev/null 2>&1; then
        _default_user="$(git config user.email 2>/dev/null || true)"
    fi
    if [ -z "${_default_user}" ]; then
        _default_user="${USER:-}"
    fi

    printf "  APOLLO_USER (your official email"
    if [ -n "${_default_user}" ]; then
        printf ", default: %s" "${_default_user}"
    fi
    printf "): "
    read -r APOLLO_USER
    APOLLO_USER="${APOLLO_USER:-${_default_user}}"
    if [ -z "${APOLLO_USER}" ]; then
        die "APOLLO_USER is required."
    fi

    while true; do
        printf "  APOLLO_OTEL_SERVER (default: https://dev-ai.apollotech.co/otel): "
        read -r APOLLO_OTEL_SERVER
        APOLLO_OTEL_SERVER="${APOLLO_OTEL_SERVER:-https://dev-ai.apollotech.co/otel}"

        printf "  APOLLO_OTEL_TOKEN (looks like at_xxxx...): "
        read -r APOLLO_OTEL_TOKEN
        if [ -z "${APOLLO_OTEL_TOKEN}" ]; then
            echo "  Token cannot be empty." >&2
            continue
        fi

        _test_token "${APOLLO_OTEL_SERVER}" "${APOLLO_USER}" "${APOLLO_OTEL_TOKEN}" && _rc=0 || _rc=$?
        if [ "${_rc}" -eq 0 ]; then
            break
        elif [ "${_rc}" -eq 2 ]; then
            echo "  Could not reach ${APOLLO_OTEL_SERVER} — check the server URL and try again." >&2
        else
            echo "  Credentials rejected by ${APOLLO_OTEL_SERVER} (HTTP 401). Check your user/token and try again." >&2
        fi
    done
    printf '\n'

    mkdir -p "${CONFIG_DIR}"
    cat > "${CONFIG_FILE}" <<EOF
APOLLO_USER=${APOLLO_USER}
APOLLO_OTEL_TOKEN=${APOLLO_OTEL_TOKEN}
APOLLO_OTEL_SERVER=${APOLLO_OTEL_SERVER}
EOF
    chmod 600 "${CONFIG_FILE}"
    ok "Credentials saved to ${CONFIG_FILE}"
fi

APOLLO_OTEL_SERVER="${APOLLO_OTEL_SERVER:-https://dev-ai.apollotech.co/otel}"

# ---------------------------------------------------------------------------
# Step 3: Create otel-headers.sh
# ---------------------------------------------------------------------------

info "Creating OTEL auth helper at ${HEADERS_HELPER}..."

mkdir -p "${CONFIG_DIR}"

cat > "${HEADERS_HELPER}" <<'HELPEREOF'
#!/usr/bin/env bash
# otel-headers.sh — outputs JSON auth headers for Claude Code's otelHeadersHelper
# Generated by install_otel.sh. Reads credentials from ~/.apollo-claude/config.
set -euo pipefail

CONFIG_FILE="${HOME}/.apollo-claude/config"
APOLLO_USER=""
APOLLO_OTEL_TOKEN=""

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "otel-headers.sh: config not found at ${CONFIG_FILE}" >&2
    exit 1
fi

while IFS='=' read -r key value; do
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }" ]] && continue
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "${key}" != APOLLO_* ]] && continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "${key}" in
        APOLLO_USER)       APOLLO_USER="${value}" ;;
        APOLLO_OTEL_TOKEN) APOLLO_OTEL_TOKEN="${value}" ;;
    esac
done < "${CONFIG_FILE}"

if [[ -z "${APOLLO_USER}" ]] || [[ -z "${APOLLO_OTEL_TOKEN}" ]]; then
    echo "otel-headers.sh: APOLLO_USER or APOLLO_OTEL_TOKEN not set in ${CONFIG_FILE}" >&2
    exit 1
fi

_basic="$(printf '%s:%s' "${APOLLO_USER}" "${APOLLO_OTEL_TOKEN}" | base64 -w0 2>/dev/null || printf '%s:%s' "${APOLLO_USER}" "${APOLLO_OTEL_TOKEN}" | base64)"
printf '{"Authorization": "Basic %s"}\n' "${_basic}"
HELPEREOF

chmod +x "${HEADERS_HELPER}"
ok "Helper script created"

# ---------------------------------------------------------------------------
# Step 4: Merge OTEL settings into ~/.claude/settings.json
# ---------------------------------------------------------------------------

info "Configuring ${CLAUDE_SETTINGS}..."

mkdir -p "${CLAUDE_DIR}"

# Seed settings.json if it doesn't exist
if [ ! -f "${CLAUDE_SETTINGS}" ]; then
    echo '{}' > "${CLAUDE_SETTINGS}"
    ok "Created new settings.json"
fi

# Validate existing JSON; back up if corrupt
if ! jq empty "${CLAUDE_SETTINGS}" 2>/dev/null; then
    cp "${CLAUDE_SETTINGS}" "${CLAUDE_SETTINGS}.bak"
    warn "Corrupt settings.json backed up to ${CLAUDE_SETTINGS}.bak"
    echo '{}' > "${CLAUDE_SETTINGS}"
fi

# Merge OTEL env vars and otelHeadersHelper
jq --arg server "${APOLLO_OTEL_SERVER}" \
   --arg user "${APOLLO_USER}" \
   --arg helper "${HEADERS_HELPER}" \
  '.env = ((.env // {}) * {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": $server,
    "OTEL_RESOURCE_ATTRIBUTES": ("developer=" + $user + ",team=engineering"),
    "OTEL_METRICS_INCLUDE_SESSION_ID": "true",
    "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "true",
    "OTEL_LOG_TOOL_DETAILS": "1"
  }) | .otelHeadersHelper = $helper' \
  "${CLAUDE_SETTINGS}" > "${CLAUDE_SETTINGS}.tmp" \
  && mv "${CLAUDE_SETTINGS}.tmp" "${CLAUDE_SETTINGS}"

ok "OTEL settings merged into settings.json"

# ---------------------------------------------------------------------------
# Step 5: Verify
# ---------------------------------------------------------------------------

info "Verifying..."

# Test helper script
if "${HEADERS_HELPER}" >/dev/null 2>&1; then
    ok "otel-headers.sh produces valid output"
else
    warn "otel-headers.sh returned an error — check ${CONFIG_FILE}"
fi

# Verify settings.json has our keys
if jq -e '.env.CLAUDE_CODE_ENABLE_TELEMETRY' "${CLAUDE_SETTINGS}" >/dev/null 2>&1; then
    ok "settings.json contains OTEL configuration"
else
    warn "settings.json may not have been updated correctly"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m✓ Global OTEL telemetry configured!\033[0m\n\n'
printf 'Telemetry is now enabled for all Claude Code usage:\n'
printf '  • VS Code (Claude Code extension)\n'
printf '  • JetBrains (Claude Code plugin)\n'
printf '  • CLI (bare claude command)\n\n'
printf 'Config:   %s\n' "${CONFIG_FILE}"
printf 'Helper:   %s\n' "${HEADERS_HELPER}"
printf 'Settings: %s\n\n' "${CLAUDE_SETTINGS}"
printf 'Note: Per-repo tagging is not available in global mode.\n'
printf '      For per-repo metrics, use the apollo-claude CLI wrapper.\n\n'
printf 'To uninstall (removes OTEL settings, keeps other settings.json entries):\n\n'
printf "  rm -f %s\n" "${HEADERS_HELPER}"
printf "  jq 'del(.otelHeadersHelper) | if .env then .env |= del("
printf ".CLAUDE_CODE_ENABLE_TELEMETRY, .OTEL_METRICS_EXPORTER, "
printf ".OTEL_LOGS_EXPORTER, .OTEL_EXPORTER_OTLP_PROTOCOL, "
printf ".OTEL_EXPORTER_OTLP_ENDPOINT, .OTEL_RESOURCE_ATTRIBUTES, "
printf ".OTEL_METRICS_INCLUDE_SESSION_ID, .OTEL_METRICS_INCLUDE_ACCOUNT_UUID, "
printf ".OTEL_LOG_TOOL_DETAILS) else . end' %s > %s.tmp && mv %s.tmp %s\n\n" \
    "${CLAUDE_SETTINGS}" "${CLAUDE_SETTINGS}" "${CLAUDE_SETTINGS}" "${CLAUDE_SETTINGS}"
