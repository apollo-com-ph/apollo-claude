#!/bin/bash
set -euo pipefail

# Atomically write content to a file (via temp file)
atomic_write_file() {
    local target="$1"
    local content="$2"
    local tmp="${target}.tmp.$$"
    echo "$content" > "$tmp"
    if [ -s "$tmp" ]; then
        if ! mv -f "$tmp" "$target" 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STATUSLINE] ERROR ❌ Failed to write file: $target" >> "$HOME/.claude/ccmetrics.log"
            rm -f "$tmp"
            return 1
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STATUSLINE] ERROR ❌ Failed to generate file: $target" >> "$HOME/.claude/ccmetrics.log"
        rm -f "$tmp"
        return 1
    fi
    return 0
}

#############################################################################
# Custom Claude Code Statusline - Session Metrics & API Utilization
# Shows: [Model]%/$usd (remaining% reset label) parent/project
#############################################################################

# Cache directory for metrics (shared with SessionEnd hook)
METRICS_CACHE_DIR="$HOME/.claude/metrics_cache"
mkdir -p "$METRICS_CACHE_DIR"

# Read session data from stdin
INPUT=$(cat)

# Logging support
LOG_FILE="$HOME/.claude/ccmetrics.log"
DEBUG_ENABLED=false
CONFIG_FILE="$HOME/.claude/.ccmetrics-config.json"
if [ -f "$CONFIG_FILE" ]; then
    DEBUG_ENABLED=$(jq -r '.debug // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
fi
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STATUSLINE] $1" >> "$LOG_FILE"
}
debug_log() {
    if [ "$DEBUG_ENABLED" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STATUSLINE] DEBUG $1" >> "$LOG_FILE"
    fi
}
debug_log "raw stdin: $INPUT"

# Cache session data for SessionEnd hook to read (high-watermark for used_percentage)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [ -n "$SESSION_ID" ]; then
    CACHE_FILE="${METRICS_CACHE_DIR}/${SESSION_ID}.json"
    INCOMING_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
    debug_log "session=$SESSION_ID incoming_pct=$INCOMING_PCT"

    if [ -f "$CACHE_FILE" ]; then
        OLD_PCT=$(jq -r '.context_window.used_percentage // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
        debug_log "old_pct=$OLD_PCT"

        # Only apply high-watermark when incoming is zero; non-zero values always overwrite
        if [ "$(awk "BEGIN {print ($INCOMING_PCT == 0) ? 1 : 0}")" -eq 1 ]; then
            debug_log "HIGH-WATERMARK: incoming is 0, keeping old=$OLD_PCT"
            atomic_write_file "$CACHE_FILE" "$(echo "$INPUT" | jq --argjson old_pct "$OLD_PCT" '.context_window.used_percentage = $old_pct')"
        else
            debug_log "writing incoming=$INCOMING_PCT (non-zero, overwriting old=$OLD_PCT)"
            atomic_write_file "$CACHE_FILE" "$INPUT"
        fi
    else
        debug_log "no existing cache, writing incoming=$INCOMING_PCT"
        atomic_write_file "$CACHE_FILE" "$INPUT"
    fi
fi

# ============================================================================
# BACKGROUND OAUTH DATA CACHING (runs async, doesn't block statusline output)
# ============================================================================

# Run OAuth fetch in background - does not block statusline output
(
    # Only fetch every 5 minutes
    OAUTH_CACHE_FILE="${METRICS_CACHE_DIR}/_oauth_cache.json"
    LAST_FETCH=0
    if [ -f "$OAUTH_CACHE_FILE" ]; then
        LAST_FETCH=$(jq -r '.fetched_at // 0' "$OAUTH_CACHE_FILE" 2>/dev/null || echo "0")
    fi

    CURRENT_TIME=$(date +%s)
    TIME_SINCE_FETCH=$((CURRENT_TIME - LAST_FETCH))

    # Only fetch if > 5 minutes since last fetch
    if [ "$TIME_SINCE_FETCH" -lt 300 ]; then
        exit 0
    fi

    debug_log "OAuth background fetch: starting (last_fetch=${TIME_SINCE_FETCH}s ago)"

    # Check token expiry
    CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        debug_log "OAuth background fetch: no credentials file, skipping"
        exit 0
    fi

    EXPIRES_AT=$(jq -r '.claudeAiOauth.expiresAt // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$EXPIRES_AT" ]; then
        debug_log "OAuth background fetch: no expiresAt in credentials, skipping"
        exit 0
    fi

    if echo "$EXPIRES_AT" | grep -qE '^[0-9]+$'; then
        EXPIRES_EPOCH=$((EXPIRES_AT / 1000))
    else
        EXPIRES_EPOCH=$(date -d "$EXPIRES_AT" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${EXPIRES_AT%.*}" +%s 2>/dev/null || echo 0)
    fi
    if [ "$EXPIRES_EPOCH" -eq 0 ] || [ "$CURRENT_TIME" -ge "$EXPIRES_EPOCH" ]; then
        debug_log "OAuth background fetch: token expired, skipping"
        exit 0
    fi

    # Token is valid, fetch OAuth data
    ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$ACCESS_TOKEN" ]; then
        debug_log "OAuth background fetch: no access token, skipping"
        exit 0
    fi

    # Fetch usage (2s timeout)
    USAGE_RAW=$(curl -s --max-time 2 -w "\n%{http_code}" \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" 2>/dev/null)
    USAGE_HTTP_CODE=$(echo "$USAGE_RAW" | tail -1)
    USAGE_RESPONSE=$(echo "$USAGE_RAW" | sed '$d')

    SEVEN_DAY_UTIL="null"
    SEVEN_DAY_RESETS="null"
    FIVE_HOUR_UTIL="null"
    FIVE_HOUR_RESETS="null"
    SEVEN_DAY_SONNET_UTIL="null"
    SEVEN_DAY_SONNET_RESETS="null"

    if [ "$USAGE_HTTP_CODE" = "200" ] && [ -n "$USAGE_RESPONSE" ]; then
        SEVEN_DAY_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day.utilization // "null"')
        SEVEN_DAY_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day.resets_at // "null"')
        FIVE_HOUR_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.five_hour.utilization // "null"')
        FIVE_HOUR_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.five_hour.resets_at // "null"')
        SEVEN_DAY_SONNET_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day_sonnet.utilization // "null"')
        SEVEN_DAY_SONNET_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day_sonnet.resets_at // "null"')
    fi

    # Fetch profile (2s timeout)
    PROFILE_RAW=$(curl -s --max-time 2 -w "\n%{http_code}" \
        "https://api.anthropic.com/api/oauth/profile" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" 2>/dev/null)
    PROFILE_HTTP_CODE=$(echo "$PROFILE_RAW" | tail -1)
    PROFILE_RESPONSE=$(echo "$PROFILE_RAW" | sed '$d')

    CLAUDE_ACCOUNT_EMAIL=""
    if [ "$PROFILE_HTTP_CODE" = "200" ] && [ -n "$PROFILE_RESPONSE" ]; then
        CLAUDE_ACCOUNT_EMAIL=$(echo "$PROFILE_RESPONSE" | jq -r '.account.email // ""')
    fi

    # Log fetch results
    if [ "$USAGE_HTTP_CODE" = "200" ] && [ "$PROFILE_HTTP_CODE" = "200" ]; then
        debug_log "OAuth background fetch: success (7d=${SEVEN_DAY_UTIL}%, 5h=${FIVE_HOUR_UTIL}%, email=${CLAUDE_ACCOUNT_EMAIL:-empty})"
    else
        log "WARN  ⚠️  OAuth background fetch: usage HTTP $USAGE_HTTP_CODE, profile HTTP $PROFILE_HTTP_CODE"
    fi

    # Write cache atomically
    atomic_write_file "$OAUTH_CACHE_FILE" "$(jq -n \
        --argjson fetched_at "$CURRENT_TIME" \
        --argjson seven_day_util "$SEVEN_DAY_UTIL" \
        --arg seven_day_resets "$SEVEN_DAY_RESETS" \
        --argjson five_hour_util "$FIVE_HOUR_UTIL" \
        --arg five_hour_resets "$FIVE_HOUR_RESETS" \
        --argjson seven_day_sonnet_util "$SEVEN_DAY_SONNET_UTIL" \
        --arg seven_day_sonnet_resets "$SEVEN_DAY_SONNET_RESETS" \
        --arg claude_account "$CLAUDE_ACCOUNT_EMAIL" \
        '{
            fetched_at: $fetched_at,
            seven_day_utilization: $seven_day_util,
            seven_day_resets_at: (if $seven_day_resets == "null" then null else $seven_day_resets end),
            five_hour_utilization: $five_hour_util,
            five_hour_resets_at: (if $five_hour_resets == "null" then null else $five_hour_resets end),
            seven_day_sonnet_utilization: $seven_day_sonnet_util,
            seven_day_sonnet_resets_at: (if $seven_day_sonnet_resets == "null" then null else $seven_day_sonnet_resets end),
            claude_account_email: (if $claude_account == "" then null else $claude_account end)
        }'
    )"
) &

# Extract data using jq
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // .model.id // "Unknown"')
USED_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
COST_USD=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0')
PROJECT_DIR=$(echo "$INPUT" | jq -r '.workspace.project_dir // ""')

# Apply baseline delta for cost display after /clear
if [ -n "$PROJECT_DIR" ]; then
    _SL_PROJECT_HASH=$(echo -n "$PROJECT_DIR" | md5sum | cut -c1-8)
    _SL_BASELINE_FILE="${METRICS_CACHE_DIR}/_clear_baseline_${_SL_PROJECT_HASH}.json"
    if [ -f "$_SL_BASELINE_FILE" ]; then
        _SL_BASELINE_COST=$(jq -r '.cost_usd // 0' "$_SL_BASELINE_FILE" 2>/dev/null || echo "0")
        COST_USD=$(awk "BEGIN {v = $COST_USD - $_SL_BASELINE_COST; printf \"%.6f\", (v < 0 ? 0 : v)}")
    fi
fi

# Format model name: 10 chars, right padded with spaces
format_model() {
    local model="$1"
    printf "%-10.10s" "$model"
}

# Format percentage: 2 chars + "%", left padded with 0, whole numbers
format_percentage() {
    local pct="$1"
    local rounded=$(awk "BEGIN {printf \"%.0f\", $pct + 0.5}")
    printf "%02d%%" "$rounded"
}

# Format cost: 4 chars, $0.0 to $999, right padded
format_cost() {
    local cost="$1"

    # Handle zero or very small values
    if [ "$(awk "BEGIN {print ($cost < 0.05) ? 1 : 0}")" -eq 1 ]; then
        echo "\$0.0"
        return
    fi

    # $0.1-$0.9: "$0.X" (1 decimal)
    if [ "$(awk "BEGIN {print ($cost < 1.0) ? 1 : 0}")" -eq 1 ]; then
        local tenths=$(awk "BEGIN {printf \"%.0f\", $cost * 10}")
        printf "\$0.%s" "$tenths"
        return
    fi

    # $1.0-$9.9: "$X.X" (1 decimal)
    if [ "$(awk "BEGIN {print ($cost < 10.0) ? 1 : 0}")" -eq 1 ]; then
        printf "\$%.1f" "$cost"
        return
    fi

    # $10-$99: "$XX " (space padded right)
    if [ "$(awk "BEGIN {print ($cost < 100.0) ? 1 : 0}")" -eq 1 ]; then
        printf "\$%2.0f " "$cost"
        return
    fi

    # $100-$999: "$XXX"
    printf "\$%3.0f" "$cost"
}

# Format project directory: last 2 path components
format_project_dir() {
    local path="$1"

    # Default if missing
    if [ -z "$path" ]; then
        echo ""
        return
    fi

    # Extract last 2 path components
    local parent=$(basename "$(dirname "$path")")
    local leaf=$(basename "$path")
    if [ "$parent" = "/" ] || [ "$parent" = "." ]; then
        path="$leaf"
    else
        path="${parent}/${leaf}"
    fi

    echo "$path"
}

# Format reset time: ISO timestamp → "XhXXm" or "XdXXh"
format_reset_time() {
    local resets_at="$1"

    if [ -z "$resets_at" ] || [ "$resets_at" = "null" ]; then
        echo "-----"
        return
    fi

    # Parse ISO timestamp to epoch
    local reset_epoch
    reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${resets_at%.*}" +%s 2>/dev/null || echo 0)
    if [ "$reset_epoch" -eq 0 ]; then
        echo "-----"
        return
    fi

    local now_epoch
    now_epoch=$(date +%s)
    local diff_seconds=$((reset_epoch - now_epoch))

    # If already past, show 0
    if [ "$diff_seconds" -le 0 ]; then
        echo "0h00m"
        return
    fi

    local total_hours=$((diff_seconds / 3600))
    local remaining_minutes=$(( (diff_seconds % 3600) / 60 ))

    # Use "XdXXh" format if >= 24 hours
    if [ "$total_hours" -ge 24 ]; then
        local days=$((total_hours / 24))
        local hours=$((total_hours % 24))
        printf "%dd%02dh" "$days" "$hours"
    else
        printf "%dh%02dm" "$total_hours" "$remaining_minutes"
    fi
}

# Read OAuth cache and format utilization display
# Logic: Always show 5h limits, conditionally show 7d warning if exceeding sustainable rate
format_utilization() {
    local session_id="$1"
    local oauth_cache="${METRICS_CACHE_DIR}/_oauth_cache.json"

    # No OAuth data available
    if [ ! -f "$oauth_cache" ]; then
        echo "(-- -----)"
        return
    fi

    local five_hour_util seven_day_util five_hour_resets seven_day_resets
    five_hour_util=$(jq -r '.five_hour_utilization // "null"' "$oauth_cache" 2>/dev/null)
    seven_day_util=$(jq -r '.seven_day_utilization // "null"' "$oauth_cache" 2>/dev/null)
    five_hour_resets=$(jq -r '.five_hour_resets_at // "null"' "$oauth_cache" 2>/dev/null)
    seven_day_resets=$(jq -r '.seven_day_resets_at // "null"' "$oauth_cache" 2>/dev/null)

    local have_5h=false have_7d=false
    if [ "$five_hour_util" != "null" ] && [ -n "$five_hour_util" ]; then
        have_5h=true
    fi
    if [ "$seven_day_util" != "null" ] && [ -n "$seven_day_util" ]; then
        have_7d=true
    fi

    # Neither available
    if [ "$have_5h" = "false" ] && [ "$have_7d" = "false" ]; then
        echo "(-- -----)"
        return
    fi

    # 5h is required - if missing, show placeholder
    if [ "$have_5h" = "false" ]; then
        echo "(-- -----)"
        return
    fi

    # Calculate remaining percentage for 5h (100 - utilization)
    local five_hour_remaining
    five_hour_remaining=$(awk "BEGIN {printf \"%.0f\", 100 - $five_hour_util}")

    # Always format 5h as primary display (no label needed since it's always 5h)
    local five_hour_fmt reset_fmt
    reset_fmt=$(format_reset_time "$five_hour_resets")
    five_hour_fmt=$(printf "(%2d%% %5s)" "$five_hour_remaining" "$reset_fmt")

    # Check if 7d warning should be shown
    local seven_day_warning=""

    if [ "$have_7d" = "true" ]; then
        # Calculate days remaining until 7d reset
        local now_epoch reset_epoch seconds_remaining days_remaining days_elapsed
        now_epoch=$(date +%s)
        reset_epoch=$(date -d "$seven_day_resets" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${seven_day_resets%.*}" +%s 2>/dev/null || echo "$now_epoch")
        seconds_remaining=$((reset_epoch - now_epoch))

        # Avoid negative values if reset is in the past
        if [ "$seconds_remaining" -lt 0 ]; then
            seconds_remaining=0
        fi

        # Convert to days (with fractional precision)
        days_remaining=$(awk "BEGIN {printf \"%.2f\", $seconds_remaining / 86400}")
        days_elapsed=$(awk "BEGIN {printf \"%.2f\", 7 - $days_remaining}")

        # Sustainable threshold = days_elapsed × 14.28%
        local sustainable_threshold
        sustainable_threshold=$(awk "BEGIN {printf \"%.2f\", $days_elapsed * 14.28}")

        # Show warning if current utilization exceeds sustainable threshold
        local exceeds_threshold
        exceeds_threshold=$(awk "BEGIN {print ($seven_day_util > $sustainable_threshold) ? 1 : 0}")

        if [ "$exceeds_threshold" -eq 1 ]; then
            local seven_day_remaining seven_reset_fmt
            seven_day_remaining=$(awk "BEGIN {printf \"%.0f\", 100 - $seven_day_util}")
            seven_reset_fmt=$(format_reset_time "$seven_day_resets")
            seven_day_warning=$(printf " !%d%% %s!" "$seven_day_remaining" "$seven_reset_fmt")
        fi
    fi

    echo "${five_hour_fmt}${seven_day_warning}"
}

# Apply formatting
MODEL_FMT=$(format_model "$MODEL")
PCT_FMT=$(format_percentage "$USED_PCT")
COST_FMT=$(format_cost "$COST_USD")
UTIL_FMT=$(format_utilization "$SESSION_ID")
PROJECT_FMT=$(format_project_dir "$PROJECT_DIR")

# Output statusline: [Model]%/$usd (remaining% reset label) parent/project
STATUSLINE_OUTPUT="[${MODEL_FMT}]${PCT_FMT}/${COST_FMT} ${UTIL_FMT} ${PROJECT_FMT}"

# Write to file for external consumers (VS Code status bar extension, etc.)
STATUSLINE_FILE="${METRICS_CACHE_DIR}/_statusline.txt"
atomic_write_file "$STATUSLINE_FILE" "$STATUSLINE_OUTPUT"

# Output to stdout (displayed in CLI mode)
echo "$STATUSLINE_OUTPUT"

exit 0
