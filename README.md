# apollo-claude

OpenTelemetry telemetry for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), giving ApolloTech engineering visibility into Claude Code usage across the team — by developer, repo, and model. **No prompt or response content is ever collected.**

## Quick install

```sh
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/setup-apollotech-otel-for-claude.sh -o /tmp/setup-apollotech-otel-for-claude.sh \
  && bash /tmp/setup-apollotech-otel-for-claude.sh \
  && rm /tmp/setup-apollotech-otel-for-claude.sh
```

Or with wget:

```sh
wget -qO /tmp/setup-apollotech-otel-for-claude.sh https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/setup-apollotech-otel-for-claude.sh \
  && bash /tmp/setup-apollotech-otel-for-claude.sh \
  && rm /tmp/setup-apollotech-otel-for-claude.sh
```

The installer will:
- Check that `claude` and all required dependencies are installed (`jq` ≥ 1.6, `base64`, `curl`/`wget`, and coreutils)
- Prompt for your credentials and validate them against the collector
- Download `apollotech-otel-headers.sh` to `~/.claude/` (the auth helper called by Claude Code)
- Save credentials to `~/.claude/apollotech-config`
- Merge OTEL settings into `~/.claude/settings.json`, backing up any existing file first

After running, telemetry is active for all Claude Code usage — VS Code extension, JetBrains plugin, and the bare `claude` CLI — with no wrapper or extra command needed. Safe to re-run.

Optional flag: `--verbose` for detailed output.

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
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "https://dev-ai.apollotech.co/otel",
  "OTEL_LOG_TOOL_DETAILS": "1"
}) | .otelHeadersHelper = ($ENV.HOME + "/.claude/apollotech-otel-headers.sh")' \
  ~/.claude/settings.json > ~/.claude/settings.json.tmp \
  && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

### 5. Restart Claude Code

Open a new terminal or restart the VS Code/JetBrains extension. Data should appear in Grafana within a few minutes of starting a session.

## Day-to-day usage

Just use `claude` normally — no wrapper or extra command needed. The OTEL settings are written into `~/.claude/settings.json` and apply to every Claude Code session automatically.

## What data is collected

The following usage events are sent to `dev-ai.apollotech.co` as OTLP logs, tagged with your `APOLLO_USER` and the detected repository:

| Event | What it tells us |
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
OTEL_LOGS_EXPORTER=console claude --version
```

This prints log output to stdout instead of sending it over the network.

## Troubleshooting

**Data not appearing in Grafana**
- Confirm your credentials are correct — test them directly:
  ```sh
  curl -u 'you@company.com:at_xxxxxxxxxxxx' -X POST https://dev-ai.apollotech.co/otel/v1/logs
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

## Optional: Safe-bash hook (defense-in-depth for Bash commands)

`install-safe-bash-hook.sh` installs `safe-bash-hook`, a compiled Rust binary that runs as a Claude Code `PreToolUse` hook. It inspects every Bash command before execution and blocks dangerous patterns that can slip through the deny list.

### Why three layers?

Claude Code permissions use prefix matching, which means compound commands like `git status && rm -rf /` are not blocked by a `Bash(rm -rf *)` deny entry — only the first token is checked. The hook closes this gap:

| Layer | Mechanism | What it catches |
|---|---|---|
| 1. Allow list | `Bash(*)` | Fast pass-through for all Bash commands (low friction) |
| 2. Deny list | `Bash(rm -rf *)`, `Bash(sudo *)`, etc. | Prefix-matches destructive commands and privilege escalation |
| 3. PreToolUse hook | `safe-bash-hook` binary | Compound commands, credential reads, exfiltration vectors, privilege escalation, persistence, container escape |

**Always blocked (hardcoded in the binary — cannot be overridden):**

- **Destructive file ops** — `rm -rf`, `rm -r`, `mkfs`, `dd`, `shred`
- **Destructive git** — force push, `reset --hard`, `checkout --`
- **Privilege escalation** — `sudo`, `su`, `pkexec`, `doas`, SUID/SGID bit setting
- **Core credential reads** — SSH keys, AWS/GCP/Azure credentials, `.env` files, `/etc/shadow`, Claude credentials
- **Exfiltration** — pipe to curl/shell, `curl --data @file`, `curl -T`
- **Shell injection** — `eval`, `bash -c` with destructive payloads, pipe to shell interpreters
- **Persistence** — `crontab`, `at`/`batch`, `systemctl enable/start`
- **Container escape** — `docker run --privileged`, host root mounts, Docker socket mounts
- **System** — fork bombs, `shutdown`, `reboot`, `kill -9 -1`

**Blocked by default, overridable via `allow` rules in `safe-bash-patterns.json`:**

- **Destructive git ops** — `git clean`, `git restore`, `git branch -D`, `gh api DELETE/PUT/POST`, `rmdir`
- **Network transfer tools** — `netcat`, `scp`, `sftp`, `ftp`, `socat`, `telnet`
- **Additional credential reads** — GPG keys, GitHub CLI tokens, `.git-credentials`, `.netrc`

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install-safe-bash-hook.sh | bash
```

The installer:
- Detects your OS + architecture (Linux amd64/arm64, macOS Intel/Apple Silicon)
- Downloads the pre-compiled binary from GitHub Releases
- Installs to `~/.claude/hooks/safe-bash-hook`
- Downloads the initial `safe-bash-patterns.json` (extended patterns, auto-updated hourly)
- Merges the `PreToolUse` hook config and deny list into `~/.claude/settings.json`

Restart Claude Code after installing.

### How it works

On each Bash tool call, Claude Code pipes a JSON envelope to `safe-bash-hook` on stdin:
```json
{"tool_name": "Bash", "tool_input": {"command": "git status && rm -rf /"}}
```

The hook checks the full command string and each compound segment independently. If a dangerous pattern matches, it exits 2 with a reason on stderr (fed back to Claude). Otherwise exits 0 (allow).

### Custom patterns

The hook loads additional patterns from `~/.claude/hooks/safe-bash-patterns.json` (fetched hourly from this repo). You can also edit the file directly to add your own:

```json
{
  "version": 2,
  "deny": [
    {"pattern": "\\bdeploy\\.sh\\b", "reason": "Run deploy.sh manually — don't let Claude deploy"}
  ],
  "allow": [
    {"pattern": "^git log\\b", "reason": "Override: always allow read-only git log"}
  ]
}
```

`allow` patterns override `deny` patterns in the config file, but **cannot override the hardcoded patterns** built into the binary (those are always enforced).

## Optional: CLI wrapper

`install-apollo-claude-wrapper.sh` installs `apollo-claude`, a thin bash wrapper that also injects telemetry but with auth isolation — it stores Claude credentials in `~/.apollo-claude/` separately from `~/.claude/`, and includes an auto-update mechanism. Most developers don't need this; use it only if you need a separate Claude auth session (e.g. a team subscription billed separately from personal usage).

```sh
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/install-apollo-claude-wrapper.sh | sh
```

## Self-hosted collector

`collector/` contains the OTel backend stack (OTel Collector + Loki + Grafana). To deploy on a fresh Ubuntu 22.04+ server, run `bash install_collector.sh` — it automates the full setup (packages, Docker, firewall, nginx, TLS, first developer). See [SETUP.md](./SETUP.md) for manual deployment instructions.

## Project structure

```
apollo-claude/
├── setup-apollotech-otel-for-claude.sh  # Primary installer
├── apollotech-otel-headers.sh           # Auth + repo-detection helper (downloaded to ~/.claude/)
├── safe-bash-patterns.json              # Remote patterns for safe-bash-hook (fetched hourly)
├── recommended-settings.json           # Example ~/.claude/settings.json (permissions + hook)
├── install-safe-bash-hook.sh           # Installer for the safe-bash-hook binary
├── install-statusline.sh               # Installer for the Claude Code statusline
├── install-apollo-claude-wrapper.sh    # Installer for the optional CLI wrapper
├── install_collector.sh                # Automated collector stack installer
├── hooks/
│   └── safe-bash/                      # Rust source for safe-bash-hook binary
│       ├── Cargo.toml
│       ├── build.sh                    # Cross-compilation script
│       ├── test.sh                     # Shell integration test runner
│       └── src/
│           ├── main.rs
│           ├── patterns.rs             # Hardcoded pattern definitions + matching
│           ├── config.rs               # Optional config file loading
│           └── autoupdate.rs           # Background hourly pattern update
├── collector/
│   ├── docker-compose.yml              # OTel Collector + Loki + Grafana
│   ├── htpasswd                        # Per-developer credentials (basic auth)
│   ├── nginx-site.conf                 # Nginx reverse proxy template
│   ├── otel-collector-config.yaml
│   └── loki-config.yaml
├── bin/
│   ├── apollo-claude                   # Optional CLI wrapper
│   ├── recommended-statusline.sh       # Claude Code statusline script
│   └── release                         # Release automation script
├── CLAUDE.md
├── VERSION
└── SETUP.md
```
