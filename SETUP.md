# OTel Collector Setup

The `collector/` directory contains a Docker Compose stack that receives telemetry from `apollo-claude` wrappers and makes it available in Grafana dashboards. This guide covers provisioning a fresh Ubuntu server to run the full stack.

## Quick install

Run the automated installer on a fresh Ubuntu 22.04+ server:

```sh
bash install_collector.sh
```

It handles everything below (packages, Docker, firewall, nginx, TLS, first developer). If you prefer to set things up manually, follow the steps in the rest of this guide.

## Stack overview

| Service | Image / Package | Port (localhost) | Purpose |
|---------|----------------|------------------|---------|
| OTel Collector | `otel/opentelemetry-collector-contrib:0.116.0` | 4318 (OTLP HTTP), 8889 (Prometheus scrape), 13133 (health) | Receives metrics and logs from wrappers, exports to Prometheus and file |
| Prometheus | `prom/prometheus:v2.55.1` | 9090 | Stores metrics (90-day retention) |
| Grafana | `grafana/grafana:11.4.0` | 3000 | Dashboards and alerting |
| Nginx | system package | 80, 443 | TLS termination and reverse proxy |
| Certbot | system package | — | Let's Encrypt certificate auto-renewal |

All Docker services bind to `127.0.0.1` only. Nginx handles TLS and proxies external traffic.

> **Warning — Docker bypasses UFW.** Docker manipulates iptables directly, so UFW rules do not apply to Docker-published ports. A `ports: "4318:4318"` binding would be publicly reachable even if `ufw deny 4318` is set. We use three layers of defence:
>
> 1. **Localhost binding** — every port in `docker-compose.yml` is prefixed with `127.0.0.1:`, so the port physically only listens on loopback. **Do not remove this prefix.**
> 2. **Nginx gateway** — the only processes listening on public ports 80/443 are nginx, which proxies to localhost.
> 3. **DOCKER-USER iptables chain** — a UFW-after rule (see step 1 below) that drops non-loopback traffic to Docker containers, as a safety net against accidental misconfiguration.

## Prerequisites

- Ubuntu 22.04+ server with a public IP
- A DNS A record pointing your domain (e.g. `dev-ai.apollotech.co`) to the server
- SSH access with sudo

## 1. Install system packages and configure firewall

```sh
sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx apache2-utils ufw
```

`apache2-utils` provides `htpasswd` for managing developer credentials.

Enable UFW and allow only SSH, HTTP, and HTTPS:

```sh
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
```

Lock down Docker's iptables chain so containers are only reachable via loopback, even if someone accidentally removes a `127.0.0.1:` prefix in docker-compose.yml:

```sh
sudo tee /etc/ufw/after.rules >> /dev/null <<'EOF'

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
sudo ufw reload
```

## 2. Install Docker

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
```

Log out and back in for the group change to take effect.

## 3. Deploy the collector stack

Clone the repo and start the services:

```sh
git clone https://github.com/apollo-com-ph/apollo-claude.git
cd apollo-claude/collector
```

Optionally create a `.env` file for Grafana:

```sh
echo 'GRAFANA_ADMIN_PASSWORD=your-secure-password' > .env
```

`GRAFANA_ADMIN_PASSWORD` defaults to `changeme` if not set.

Create the Grafana provisioning directory (bind mount target):

```sh
mkdir -p grafana/provisioning
```

Start the stack:

```sh
docker compose up -d
```

Verify the collector is healthy:

```sh
curl -s http://localhost:13133 | grep -q '"status":"Server available"' && echo "OK"
```

## 4. Configure Nginx

Copy the provided site config, replacing `YOUR_DOMAIN` with your actual domain:

```sh
sudo cp nginx-site.conf /etc/nginx/sites-available/apollo-claude
sudo sed -i 's/YOUR_DOMAIN/dev-ai.apollotech.co/g' /etc/nginx/sites-available/apollo-claude
sudo ln -sf /etc/nginx/sites-available/apollo-claude /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

The site config proxies (all on a single domain, path-based routing):
- `https://dev-ai.apollotech.co/otel/v1/*` → OTel Collector (port 4318), POST only
- `https://dev-ai.apollotech.co/grafana/*` → Grafana (port 3000)

## 5. Set up TLS with Let's Encrypt

```sh
sudo certbot --nginx -d dev-ai.apollotech.co
```

Certbot automatically:
- Obtains certificates from Let's Encrypt
- Patches the nginx config with `ssl_certificate` / `ssl_certificate_key` directives
- Installs a systemd timer (`certbot.timer`) that renews certificates before expiry

Verify auto-renewal is active:

```sh
sudo systemctl list-timers certbot.timer
```

Test a dry-run renewal:

```sh
sudo certbot renew --dry-run
```

## 6. Add developer credentials

Each developer gets a username/password entry in the htpasswd file. The username is their `APOLLO_USER` and the password is their `APOLLO_OTEL_TOKEN`.

Add a developer:

```sh
cd apollo-claude/collector
htpasswd -nbB alice at_xxxxxxxxxxxx >> htpasswd
docker compose restart otel-collector
```

To revoke a developer, remove their line from `htpasswd` and restart.

## Data pipeline

```
apollo-claude wrappers
  → HTTPS /otel/v1/* (nginx, TLS via Let's Encrypt)
  → OTLP HTTP (port 4318, basic auth via htpasswd)
  → OTel Collector
      ├─ metrics → Prometheus scrape endpoint (:8889) → Prometheus → Grafana
      └─ logs   → /var/log/otel/claude-events.jsonl (rotated, 100MB/30d)
```

## Privacy

The collector applies defence-in-depth filtering — the `attributes` processor strips `prompt`, `completion`, and `message.content` keys from all logs, even if they were accidentally included. The wrapper itself never sends prompt content, but the collector enforces this as a second layer.

## Customization

**Remote forwarding**: To forward telemetry to a central OTLP backend, uncomment the `otlp/remote` exporter in `otel-collector-config.yaml` and add it to the relevant pipeline.

**Retention**: Prometheus retention is set to 90 days via `--storage.tsdb.retention.time=90d` in `docker-compose.yml`.

**Log rotation**: File logs rotate at 100MB with 5 backups kept for 30 days, configured in the `file` exporter.

## Maintenance

**Update container images**: Edit the image tags in `docker-compose.yml`, then:

```sh
cd apollo-claude/collector
docker compose pull && docker compose up -d
```

**Renew certificates manually** (not normally needed):

```sh
sudo certbot renew
```

**View collector logs**:

```sh
cd apollo-claude/collector
docker compose logs -f otel-collector
```
