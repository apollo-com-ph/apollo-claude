use regex::Regex;
use serde::Deserialize;
use std::fs;
use std::path::Path;

/// A single pattern entry from the config file.
#[derive(Deserialize, Debug)]
pub struct ConfigPattern {
    pub pattern: String,
    pub reason: String,
}

/// The structure of the optional ~/.claude/hooks/safe-bash-patterns.json file.
#[derive(Deserialize, Debug, Default)]
pub struct PatternsConfig {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub deny: Vec<ConfigPattern>,
    #[serde(default)]
    pub allow: Vec<ConfigPattern>,
}

/// A compiled config deny/allow entry.
pub struct CompiledPattern {
    pub re: Regex,
    pub reason: String,
}

/// Compiled result from loading the config file.
#[derive(Default)]
pub struct CompiledConfig {
    pub deny: Vec<CompiledPattern>,
    pub allow: Vec<CompiledPattern>,
}

/// Load and compile patterns from the given path.
/// Returns an empty config if the file doesn't exist or has errors (non-fatal).
pub fn load_config(path: &Path) -> CompiledConfig {
    if !path.exists() {
        return CompiledConfig::default();
    }

    let contents = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("safe-bash-hook: warn: could not read {}: {}", path.display(), e);
            return CompiledConfig::default();
        }
    };

    let config: PatternsConfig = match serde_json::from_str(&contents) {
        Ok(c) => c,
        Err(e) => {
            eprintln!(
                "safe-bash-hook: warn: malformed JSON in {}: {} — using hardcoded patterns only",
                path.display(),
                e
            );
            return CompiledConfig::default();
        }
    };

    let mut compiled = CompiledConfig::default();

    for entry in config.deny {
        match Regex::new(&entry.pattern) {
            Ok(re) => compiled.deny.push(CompiledPattern { re, reason: entry.reason }),
            Err(e) => eprintln!(
                "safe-bash-hook: warn: invalid deny regex {:?}: {}",
                entry.pattern, e
            ),
        }
    }

    for entry in config.allow {
        match Regex::new(&entry.pattern) {
            Ok(re) => compiled.allow.push(CompiledPattern { re, reason: entry.reason }),
            Err(e) => eprintln!(
                "safe-bash-hook: warn: invalid allow regex {:?}: {}",
                entry.pattern, e
            ),
        }
    }

    compiled
}

/// Check a command against the compiled config patterns.
/// Returns Ok(()) if allowed, Err(reason) if denied.
/// allow overrides deny, but neither overrides the hardcoded patterns (handled by caller).
pub fn check_config(cmd: &str, config: &CompiledConfig) -> Result<(), String> {
    // If an allow pattern matches the full command, this config layer passes unconditionally.
    for p in &config.allow {
        if p.re.is_match(cmd) {
            return Ok(());
        }
    }

    // Check config deny patterns against the full command.
    for p in &config.deny {
        if p.re.is_match(cmd) {
            return Err(p.reason.clone());
        }
    }

    // Also check each split segment (catches compound commands like "echo ok && forbidden")
    let segments = crate::patterns::split_command(cmd);
    for segment in &segments {
        // Check allow first for this segment
        let mut segment_allowed = false;
        for p in &config.allow {
            if p.re.is_match(segment) {
                segment_allowed = true;
                break;
            }
        }
        if segment_allowed {
            continue;
        }
        for p in &config.deny {
            if p.re.is_match(segment) {
                return Err(p.reason.clone());
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn write_config(json: &str) -> NamedTempFile {
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(json.as_bytes()).unwrap();
        f
    }

    #[test]
    fn missing_file_returns_empty() {
        let config = load_config(Path::new("/nonexistent/path/safe-bash-patterns.json"));
        assert!(config.deny.is_empty());
        assert!(config.allow.is_empty());
    }

    #[test]
    fn malformed_json_returns_empty() {
        let f = write_config("this is not json {{{");
        let config = load_config(f.path());
        assert!(config.deny.is_empty());
        assert!(config.allow.is_empty());
    }

    #[test]
    fn valid_deny_pattern_loaded() {
        let json = r#"{"version":1,"deny":[{"pattern":"\\bfoo\\b","reason":"test deny"}],"allow":[]}"#;
        let f = write_config(json);
        let config = load_config(f.path());
        assert_eq!(config.deny.len(), 1);
        assert!(config.allow.is_empty());
    }

    #[test]
    fn valid_allow_pattern_loaded() {
        let json = r#"{"version":1,"deny":[],"allow":[{"pattern":"^git log\\b","reason":"safe read-only"}]}"#;
        let f = write_config(json);
        let config = load_config(f.path());
        assert!(config.deny.is_empty());
        assert_eq!(config.allow.len(), 1);
    }

    #[test]
    fn empty_arrays_ok() {
        let json = r#"{"version":1,"deny":[],"allow":[]}"#;
        let f = write_config(json);
        let config = load_config(f.path());
        assert!(config.deny.is_empty());
        assert!(config.allow.is_empty());
    }

    #[test]
    fn config_deny_blocks_command() {
        let json = r#"{"deny":[{"pattern":"\\bforbidden\\b","reason":"forbidden command"}],"allow":[]}"#;
        let f = write_config(json);
        let config = load_config(f.path());
        assert!(check_config("run forbidden now", &config).is_err());
        assert!(check_config("run allowed now", &config).is_ok());
    }

    #[test]
    fn config_allow_overrides_config_deny() {
        let json = r#"{
            "deny": [{"pattern":"\\bfoo\\b","reason":"deny foo"}],
            "allow": [{"pattern":"^allow foo$","reason":"allow this specific foo"}]
        }"#;
        let f = write_config(json);
        let config = load_config(f.path());
        // The allow pattern matches first for "allow foo"
        assert!(check_config("allow foo", &config).is_ok());
        // But "run foo" is blocked by deny
        assert!(check_config("run foo", &config).is_err());
    }

    #[test]
    fn invalid_regex_in_deny_skipped() {
        let json = r#"{"deny":[{"pattern":"[invalid","reason":"bad pattern"},{"pattern":"\\bsafe\\b","reason":"good"}],"allow":[]}"#;
        let f = write_config(json);
        let config = load_config(f.path());
        // The valid pattern should still be loaded
        assert_eq!(config.deny.len(), 1);
    }

    #[test]
    fn config_deny_catches_compound_command() {
        let json = r#"{"deny":[{"pattern":"^forbidden\\b","reason":"deny forbidden at start"}],"allow":[]}"#;
        let f = write_config(json);
        let config = load_config(f.path());
        // "echo ok && forbidden thing" — full command does NOT start with "forbidden"
        // but after splitting, the segment "forbidden thing" does
        assert!(check_config("echo ok && forbidden thing", &config).is_err());
    }

    #[test]
    fn config_allow_works_per_segment() {
        let json = r#"{
            "deny":[{"pattern":"\\bgit\\s+clean\\b","reason":"deny git clean"}],
            "allow":[{"pattern":"^git log\\b","reason":"safe read-only"}]
        }"#;
        let f = write_config(json);
        let config = load_config(f.path());
        // "git clean" should be blocked
        assert!(check_config("git clean -fd", &config).is_err());
        // "git log" should be allowed even with compound
        assert!(check_config("git log --oneline", &config).is_ok());
    }
}
