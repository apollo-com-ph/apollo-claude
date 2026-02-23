# apollo-claude

OpenTelemetry telemetry for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), giving ApolloTech engineering visibility into Claude Code usage across the team — by developer, repo, and model. **No prompt or response content is ever collected.**

## Quick install

```sh
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/setup-apollotech-otel-for-claude.sh | bash
```

Or with wget:

```sh
wget -qO- https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/setup-apollotech-otel-for-claude.sh | bash
```

The installer will:
- Check that `claude` and all required dependencies are installed (`jq` ≥ 1.6, `base64`, `curl`/`wget`, and coreutils)
- Prompt for your credentials and validate them against the collector
- Download `apollotech-otel-headers.sh` to `~/.claude/` (the auth helper called by Claude Code)
- Save credentials to `~/.claude/apollotech-config`
- Merge OTEL settings into `~/.claude/settings.json`, backing up any existing file first

After running, telemetry is active for all Claude Code usage — VS Code extension, JetBrains plugin, and the bare `claude` CLI — with no wrapper or extra command needed. Safe to re-run.

Optional flags: `--verbose` for detailed output, `--debug` for full trace.

## Manual install

### 1. Get your credentials

Ask your team lead for your personal token. You'll need:

- `APOLLO_USER` — your official email (e.g. `jess@company.com`)
- `APOLLO_OTEL_TOKEN` — your personal token (looks like `at_xxxxxxxxxxxx`)

### 2. Create the config file

```bash
mkdir -p ~/.claude
cat > ~/.claude/apollotech-config <<'EOF'
APOLLO_USER=you@company.com
APOLLO_OTEL_TOKEN=at_xxxxxxxxxxxx
EOF
chmod 600 ~/.claude/apollotech-config
```

### 3. Download the headers helper

```bash
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/apollotech-otel-headers.sh \
  -o ~/.claude/apollotech-otel-headers.sh
chmod 700 ~/.claude/apollotech-otel-headers.sh
```

### 4. Update settings.json

If `~/.claude/settings.json` doesn't exist yet, create it first:

```bash
echo '{}' > ~/.claude/settings.json
```

Then merge the OTEL configuration:

```bash
jq '.env = ((.env // {}) + {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "https://dev-ai.apollotech.co/otel",
  "OTEL_METRICS_INCLUDE_SESSION_ID": "true",
  "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "true",
  "OTEL_LOG_TOOL_DETAILS": "1"
}) | .otelHeadersHelper = ($ENV.HOME + "/.claude/apollotech-otel-headers.sh")' \
  ~/.claude/settings.json > ~/.claude/settings.json.tmp \
  && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

### 5. Restart Claude Code

Open a new terminal or restart the VS Code/JetBrains extension. Metrics should appear in Grafana within a few minutes of starting a session.

## Day-to-day usage

Just use `claude` normally — no wrapper or extra command needed. The OTEL settings are written into `~/.claude/settings.json` and apply to every Claude Code session automatically.

## What data is collected

The following metrics are sent to `dev-ai.apollotech.co`, tagged with your `APOLLO_USER` and the detected repository:

| Metric | What it tells us |
|--------|-----------------|
| `claude_code.session.count` | How often each dev uses Claude Code |
| `claude_code.cost.usage` | Per-session cost in USD, by model |
| `claude_code.token.usage` | Input/output/cache tokens per model |
| `claude_code.lines_of_code.count` | Lines added/removed |
| `claude_code.active_time.total` | Active usage time in seconds |
| `claude_code.code_edit_tool.decision` | Accept/reject rate for suggestions |
| `claude_code.commit.count` | Commits created with Claude Code |
| `claude_code.pull_request.count` | PRs created with Claude Code |

Event logs (stored server-side) include per-API-request detail: model used, cost, token counts, and tool calls. **Prompt and response content is never logged.**

## Repo detection

Claude Code calls the headers helper at session start and approximately every 29 minutes. Each time, it detects the project context from the current working directory:

- **Inside a git repo with a remote**: uses `org/repo` from the `origin` remote URL
- **Inside a git repo without a remote**: uses the basename of the git root
- **Not in a git repo**: uses the basename of the current directory

This is sent as the `X-Apollo-Repository` header on every OTLP request.

## Local debugging

To verify telemetry is active without hitting the remote collector, override the exporter for a single session:

```bash
OTEL_METRICS_EXPORTER=console claude --version
```

This prints metric output to stdout instead of sending it over the network.

## Troubleshooting

**Metrics not appearing in Grafana**
- Confirm your credentials are correct — test them directly:
  ```sh
  curl -u 'you@company.com:at_xxxxxxxxxxxx' -X POST https://dev-ai.apollotech.co/otel/v1/metrics
  ```
  A `400` response means auth is OK (empty body rejected). A `401` means bad credentials.
- Check connectivity: `curl -I https://dev-ai.apollotech.co`
- Confirm `~/.claude/apollotech-config` exists and contains both `APOLLO_USER` and `APOLLO_OTEL_TOKEN`
- Confirm `~/.claude/settings.json` has `"CLAUDE_CODE_ENABLE_TELEMETRY": "1"` under `.env`
- Restart Claude Code after any config changes — settings.json is only read at startup

**jq not installed**
```sh
# macOS
brew install jq
# Ubuntu/Debian
sudo apt install jq
# Fedora
sudo dnf install jq
```
Then re-run the installer.

**claude not installed**
Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code/getting-started

## Optional: CLI wrapper

`install.sh` installs `apollo-claude`, a thin bash wrapper that also injects telemetry but with auth isolation — it stores Claude credentials in `~/.apollo-claude/` separately from `~/.claude/`, and includes an auto-update mechanism. Most developers don't need this; use it only if you need a separate Claude auth session (e.g. a team subscription billed separately from personal usage).

```sh
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install.sh | sh
```

## Self-hosted collector

`collector/` contains the OTel backend stack (OTel Collector + Loki + Grafana). To deploy on a fresh Ubuntu 22.04+ server, run `bash install_collector.sh` — it automates the full setup (packages, Docker, firewall, nginx, TLS, first developer). See [SETUP.md](./SETUP.md) for manual deployment instructions.

## Project structure

```
apollo-claude/
├── setup-apollotech-otel-for-claude.sh  # Primary installer
├── apollotech-otel-headers.sh           # Auth + repo-detection helper (downloaded to ~/.claude/)
├── collector/
│   ├── docker-compose.yml               # OTel Collector + Loki + Grafana
│   ├── htpasswd                         # Per-developer credentials (basic auth)
│   ├── nginx-site.conf                  # Nginx reverse proxy template
│   ├── otel-collector-config.yaml
│   └── loki-config.yaml
├── bin/
│   └── apollo-claude                    # Optional CLI wrapper
├── install.sh                           # Installer for the optional CLI wrapper
├── install_otel.sh                      # Alternative global OTEL installer
├── install_collector.sh                 # Automated collector stack installer
├── CLAUDE.md
├── VERSION
└── SETUP.md
```
