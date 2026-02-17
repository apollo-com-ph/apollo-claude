#!/usr/bin/env bash
# install_collector.sh — automated installer for the apollo-claude OTel collector stack
#
# Usage:
#   bash install_collector.sh
#
# What it does:
#   1. Validates OS (Ubuntu 22.04+) and sudo access
#   2. Prompts for domain, Grafana admin password, and first developer credentials
#   3. Installs system packages (nginx, certbot, ufw, etc.)
#   4. Installs Docker (if not present)
#   5. Configures UFW firewall
#   6. Clones repo and starts the collector stack
#   7. Configures Nginx reverse proxy
#   8. Provisions TLS via Let's Encrypt
#   9. Prints summary with next steps

set -euo pipefail

REPO_URL="https://github.com/apollo-com-ph/apollo-claude.git"
INSTALL_DIR="/opt/apollo-claude"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

prompt_value() {
    local prompt="$1" default="${2:-}" value
    if [ -n "$default" ]; then
        printf '\033[1;34m  ?\033[0m %s [%s]: ' "$prompt" "$default"
    else
        printf '\033[1;34m  ?\033[0m %s: ' "$prompt"
    fi
    read -r value
    printf '%s' "${value:-$default}"
}

prompt_secret() {
    local prompt="$1" default="${2:-}" value
    if [ -n "$default" ]; then
        printf '\033[1;34m  ?\033[0m %s [%s]: ' "$prompt" "(generated)"
    else
        printf '\033[1;34m  ?\033[0m %s: ' "$prompt"
    fi
    read -rs value
    printf '\n'
    printf '%s' "${value:-$default}"
}

generate_password() {
    head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 16
}

# ---------------------------------------------------------------------------
# Step 1: OS check
# ---------------------------------------------------------------------------

info "Checking operating system..."

if [ ! -f /etc/os-release ]; then
    die "Cannot detect OS — /etc/os-release not found. This installer requires Ubuntu 22.04+."
fi

. /etc/os-release

if [ "$ID" != "ubuntu" ]; then
    die "This installer requires Ubuntu. Detected: $ID ($PRETTY_NAME)"
fi

_version_major="${VERSION_ID%%.*}"
if [ "$_version_major" -lt 22 ] 2>/dev/null; then
    die "Ubuntu 22.04+ required. Detected: Ubuntu $VERSION_ID"
fi

ok "Ubuntu $VERSION_ID detected"

# ---------------------------------------------------------------------------
# Step 2: Sudo check
# ---------------------------------------------------------------------------

info "Checking sudo access..."

if ! sudo -v 2>/dev/null; then
    die "sudo access required. Run this script as a user with sudo privileges."
fi

ok "sudo access confirmed"

# ---------------------------------------------------------------------------
# Step 3: Prompt for configuration
# ---------------------------------------------------------------------------

info "Configuration"
printf '\n'

DOMAIN=$(prompt_value "Collector domain (e.g. dev-ai.apollotech.co)")
printf '\n'
if [ -z "$DOMAIN" ]; then
    die "Domain is required."
fi

_grafana_pw_default=$(generate_password)
GRAFANA_ADMIN_PASSWORD=$(prompt_secret "Grafana admin password" "$_grafana_pw_default")
if [ -z "$GRAFANA_ADMIN_PASSWORD" ]; then
    GRAFANA_ADMIN_PASSWORD="$_grafana_pw_default"
fi

printf '\n'
info "First developer credentials"
printf '\n'

DEV_USER=$(prompt_value "Developer username (APOLLO_USER)")
printf '\n'
if [ -z "$DEV_USER" ]; then
    die "Developer username is required."
fi

DEV_TOKEN=$(prompt_value "Developer token (APOLLO_OTEL_TOKEN)")
printf '\n'
if [ -z "$DEV_TOKEN" ]; then
    die "Developer token is required."
fi

printf '\n'
ok "Configuration collected"

# ---------------------------------------------------------------------------
# Step 4: Install system packages
# ---------------------------------------------------------------------------

info "Installing system packages..."

sudo apt-get update -qq
sudo apt-get install -y -qq nginx certbot python3-certbot-nginx apache2-utils ufw git > /dev/null

ok "System packages installed"

# ---------------------------------------------------------------------------
# Step 5: Install Docker (if not present)
# ---------------------------------------------------------------------------

info "Checking Docker..."

_need_group=false
if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version)"
else
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    ok "Docker installed"
    _need_group=true
fi

if ! groups "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    _need_group=true
    ok "Added $USER to docker group"
fi

# Use sg to run subsequent docker commands with the docker group
# without requiring re-login
_docker() {
    if [ "$_need_group" = true ]; then
        sg docker -c "docker $*"
    else
        docker "$@"
    fi
}

_docker_compose() {
    if [ "$_need_group" = true ]; then
        sg docker -c "docker compose $*"
    else
        docker compose "$@"
    fi
}

# ---------------------------------------------------------------------------
# Step 6: Configure UFW
# ---------------------------------------------------------------------------

info "Configuring firewall (UFW)..."

sudo ufw default deny incoming > /dev/null 2>&1
sudo ufw default allow outgoing > /dev/null 2>&1
sudo ufw allow OpenSSH > /dev/null 2>&1
sudo ufw allow 'Nginx Full' > /dev/null 2>&1

# Add DOCKER-USER chain rules (idempotent — check if already present)
if ! grep -q 'DOCKER-USER' /etc/ufw/after.rules 2>/dev/null; then
    sudo tee -a /etc/ufw/after.rules > /dev/null <<'EOF'

# Drop external traffic to Docker containers (DOCKER-USER chain).
# Containers bound to 127.0.0.1 are already safe; this is a safety net.
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN -s 127.0.0.0/8
-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -j DROP
COMMIT
EOF
    ok "DOCKER-USER iptables rules added"
else
    ok "DOCKER-USER iptables rules already present"
fi

sudo ufw --force enable > /dev/null 2>&1
sudo ufw reload > /dev/null 2>&1

ok "Firewall configured"

# ---------------------------------------------------------------------------
# Step 7: Clone repo and deploy collector
# ---------------------------------------------------------------------------

info "Deploying collector stack..."

if [ -d "$INSTALL_DIR" ]; then
    warn "$INSTALL_DIR already exists — using existing installation"
else
    sudo git clone "$REPO_URL" "$INSTALL_DIR"
    ok "Repository cloned to $INSTALL_DIR"
fi

sudo chown -R "$USER:$USER" "$INSTALL_DIR"

cd "$INSTALL_DIR/collector"

# Write .env for Grafana
cat > .env <<EOF
GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
EOF

ok "Grafana .env written"

# Ensure bind mount target exists
mkdir -p grafana/provisioning

# Generate htpasswd entry for first developer
htpasswd -nbB "$DEV_USER" "$DEV_TOKEN" >> htpasswd

ok "Developer $DEV_USER added to htpasswd"

# Start the stack
_docker_compose up -d

ok "Collector stack started"

# Wait for health check
info "Waiting for collector health check..."

_retries=0
_max_retries=30
while [ "$_retries" -lt "$_max_retries" ]; do
    if curl -sf http://localhost:13133 | grep -q '"status":"Server available"' 2>/dev/null; then
        break
    fi
    _retries=$((_retries + 1))
    sleep 2
done

if [ "$_retries" -ge "$_max_retries" ]; then
    warn "Collector health check timed out after 60s. Check: docker compose logs otel-collector"
else
    ok "Collector is healthy"
fi

# ---------------------------------------------------------------------------
# Step 8: Configure Nginx
# ---------------------------------------------------------------------------

info "Configuring Nginx..."

sudo cp nginx-site.conf /etc/nginx/sites-available/apollo-claude

# Replace domain placeholder
sudo sed -i "s/YOUR_DOMAIN/$DOMAIN/g" /etc/nginx/sites-available/apollo-claude

sudo ln -sf /etc/nginx/sites-available/apollo-claude /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

if sudo nginx -t 2>/dev/null; then
    sudo systemctl reload nginx
    ok "Nginx configured and reloaded"
else
    die "Nginx config test failed. Check: sudo nginx -t"
fi

# ---------------------------------------------------------------------------
# Step 9: TLS with Let's Encrypt
# ---------------------------------------------------------------------------

info "Setting up TLS with Let's Encrypt..."

_certbot_cmd="sudo certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email -d $DOMAIN"

if eval "$_certbot_cmd"; then
    ok "TLS certificates obtained"
else
    warn "Certbot failed — you can retry manually: $_certbot_cmd"
fi

# Verify certbot timer
if sudo systemctl list-timers certbot.timer --no-pager 2>/dev/null | grep -q certbot; then
    ok "Certbot auto-renewal timer is active"
else
    warn "Certbot timer not found — certificates may not auto-renew"
fi

# ---------------------------------------------------------------------------
# Step 10: Final summary
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m✓ Collector stack deployed successfully!\033[0m\n'
printf '\n'
printf '  ┌─────────────────────────────────────────────────────────────────┐\n'
printf '  │                         Summary                                │\n'
printf '  ├─────────────────────────────────────────────────────────────────┤\n'
printf '  │  OTel endpoint:   https://%s/otel\n' "$DOMAIN"
printf '  │  Grafana URL:     https://%s/grafana\n' "$DOMAIN"
printf '  │  Grafana login:   admin / %s\n' "$GRAFANA_ADMIN_PASSWORD"
printf '  │  Install dir:     %s/collector\n' "$INSTALL_DIR"
printf '  │  First developer: %s\n' "$DEV_USER"
printf '  └─────────────────────────────────────────────────────────────────┘\n'
printf '\n'
printf 'Next steps:\n'
printf '\n'
printf '  Add more developers:\n'
printf '    cd %s/collector\n' "$INSTALL_DIR"
printf '    htpasswd -nbB <username> <token> >> htpasswd\n'
printf '    docker compose restart otel-collector\n'
printf '\n'
printf '  View collector logs:\n'
printf '    cd %s/collector\n' "$INSTALL_DIR"
printf '    docker compose logs -f otel-collector\n'
printf '\n'
printf '  Configure a developer'\''s wrapper:\n'
printf '    APOLLO_USER=%s\n' "$DEV_USER"
printf '    APOLLO_OTEL_TOKEN=<their token>\n'
printf '    APOLLO_OTEL_SERVER=https://%s/otel\n' "$DOMAIN"
printf '\n'
