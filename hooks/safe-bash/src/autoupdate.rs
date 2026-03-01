use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const UPDATE_URL: &str = "https://raw.githubusercontent.com/apollo-com-ph/apollo-claude/main/safe-bash-patterns.json";
const UPDATE_INTERVAL_SECS: u64 = 3600; // 1 hour

/// Path to the timestamp file that tracks the last update check.
pub fn last_update_path(hooks_dir: &Path) -> PathBuf {
    hooks_dir.join("safe-bash-patterns.last_update")
}

/// Path to the patterns file.
pub fn patterns_path(hooks_dir: &Path) -> PathBuf {
    hooks_dir.join("safe-bash-patterns.json")
}

/// Returns true if an update should be triggered (file missing or mtime > interval).
pub fn update_needed(timestamp_path: &Path) -> bool {
    match fs::metadata(timestamp_path) {
        Err(_) => true, // file doesn't exist
        Ok(meta) => {
            let mtime = match meta.modified() {
                Ok(t) => t,
                Err(_) => return true,
            };
            let elapsed = match SystemTime::now().duration_since(mtime) {
                Ok(d) => d,
                Err(_) => return true,
            };
            elapsed > Duration::from_secs(UPDATE_INTERVAL_SECS)
        }
    }
}

/// Touch the timestamp file (create or update mtime).
pub fn touch_timestamp(timestamp_path: &Path) {
    if let Err(e) = fs::write(timestamp_path, format!("{}", now_secs())) {
        eprintln!("safe-bash-hook: warn: could not write timestamp {}: {}", timestamp_path.display(), e);
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Spawn a detached background curl to fetch the latest patterns file.
/// Never blocks — the child process is fully detached.
/// Returns Ok(()) if the spawn succeeded, Err(msg) if curl is unavailable or spawn failed.
pub fn spawn_background_update(hooks_dir: &Path) -> Result<(), String> {
    let target = patterns_path(hooks_dir);
    let tmpfile = format!("{}.tmp", target.display());

    // Build: curl -fsSL <url> -o <tmp> && jq empty <tmp> 2>/dev/null && mv <tmp> <target>
    // The jq validation ensures we never replace the patterns file with corrupted/truncated content.
    // If jq is not installed, validation fails and the existing patterns file is preserved (safe default).
    let script = format!(
        "curl -fsSL {} -o {} && jq empty {} 2>/dev/null && mv {} {}",
        UPDATE_URL,
        shell_quote(&tmpfile),
        shell_quote(&tmpfile),
        shell_quote(&tmpfile),
        shell_quote(target.to_str().unwrap_or("")),
    );

    // Spawn detached via sh -c "..." &
    let result = Command::new("sh")
        .arg("-c")
        .arg(&format!("{} >/dev/null 2>&1 &", script))
        .spawn();

    match result {
        Ok(_) => Ok(()),
        Err(e) => Err(format!("safe-bash-hook: warn: could not spawn update: {}", e)),
    }
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Check if update is needed and, if so, touch the timestamp and spawn the background fetch.
/// This function is intentionally non-blocking and failure-tolerant.
pub fn maybe_update(hooks_dir: &Path) {
    let ts_path = last_update_path(hooks_dir);

    if !update_needed(&ts_path) {
        return;
    }

    touch_timestamp(&ts_path);

    if let Err(warn) = spawn_background_update(hooks_dir) {
        eprintln!("{}", warn);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration as StdDuration;
    use tempfile::TempDir;

    #[test]
    fn update_needed_when_file_missing() {
        let dir = TempDir::new().unwrap();
        let ts = dir.path().join("last_update");
        assert!(update_needed(&ts));
    }

    #[test]
    fn update_not_needed_when_recent() {
        let dir = TempDir::new().unwrap();
        let ts = dir.path().join("last_update");
        fs::write(&ts, "now").unwrap();
        // File was just written — should not need update
        assert!(!update_needed(&ts));
    }

    #[test]
    fn touch_creates_file() {
        let dir = TempDir::new().unwrap();
        let ts = dir.path().join("last_update");
        assert!(!ts.exists());
        touch_timestamp(&ts);
        assert!(ts.exists());
    }

    #[test]
    fn touch_updates_existing_file() {
        let dir = TempDir::new().unwrap();
        let ts = dir.path().join("last_update");
        fs::write(&ts, "old").unwrap();
        // Brief sleep so mtime differs
        thread::sleep(StdDuration::from_millis(10));
        touch_timestamp(&ts);
        let contents = fs::read_to_string(&ts).unwrap();
        // The new content should be a numeric timestamp
        assert!(contents.parse::<u64>().is_ok());
    }

    #[test]
    fn spawn_does_not_block() {
        // This test just verifies spawn_background_update returns quickly
        // without hanging. We don't assert the network result.
        let dir = TempDir::new().unwrap();
        let start = std::time::Instant::now();
        let _ = spawn_background_update(dir.path());
        assert!(start.elapsed() < StdDuration::from_secs(1));
    }

    #[test]
    fn maybe_update_does_not_panic_on_bad_path() {
        // Non-writable path — should warn but not panic
        maybe_update(Path::new("/nonexistent/path/hooks"));
    }
}
