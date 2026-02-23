# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

apollo-claude configures OpenTelemetry telemetry for Claude Code, giving ApolloTech engineering visibility into usage across the team — by developer, repo, and model. It does **not** capture prompts, responses, or code — only aggregate metrics (session count, cost, tokens, active time, etc.).

The primary installer is `setup-apollotech-otel-for-claude.sh`, which writes into `~/.claude/` and covers all Claude Code usage (VS Code, JetBrains, CLI) without a wrapper. An optional CLI wrapper (`bin/apollo-claude`) exists for teams that need auth isolation.

## Architecture

```
Primary path (setup-apollotech-otel-for-claude.sh):
  setup-apollotech-otel-for-claude.sh configures ~/.claude/ once
    → downloads apollotech-otel-headers.sh to ~/.claude/
    → saves credentials to ~/.claude/apollotech-config (APOLLO_USER, APOLLO_OTEL_TOKEN)
    → merges OTEL env vars into ~/.claude/settings.json
    → otelHeadersHelper points to ~/.claude/apollotech-otel-headers.sh
    → apollotech-otel-headers.sh reads ~/.claude/apollotech-config,
      detects git repo from CWD,
      outputs {"Authorization": "Basic ...", "X-Apollo-Repository": "org/repo"}
    → Claude Code attaches headers to OTLP requests at startup + every ~29 min
    → OTel Collector extracts X-Apollo-Repository → repository resource attribute
    → covers all Claude Code sessions: CLI, VS Code, JetBrains

Optional CLI wrapper path (bin/apollo-claude):
  User runs apollo-claude
    → sets CLAUDE_CONFIG_DIR=~/.apollo-claude (auth isolation from plain claude)
    → handles --self-update / --wrapper-version if requested (no config needed)
    → loads ~/.apollo-claude/config (APOLLO_USER, APOLLO_OTEL_TOKEN)
    → auto-update check (daily, via _fetch_stdout/_fetch_to_file helpers)
    → claude auth login check (skipped if .credentials.json exists)
    → detects git repo context (org/repo from remote URL)
    → sets OTEL_* env vars
    → exec claude "$@"
```

**Primary telemetry pipeline:** Claude Code → OTLP HTTP (`/otel/v1/*`) → Nginx → OTel Collector (dev-ai.apollotech.co) → Loki → Grafana (`/grafana`)

**Auth isolation (wrapper only):** `CLAUDE_CONFIG_DIR` is set to `~/.apollo-claude/`, so Claude's auth tokens (`.credentials.json`) are stored separately from `~/.claude/`. This prevents Apollo's subscription from leaking to plain `claude` usage.

**HTTP helpers (wrapper only):** `_fetch_stdout` and `_fetch_to_file` abstract curl vs wget. All wrapper network calls (auto-update, version check) go through these helpers, preferring curl with wget as fallback.

The collector stack in `collector/` (docker-compose with OTel Collector, Loki, Grafana) is the self-hosted backend — it's separate from the installers and deployed independently.

## Key Files

- `setup-apollotech-otel-for-claude.sh` — primary installer (bash). Checks deps, validates credentials, downloads `apollotech-otel-headers.sh`, saves `~/.claude/apollotech-config`, and merges OTEL settings into `~/.claude/settings.json`. Supports a `--verbose` flag for detailed output.
- `apollotech-otel-headers.sh` — auth + repo-detection helper. Installed to `~/.claude/apollotech-otel-headers.sh` by the setup script. Reads `~/.claude/apollotech-config`, detects git repo from CWD, and outputs `{"Authorization": "Basic <base64>", "X-Apollo-Repository": "org/repo"}` JSON. Called by Claude Code's `otelHeadersHelper` setting at startup + every ~29 min.
- `install_collector.sh` — automated collector stack installer (bash, Ubuntu-only). Handles OS validation, packages, Docker, UFW, repo clone, nginx, TLS, and first developer provisioning in one script.
- `collector/` — self-hosted OTel backend (docker-compose stack, nginx reverse proxy). Defense-in-depth filtering strips prompt/completion content at the collector level.
- `collector/htpasswd` — per-developer credentials for basic auth (managed with `htpasswd -nbB`).
- `collector/nginx-site.conf` — nginx site config template for TLS termination and path-based reverse proxy (`/otel/v1/*` → collector, `/grafana/*` → Grafana).
- `README.md` — developer-facing: install, usage, troubleshooting.
- `SETUP.md` — OTel collector deployment guide.
- `bin/apollo-claude` — optional CLI wrapper (bash). Installed to `~/.local/bin/apollo-claude` by `install-apollo-claude-wrapper.sh`. Provides auth isolation and auto-update; most developers don't need this.
- `install-apollo-claude-wrapper.sh` — one-liner installer for the optional CLI wrapper. Uses POSIX `sh` for portability.
- `VERSION` — single integer, monotonically increasing. Must match `APOLLO_CLAUDE_VERSION` in `bin/apollo-claude`.

## Development

There is no build step, test suite, or linter. The project is shell scripts.

**Syntax-check all scripts:**
```sh
bash -n setup-apollotech-otel-for-claude.sh
bash -n apollotech-otel-headers.sh
bash -n bin/apollo-claude
sh -n install-apollo-claude-wrapper.sh
bash -n install_collector.sh
```

**Run the collector stack locally:**
```sh
cd collector && docker compose up -d
```

**Debug telemetry locally (prints logs to terminal instead of sending):**
```sh
OTEL_LOGS_EXPORTER=console claude --version
```

## Commit Rules

- Never add `Co-Authored-By` or any Claude/AI attribution to commit messages.
- Before committing, ensure CLAUDE.md and README.md are consistent with the current state of the code (key files, config variables, architecture, conventions, etc.).

## Conventions

- `setup-apollotech-otel-for-claude.sh`, `apollotech-otel-headers.sh`, and `bin/apollo-claude` use `set -euo pipefail` and bash. `install-apollo-claude-wrapper.sh` uses `set -eu` and POSIX sh.
- Config is read via line-by-line `IFS='=' read`, not `source`, to avoid executing arbitrary code. Only `APOLLO_*` keys are processed; other keys are silently ignored. Leading/trailing whitespace on keys and values is trimmed.
- `settings.json` is always updated via a `jq` merge into a temp file followed by atomic `mv` — never written directly, and always backed up first.
- Downloaded helpers (e.g. `apollotech-otel-headers.sh`) are validated before install: non-empty, bash shebang present, `bash -n` syntax check passes.
- All wrapper network calls go through `_fetch_stdout`/`_fetch_to_file` (curl preferred, wget fallback) with connect timeouts. The wrapper must never hang or block normal `claude` usage.
- Auto-update downloads are quadruple-validated (non-empty, shebang present, version bump, `bash -n` syntax check) before atomic `mv` replacement.
- When bumping the wrapper, increment both `APOLLO_CLAUDE_VERSION` in `bin/apollo-claude` and the `VERSION` file. They must stay in sync.

## Dependencies

### `setup-apollotech-otel-for-claude.sh` (primary installer)

| Dependency | Required | Used for |
|---|---|---|
| `bash` | yes | Script runs under bash; headers helper also requires bash |
| `claude` | yes | Confirms Claude Code is installed before configuring it |
| `jq` >= 1.6 | yes | Safe JSON merge into `~/.claude/settings.json` |
| `base64` | yes | Basic auth encoding in the headers helper |
| `curl` or `wget` | yes | Downloading `apollotech-otel-headers.sh`; credential validation |
| `grep`, `tr`, `sed`, `basename`, `date`, `chmod`, `cp`, `mkdir`, `mv` | yes | Validation, config handling, atomic writes |
| `git` | no | Repo detection in the headers helper (falls back to directory name) |

### `bin/apollo-claude` (optional CLI wrapper)

| Dependency | Required | Used for |
|---|---|---|
| `bash` | yes | Wrapper runs under bash (not sh) |
| `claude` | yes | The underlying Claude Code CLI |
| `curl` or `wget` | yes | Auto-update downloads |
| `grep`, `sed`, `date`, `stat`, `mktemp`, `head`, `cut`, `base64` | yes | Login check, auto-update, repo detection, basic auth encoding |
| `git` | no | Repo detection (falls back to directory name) |

## Config

### Primary config (`~/.claude/apollotech-config`)

Written by `setup-apollotech-otel-for-claude.sh`. Read by `apollotech-otel-headers.sh` at runtime.

| Variable | Required | Description |
|---|---|---|
| `APOLLO_USER` | yes | Developer email (basic auth username) |
| `APOLLO_OTEL_TOKEN` | yes | Per-developer token (basic auth password) |

### Optional CLI wrapper config (`~/.apollo-claude/config`)

Written by `bin/apollo-claude` on first run.

| Variable | Required | Description |
|---|---|---|
| `APOLLO_USER` | yes | Developer email (basic auth username) |
| `APOLLO_OTEL_TOKEN` | yes | Per-developer token (basic auth password) |
| `APOLLO_AUTO_UPDATE` | no | Set `false` to disable auto-update |
| `APOLLO_UPDATE_INTERVAL` | no | Seconds between update checks (default: 86400) |
| `APOLLO_OTEL_SERVER` | no | OTel collector endpoint (default: `https://dev-ai.apollotech.co/otel`) |
