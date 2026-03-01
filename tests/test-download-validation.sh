#!/usr/bin/env bash
# test-download-validation.sh — tests for the download validation pattern used in installers
# Tests: non-empty, bash shebang present, bash -n passes
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/tests/test-lib.sh"

printf '\033[1;34m==>\033[0m Testing download validation checks\n\n'

TMPDIR_DL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DL"' EXIT

# ---------------------------------------------------------------------------
# validate_download FILE
# Replicates the three checks from install-statusline.sh (lines 118-128):
#   1. Non-empty
#   2. Bash shebang present
#   3. bash -n syntax check passes
# Exits 0 if all pass, non-zero otherwise.
# ---------------------------------------------------------------------------
validate_download() {
  local f="$1"
  # Check 1: non-empty
  if [ ! -s "$f" ]; then return 1; fi
  # Check 2: bash shebang
  if ! grep -qE '^#!(\/bin\/bash|\/usr\/bin\/env bash)' "$f"; then return 2; fi
  # Check 3: bash syntax
  if ! bash -n "$f" 2>/dev/null; then return 3; fi
  return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# 1. Valid script with /usr/bin/env bash
f="$TMPDIR_DL/valid1.sh"
printf '#!/usr/bin/env bash\necho hello\n' > "$f"
assert_exit 'valid script (env bash) passes all checks' 0 validate_download "$f"

# 2. Valid script with /bin/bash
f="$TMPDIR_DL/valid2.sh"
printf '#!/bin/bash\necho hello\n' > "$f"
assert_exit 'valid script (/bin/bash) passes all checks' 0 validate_download "$f"

# 3. Empty file → fails non-empty check
f="$TMPDIR_DL/empty.sh"
printf '' > "$f"
assert_exit 'empty file fails' 1 validate_download "$f"

# 4. HTML error page → fails shebang check
f="$TMPDIR_DL/html.sh"
printf '<html><body>404 Not Found</body></html>\n' > "$f"
assert_exit 'HTML error page fails shebang check' 2 validate_download "$f"

# 5. Valid shebang but syntax error → fails bash -n
f="$TMPDIR_DL/syntax-error.sh"
printf '#!/usr/bin/env bash\necho $((\n' > "$f"
assert_exit 'syntax error script fails bash -n' 3 validate_download "$f"

# 6. Wrong interpreter (python) → fails shebang check
f="$TMPDIR_DL/python.sh"
printf '#!/usr/bin/env python3\nprint("hello")\n' > "$f"
assert_exit 'python shebang fails check' 2 validate_download "$f"

# 7. No shebang → fails shebang check
f="$TMPDIR_DL/noshebang.sh"
printf 'plain text no shebang\n' > "$f"
assert_exit 'no shebang fails check' 2 validate_download "$f"

# 8. Minimal valid script (comment only)
f="$TMPDIR_DL/minimal.sh"
printf '#!/usr/bin/env bash\n# valid comment only\n' > "$f"
assert_exit 'minimal valid script passes all checks' 0 validate_download "$f"

test_summary
