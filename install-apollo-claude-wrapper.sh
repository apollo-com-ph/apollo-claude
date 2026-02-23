#!/usr/bin/env sh
# install-apollo-claude-wrapper.sh — one-liner installer for the apollo-claude CLI wrapper
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install-apollo-claude-wrapper.sh | sh
#
# What it does:
#   1. Checks that `claude` is installed
#   2. Downloads bin/apollo-claude to ~/.local/bin/
#   3. Adds ~/.local/bin to PATH in your shell rc (if needed)
#   4. Creates ~/.apollo-claude/ config dir
#   5. Verifies the install

set -eu

BIN_DIR="${HOME}/.local/bin"
WRAPPER="${BIN_DIR}/apollo-claude"
CONFIG_DIR="${HOME}/.apollo-claude"
RAW_URL="https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/bin/apollo-claude"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: Pre-flight — check dependencies
# ---------------------------------------------------------------------------

info "Checking dependencies..."

if ! command -v bash >/dev/null 2>&1; then
    die "bash is not installed. apollo-claude requires bash to run."
fi

ok "bash found: $(command -v bash)"

if ! command -v claude >/dev/null 2>&1; then
    die "claude is not installed or not in PATH.

  Install Claude Code first:
    https://docs.anthropic.com/en/docs/claude-code/getting-started

  Then re-run this installer."
fi

ok "claude found: $(command -v claude)"

if command -v curl >/dev/null 2>&1; then
    ok "curl found (used for auto-updates)"
elif command -v wget >/dev/null 2>&1; then
    ok "wget found (used for auto-updates)"
else
    die "Neither curl nor wget found. Install one and retry."
fi

# Coreutils used by the wrapper
_missing=""
for cmd in grep sed date stat mktemp head cut base64; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        _missing="${_missing} ${cmd}"
    fi
done
if [ -n "$_missing" ]; then
    die "Missing required utilities:${_missing}"
fi
ok "coreutils found (grep, sed, date, stat, mktemp, head, cut, base64)"

if command -v git >/dev/null 2>&1; then
    ok "git found (used for repo detection)"
else
    warn "git not found — repo detection will fall back to directory name"
fi

# ---------------------------------------------------------------------------
# Step 2: Download wrapper to ~/.local/bin/apollo-claude
# ---------------------------------------------------------------------------

info "Installing apollo-claude to ${WRAPPER}..."

mkdir -p "${BIN_DIR}"

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${RAW_URL}" -o "${WRAPPER}"
else
    wget -qO "${WRAPPER}" "${RAW_URL}"
fi

chmod +x "${WRAPPER}"

case "$(head -1 "${WRAPPER}")" in
    '#!'*) ;;
    *) rm -f "${WRAPPER}"; die "Downloaded file is not a valid script" ;;
esac

if ! bash -n "${WRAPPER}" 2>/dev/null; then
    rm -f "${WRAPPER}"
    die "Downloaded wrapper failed syntax check"
fi

ok "Wrapper installed"

# ---------------------------------------------------------------------------
# Step 3: Add ~/.local/bin to PATH (persistently, idempotent)
# ---------------------------------------------------------------------------

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

# Detect rc file from $SHELL
case "${SHELL:-}" in
    */zsh)  RC_FILE="${HOME}/.zshrc" ;;
    */bash) RC_FILE="${HOME}/.bashrc" ;;
    *)
        # Fallback: try .bashrc, then .profile
        if [ -f "${HOME}/.bashrc" ]; then
            RC_FILE="${HOME}/.bashrc"
        else
            RC_FILE="${HOME}/.profile"
        fi
        ;;
esac

info "Checking PATH in ${RC_FILE}..."

if echo "${PATH}" | tr ':' '\n' | grep -qx "${BIN_DIR}"; then
    ok "~/.local/bin already in current PATH"
elif [ -f "${RC_FILE}" ] && grep -qF "${BIN_DIR}" "${RC_FILE}"; then
    ok "~/.local/bin already in ${RC_FILE}"
else
    printf '\n# Added by apollo-claude installer\n%s\n' "${PATH_LINE}" >> "${RC_FILE}"
    ok "Added ~/.local/bin to ${RC_FILE}"
fi

# ---------------------------------------------------------------------------
# Step 4: Create config dir
# ---------------------------------------------------------------------------

info "Setting up config directory..."

mkdir -p "${CONFIG_DIR}"
touch "${CONFIG_DIR}/.last_update_check" 2>/dev/null || true
ok "Config dir ready: ${CONFIG_DIR}"

# ---------------------------------------------------------------------------
# Step 5: Verify
# ---------------------------------------------------------------------------

info "Verifying install..."

if [ -x "${WRAPPER}" ]; then
    ok "Wrapper ready at ${WRAPPER}"
else
    die "Something went wrong — ${WRAPPER} is not executable"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m✓ apollo-claude installed successfully!\033[0m\n\n'
printf 'Next steps:\n'
printf '  1. Reload your shell (or open a new terminal):\n'
printf '       source %s\n' "${RC_FILE}"
printf '  2. Run apollo-claude — it will prompt for your credentials on first use:\n'
printf '       apollo-claude\n\n'
printf '  Tip: To also enable telemetry in VS Code / JetBrains:\n'
printf '         curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/setup-apollotech-otel-for-claude.sh -o /tmp/setup-apollotech-otel-for-claude.sh\n'
printf '         bash /tmp/setup-apollotech-otel-for-claude.sh\n'
printf '         rm /tmp/setup-apollotech-otel-for-claude.sh\n'
printf '\n'
