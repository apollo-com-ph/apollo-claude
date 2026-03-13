# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

apollo-claude configures OpenTelemetry telemetry for Claude Code, giving ApolloTech engineering visibility into usage across the team — by developer, repo, and model. It does **not** capture prompts, responses, or code — only usage events (session count, cost, tokens, active time, etc.).

Primary path: `setup-apollotech-otel-for-claude.sh` writes into `~/.claude/` once, covering all Claude Code usage (VS Code, JetBrains, CLI) without a wrapper. An optional CLI wrapper (`bin/apollo-claude`) exists for teams that need auth isolation.

## Architecture

**Primary pipeline:** `setup-apollotech-otel-for-claude.sh` saves credentials to `~/.claude/apollotech-config`, downloads `apollotech-otel-headers.sh` to `~/.claude/`, and merges OTEL env vars + `otelHeadersHelper` into `~/.claude/settings.json`. At startup and every ~29 min, Claude Code calls the headers helper, which reads the config, detects the git repo from CWD, and outputs `{"Authorization": "Basic <base64>", "X-Apollo-Repository": "org/repo"}`. These headers ride on every OTLP request to the collector.

**Telemetry stack:** Claude Code → OTLP HTTP → Nginx → OTel Collector (dev-ai.apollotech.co) → Loki → Grafana

**Wrapper (`bin/apollo-claude`):** Sets `CLAUDE_CONFIG_DIR=~/.apollo-claude` for auth isolation, runs daily auto-update via `_fetch_stdout`/`_fetch_to_file` (curl preferred, wget fallback), detects repo, sets OTEL vars, then `exec claude "$@"`.

**Collector:** `collector/` is a separate docker-compose stack (OTel Collector + Loki + Grafana) deployed independently.

## Key Files

- `setup-apollotech-otel-for-claude.sh` — primary installer. Checks deps, validates credentials, downloads headers helper, saves config, merges settings.json.
- `apollotech-otel-headers.sh` — auth + repo-detection helper, installed to `~/.claude/`. Reads config, detects git repo, outputs JSON headers. Called by `otelHeadersHelper`.
- `safe-bash-patterns.json` — remote deny/allow patterns for `safe-bash-hook` (version 3, 49 deny + 4 allow). Fetched hourly by the hook.
- `hooks/safe-bash/` — Rust source for `safe-bash-hook` PreToolUse binary. Two tiers: 52 hardcoded patterns (always enforced) + remote config patterns (overridable). Exits 0 (allow) or 2 (block).
- `install-safe-bash-hook.sh` — downloads platform binary from GitHub Releases, installs to `~/.claude/hooks/safe-bash-hook`, merges hook config + deny list into settings.json.
- `install-statusline.sh` — downloads `bin/recommended-statusline.sh` to `~/.claude/hooks/statusline.sh`, merges `statusLine` config into settings.json.
- `bin/recommended-statusline.sh` — statusline script. Reads stdin JSON, fetches OAuth usage from Anthropic API (cached 8 min, flock-protected), outputs `[Model]XX%/$Y.YY (remaining% reset) parent/project`. Also writes `/tmp/statusline.json`.
- `install-apollo-claude-wrapper.sh` — POSIX sh one-liner installer for the optional CLI wrapper.
- `bin/apollo-claude` — optional CLI wrapper with auth isolation and auto-update.
- `install_collector.sh` — Ubuntu-only automated collector stack installer.
- `recommended-settings.json` — example settings.json with permission defaults (not auto-installed).
- `Makefile` — `make test` runs syntax-check → cargo test → `tests/test-*.sh` → `hooks/safe-bash/test.sh`.
- `tests/test-lib.sh` — shared assertion library for shell tests.
- `tests/test-*.sh` — 176 shell tests across 10 files (version_gte, statusline formatters + format_reset_time/utilization, config parsing, URL normalization, settings.json jq merge, otel-headers e2e, remote patterns, download validation, platform detection, wrapper config + _test_token).
- `bin/release` — bumps VERSION + APOLLO_CLAUDE_VERSION, syntax-checks, commits and pushes.
- `VERSION` — monotonically increasing integer; must match `APOLLO_CLAUDE_VERSION` in `bin/apollo-claude`.

## Development

```sh
make test          # full suite: syntax-check → cargo test → test-shell → safe-bash-hook test.sh
make test-shell    # shell tests only (no Rust build needed)
make syntax-check  # bash -n / sh -n on all scripts
```

**Build safe-bash-hook (requires Rust, `cargo` at `~/.cargo/bin/cargo`):**
```sh
cd hooks/safe-bash && cargo build --release  # dev build
cd hooks/safe-bash && cargo test             # unit + integration tests
cd hooks/safe-bash && ./test.sh              # shell tests against compiled binary
cd hooks/safe-bash && ./build.sh             # cross-compile all 4 release targets
```

`cargo` is a build-time dependency only — end users download the pre-compiled binary.

```sh
cd collector && docker compose up -d         # run collector stack locally
OTEL_LOGS_EXPORTER=console claude --version  # debug telemetry (prints to stdout)
```

## Commit Rules

- Never add `Co-Authored-By` or any Claude/AI attribution to commit messages.
- Before committing, ensure CLAUDE.md and README.md are consistent with the current code.

## Conventions

- All bash scripts use `set -euo pipefail`. `install-apollo-claude-wrapper.sh` uses `set -eu` and POSIX sh.
- Config is read via `IFS='=' read` (not `source`). Only `APOLLO_*` keys processed; whitespace trimmed from keys and values.
- `settings.json` is always updated via `jq` into a temp file + atomic `mv`, backed up first.
- Downloaded scripts validated before install: non-empty, bash shebang, `bash -n` passes.
- Wrapper network calls always go through `_fetch_stdout`/`_fetch_to_file` with timeouts.
- When bumping the wrapper: increment `APOLLO_CLAUDE_VERSION` in `bin/apollo-claude` AND `VERSION` file. They must stay in sync.

## Dependencies

All installers require `bash`, `claude`, `jq` ≥ 1.6, and `curl` (or `wget` for setup). Additional per-script deps:
- **setup**: `base64`, `git` (optional, for repo detection), coreutils (`grep`, `sed`, `tr`, `basename`, `date`, `chmod`, `cp`, `mkdir`, `mv`)
- **statusline installer**: `curl`, `awk`, `date`, `basename`, `dirname`, `sed`, `tail`; `flock` (optional, Linux concurrent-fetch guard — skipped gracefully on macOS)
- **safe-bash-hook installer**: `curl`; `file`/`xxd`/`od` optional (binary validation)
- **wrapper**: `curl` or `wget`, `grep`, `sed`, `date`, `stat`, `mktemp`, `head`, `cut`, `base64`, `git` (optional)

## Config

**`~/.claude/apollotech-config`** (written by setup, read by headers helper):

| Variable | Description |
|---|---|
| `APOLLO_USER` | Developer email (basic auth username) |
| `APOLLO_OTEL_TOKEN` | Per-developer token (basic auth password) |

**`~/.apollo-claude/config`** (wrapper only, written on first run):

| Variable | Default | Description |
|---|---|---|
| `APOLLO_USER` | — | Developer email |
| `APOLLO_OTEL_TOKEN` | — | Per-developer token |
| `APOLLO_AUTO_UPDATE` | `true` | Set `false` to disable |
| `APOLLO_UPDATE_INTERVAL` | `86400` | Seconds between update checks |
| `APOLLO_OTEL_SERVER` | `https://dev-ai.apollotech.co/otel` | Collector endpoint |
