# apollo-claude

A thin wrapper around [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that injects OpenTelemetry telemetry, giving ApolloTech engineering visibility into Claude Code usage across the team — by developer, repo, and model. **No prompt or response content is ever collected.**

## Quick install

```sh
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install.sh | sh
```

Or with wget:

```sh
wget -qO- https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install.sh | sh
```

The installer will:
- Check that `claude` is installed (and tell you how to get it if not)
- Download the wrapper to `~/.local/bin/apollo-claude`
- Validate the download (shebang check + `bash -n` syntax check)
- Add `~/.local/bin` to your PATH (in `~/.zshrc` or `~/.bashrc`)

On first run, `apollo-claude` will prompt for your credentials and write `~/.apollo-claude/config`.

Safe to re-run — existing PATH entries are not duplicated.

## Manual install

### 1. Get your credentials

Ask your team lead for your personal token. You'll need:

- `APOLLO_USER` — your official email (e.g. `jess@company.com`)
- `APOLLO_OTEL_TOKEN` — your personal token (looks like `at_xxxxxxxxxxxx`)

### 2. Create the config file

```bash
mkdir -p ~/.apollo-claude
cat > ~/.apollo-claude/config <<'EOF'
APOLLO_USER=you@company.com
APOLLO_OTEL_TOKEN=at_xxxxxxxxxxxx
APOLLO_OTEL_SERVER=https://dev-ai.apollotech.co/otel
EOF
```

Replace `you@company.com`, `at_xxxxxxxxxxxx`, and optionally the server URL with the values for your team.

The config file is only readable by you (`chmod 600` is recommended):

```bash
chmod 600 ~/.apollo-claude/config
```

### 3. Add `apollo-claude` to your PATH

**Option A — symlink into an existing PATH directory:**

```bash
ln -sf /path/to/apollo-claude/bin/apollo-claude ~/.local/bin/apollo-claude
```

**Option B — add the `bin/` directory to PATH:**

Add to your `~/.bashrc` or `~/.zshrc`:

```bash
export PATH="/path/to/apollo-claude/bin:$PATH"
```

Then reload your shell:

```bash
source ~/.bashrc   # or ~/.zshrc
```

### 4. Verify the setup

```bash
apollo-claude --wrapper-version
```

You should see the wrapper version (e.g. `apollo-claude version 1`). You can also run `apollo-claude --version` to see the underlying Claude version. If you see a "configuration required" message, check that `~/.apollo-claude/config` exists and contains both variables.

## Day-to-day usage

**Use `apollo-claude` for all Apollo repo work.** It behaves identically to `claude` — all flags and arguments pass through unchanged.

```bash
# Instead of:
claude

# Use:
apollo-claude
```

The wrapper adds two flags of its own:
- `--wrapper-version` — print the wrapper version and exit
- `--self-update` — force an immediate update check and exit

`apollo-claude` uses its own auth session, stored in `~/.apollo-claude/` (separate from `~/.claude/`). The first time you run the wrapper, you'll need to log in through it — this is a one-time step, independent of any personal `claude` login you may have.

You can continue to use bare `claude` for personal projects — it uses its own auth in `~/.claude/` and no telemetry is injected.

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

The wrapper automatically detects the project context:

- **Inside a git repo with a remote**: uses `org/repo` from the `origin` remote URL
- **Inside a git repo without a remote**: uses the basename of the git root
- **Not in a git repo**: uses the basename of the current directory

## Local debugging

To verify what OTel attributes are being sent without hitting the remote collector, you can temporarily override the exporter:

```bash
OTEL_METRICS_EXPORTER=console apollo-claude --version
```

This prints metric output to stdout instead of sending it over the network.

## Troubleshooting

**"configuration required" on every run**
- Check that `~/.apollo-claude/config` exists
- Check that both `APOLLO_USER` and `APOLLO_OTEL_TOKEN` are set (leading/trailing whitespace around `=` is fine)

**`apollo-claude: command not found`**
- Re-check your PATH setup (step 3 above)
- Run `which apollo-claude` to confirm it's found

**"not logged in" on every run**
- `apollo-claude` has its own auth session separate from plain `claude`
- Run `apollo-claude` and complete the login prompt — this only needs to happen once

**Metrics not appearing in Grafana**
- Confirm your credentials are correct — `APOLLO_USER` is the username, `APOLLO_OTEL_TOKEN` is the password (ask your team lead if unsure)
- Test your credentials directly: `curl -u 'user:token' -X POST https://dev-ai.apollotech.co/otel/v1/metrics` — a `400` means auth is OK (empty body), `401` means bad credentials
- Check connectivity: `curl -I https://dev-ai.apollotech.co` (or your custom `APOLLO_OTEL_SERVER` URL)
- If your team uses a custom collector, ensure `APOLLO_OTEL_SERVER` is set correctly in `~/.apollo-claude/config`
- Collector logs are available from the team if needed

## Self-hosted collector

`collector/` contains the OTel backend stack (OTel Collector + Prometheus + Grafana). To deploy on a fresh Ubuntu 22.04+ server, run `bash install_collector.sh` — it automates the full setup (packages, Docker, firewall, nginx, TLS, first developer). See [SETUP.md](./SETUP.md) for manual deployment instructions.

## Project structure

```
apollo-claude/
├── bin/
│   └── apollo-claude          # The wrapper script
├── collector/
│   ├── docker-compose.yml     # OTel + Prometheus + Grafana (localhost-only ports)
│   ├── htpasswd               # Per-developer credentials (basic auth)
│   ├── nginx-site.conf        # Nginx reverse proxy template
│   ├── otel-collector-config.yaml
│   └── prometheus.yml
├── install.sh                 # One-liner installer (wrapper)
├── install_collector.sh       # Automated collector stack installer
└── SETUP.md                   # Ubuntu server deployment guide
```
