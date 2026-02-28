mod autoupdate;
mod config;
mod patterns;

use serde::Deserialize;
use serde_json::Value;
use std::io::{self, Read};
use std::path::PathBuf;

/// The top-level JSON structure sent by Claude Code's PreToolUse hook.
#[derive(Deserialize, Debug)]
struct HookInput {
    #[serde(default)]
    tool_name: String,
    #[serde(default)]
    tool_input: Value,
}

fn hooks_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".claude").join("hooks")
}

fn main() {
    // Read all stdin
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        // Can't read stdin — allow (don't block Claude)
        std::process::exit(0);
    }

    // Parse JSON — if malformed, allow (don't block Claude)
    let hook_input: HookInput = match serde_json::from_str(&input) {
        Ok(v) => v,
        Err(_) => std::process::exit(0),
    };

    // Only act on Bash tool calls
    if hook_input.tool_name != "Bash" {
        std::process::exit(0);
    }

    // Extract tool_input.command — if missing, allow
    let command = match hook_input.tool_input.get("command").and_then(|v| v.as_str()) {
        Some(cmd) => cmd.to_string(),
        None => std::process::exit(0),
    };

    let hooks_dir = hooks_dir();

    // Trigger hourly background update of remote patterns (non-blocking)
    autoupdate::maybe_update(&hooks_dir);

    // Load optional config patterns
    let config_path = autoupdate::patterns_path(&hooks_dir);
    let compiled_config = config::load_config(&config_path);

    // Load hardcoded deny patterns
    let hardcoded = patterns::hardcoded_deny_patterns();

    // 1. Check hardcoded patterns first (cannot be overridden)
    if let patterns::CheckResult::Deny(reason) = patterns::check_command(&command, &hardcoded) {
        eprintln!("Blocked: {}", reason);
        std::process::exit(2);
    }

    // 2. Check config allow patterns (override config deny)
    // 3. Check config deny patterns
    if let Err(reason) = config::check_config(&command, &compiled_config) {
        eprintln!("Blocked: {}", reason);
        std::process::exit(2);
    }

    // All checks passed — allow
    std::process::exit(0);
}
