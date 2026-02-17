# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

apollo-claude is a thin bash wrapper around `claude` that injects OpenTelemetry environment variables for team-wide usage visibility. It does **not** capture prompts, responses, or code — only aggregate metrics (session count, cost, tokens, active time, etc.). The wrapper is distributed via a `curl | sh` one-liner installer.

## Architecture

```
User runs apollo-claude
  → sets CLAUDE_CONFIG_DIR=~/.apollo-claude (auth isolation from plain claude)
  → loads ~/.apollo-claude/config (APOLLO_USER, APOLLO_OTEL_TOKEN)
  → handles --wrapper-version / --self-update if requested
  → auto-update check (daily, via _fetch_stdout/_fetch_to_file helpers)
  → claude auth login check (skipped if .credentials.json exists)
  → detects git repo context (org/repo from remote URL)
  → sets OTEL_* env vars
  → exec claude "$@"
```

**Auth isolation:** `CLAUDE_CONFIG_DIR` is set to `~/.apollo-claude/`, so Claude's auth tokens (`.credentials.json`) are stored separately from `~/.claude/`. This prevents Apollo's subscription from leaking to plain `claude` usage.

**HTTP helpers:** `_fetch_stdout` and `_fetch_to_file` abstract curl vs wget. All network calls (auto-update, version check) go through these helpers, preferring curl with wget as fallback.

**Telemetry pipeline:** Wrapper → OTLP HTTP → OTel Collector (dev-ai.apollotech.co) → Prometheus → Grafana

The collector stack in `collector/` (docker-compose with OTel Collector, Prometheus, Grafana) is the self-hosted backend — it's separate from the wrapper and deployed independently.

## Key Files

- `bin/apollo-claude` — the wrapper script (bash). This is what gets installed to `~/.local/bin/apollo-claude`.
- `install.sh` — one-liner installer. Uses POSIX `sh` (not bash) for portability. Checks all wrapper dependencies (bash, claude, curl/wget, coreutils, git) before installing. Validates the downloaded wrapper (shebang check + `bash -n` syntax check) before declaring success.
- `VERSION` — single integer, monotonically increasing. Must match `APOLLO_CLAUDE_VERSION` in `bin/apollo-claude`.
- `collector/` — self-hosted OTel backend (docker-compose stack). Defense-in-depth filtering strips prompt/completion content at the collector level.
- `README.md` — developer-facing: install, usage, troubleshooting.
- `SETUP.md` — OTel collector deployment guide.

## Development

There is no build step, test suite, or linter. The project is shell scripts.

**Syntax-check both scripts:**
```sh
bash -n bin/apollo-claude
sh -n install.sh
```

**Run the collector stack locally:**
```sh
cd collector && docker compose up -d
```

**Debug telemetry locally (prints metrics to terminal instead of sending):**
```sh
OTEL_METRICS_EXPORTER=console apollo-claude --version
```

## Commit Rules

- Never add `Co-Authored-By` or any Claude/AI attribution to commit messages.
- Before committing, ensure CLAUDE.md and README.md are consistent with the current state of the code (key files, config variables, architecture, conventions, etc.).

## Conventions

- `bin/apollo-claude` uses `set -euo pipefail` and bash. `install.sh` uses `set -eu` and POSIX sh.
- Config is read via line-by-line `IFS='=' read`, not `source`, to avoid executing arbitrary code. Only `APOLLO_*` keys are exported; other keys are silently ignored. Leading/trailing whitespace on keys and values is trimmed.
- All network calls go through `_fetch_stdout`/`_fetch_to_file` (curl preferred, wget fallback) with connect timeouts. The wrapper must never hang or block normal `claude` usage.
- Auto-update downloads are quadruple-validated (non-empty, shebang present, version bump, `bash -n` syntax check) before atomic `mv` replacement.
- When bumping the wrapper, increment both `APOLLO_CLAUDE_VERSION` in `bin/apollo-claude` and the `VERSION` file. They must stay in sync.

## Dependencies

The installer checks these at install time:

| Dependency | Required | Used for |
|---|---|---|
| `bash` | yes | Wrapper runs under bash (not sh) |
| `claude` | yes | The underlying Claude Code CLI |
| `curl` or `wget` | yes | Auto-update downloads |
| `grep`, `sed`, `date`, `stat`, `mktemp`, `head`, `cut` | yes | Login check, auto-update, repo detection |
| `git` | no | Repo detection (falls back to directory name) |

## Config

User config lives at `~/.apollo-claude/config` with `KEY=VALUE` lines:

| Variable | Required | Description |
|---|---|---|
| `APOLLO_USER` | yes | Developer shortname (basic auth username) |
| `APOLLO_OTEL_TOKEN` | yes | Per-developer token (basic auth password, paired with `APOLLO_USER`) |
| `APOLLO_AUTO_UPDATE` | no | Set `false` to disable auto-update |
| `APOLLO_UPDATE_INTERVAL` | no | Seconds between update checks (default: 86400) |
| `APOLLO_OTEL_SERVER` | no | OTel collector endpoint (default: `https://dev-ai.apollotech.co`) |
