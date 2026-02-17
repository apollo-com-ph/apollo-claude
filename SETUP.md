# OTel Collector Setup

The `collector/` directory contains a Docker Compose stack that receives telemetry from `apollo-claude` wrappers and makes it available in Grafana dashboards.

## Stack overview

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| OTel Collector | `otel/opentelemetry-collector-contrib:0.116.0` | 4318 (OTLP HTTP), 8889 (Prometheus scrape), 13133 (health) | Receives metrics and logs from wrappers, exports to Prometheus and file |
| Prometheus | `prom/prometheus:v2.55.1` | 9090 | Stores metrics (90-day retention) |
| Grafana | `grafana/grafana:11.4.0` | 3000 | Dashboards and alerting |

## Prerequisites

- Docker and Docker Compose
- A reverse proxy (e.g. nginx, Caddy) terminating TLS in front of port 4318 — the collector listens on plain HTTP

## Configuration

### Developer credentials (htpasswd)

Each developer gets a unique username/password entry in `collector/htpasswd`. The username is their `APOLLO_USER` and the password is their `APOLLO_OTEL_TOKEN`.

Add a developer:

```sh
htpasswd -nbB alice at_xxxxxxxxxxxx >> collector/htpasswd
```

After adding or removing entries, restart the collector:

```sh
cd collector && docker compose restart otel-collector
```

### Grafana

Optionally create a `.env` file in the `collector/` directory:

```sh
GRAFANA_ADMIN_PASSWORD=your-secure-password
```

`GRAFANA_ADMIN_PASSWORD` defaults to `changeme` if not set.

## Running

```sh
cd collector
docker compose up -d
```

Verify the collector is healthy:

```sh
curl -s http://localhost:13133 | grep -q '"status":"Server available"' && echo "OK"
```

## Data pipeline

```
apollo-claude wrappers
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
