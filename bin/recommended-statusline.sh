#!/bin/bash
set -euo pipefail

# Claude Code Statusline Script
# Displays session metrics and API utilization in the format:
#   [Model]XX%/$YY.YY (remaining% reset) parent/project
#
# - Caches OAuth usage/profile data in $HOME/.claude/statusline_oauth_cache.json
# to test: bash -n bin/recommended-statusline.sh && echo '{"model":{"display_name":"Claude-3"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":0.12},"workspace":{"project_dir":"/home/jessie/projects/apollo-claude"}}' | bash bin/recommended-statusline.sh

## Logging setup
# LOG_FILE: Path to log file
# DEBUG_ENABLED: Enable debug logging with --debug
LOG_FILE="$HOME/.claude/statusline.log"
DEBUG_ENABLED=false

## Parse --debug switch
if [ "${1:-}" = "--debug" ]; then
    DEBUG_ENABLED=true
    shift
fi
## Log a message to the log file
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STATUSLINE] $1" >> "$LOG_FILE"
}
## Log a debug message if debug is enabled
debug_log() {
    if [ "$DEBUG_ENABLED" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STATUSLINE] DEBUG $1" >> "$LOG_FILE"
    fi
}

## atomic_write_file(target, content)
# Atomically writes content to a file. Logs errors if write fails.
# Params:
#   $1: Target file path
#   $2: Content to write
atomic_write_file() {
    local target="$1"
    local content="$2"
    local tmp="${target}.tmp.$$"
    debug_log "atomic_write_file: Writing to $target (content length: ${#content})"
    echo "$content" > "$tmp"
    if [ -s "$tmp" ]; then
        if ! mv -f "$tmp" "$target" 2>/dev/null; then
            log "ERROR ❌ Failed to write file: $target"
            rm -f "$tmp"
            return 1
        else
            debug_log "atomic_write_file: Successfully wrote to $target"
        fi
    else
        log "ERROR ❌ Failed to generate file: $target"
        rm -f "$tmp"
        return 1
    fi
    return 0
}


## Usage/profile cache file (shared for all sessions)
USAGE_CACHE_FILE="$HOME/.claude/statusline_usage_cache.json"

## Read session data from stdin (expects JSON)
INPUT=$(cat)

debug_log "raw stdin: $INPUT"

if ! echo "$INPUT" | jq -e . > /dev/null 2>&1; then
    echo "[Unknown   ]00%/\$0.0 (-- -----) "
    exit 0
fi



###############################################################################
# Background OAuth Data Caching (async)
# Fetches usage/profile data from Anthropic API every 5 minutes and caches it.
###############################################################################

# Run OAuth fetch in background - does not block statusline output
(

    # Only fetch if more than 5 minutes since last fetch
    LAST_FETCH=0
    if [ -f "$USAGE_CACHE_FILE" ]; then
        LAST_FETCH=$(jq -r '.fetched_at // 0' "$USAGE_CACHE_FILE" 2>/dev/null || echo "0")
    fi

    CURRENT_TIME=$(date +%s)
    TIME_SINCE_FETCH=$((CURRENT_TIME - LAST_FETCH))

    # Only fetch if > 5 minutes since last fetch
    if [ "$TIME_SINCE_FETCH" -lt 300 ]; then
        debug_log "OAuth background fetch: skipping, only ${TIME_SINCE_FETCH}s since last fetch"
        exit 0
    fi

    debug_log "OAuth background fetch: starting (last_fetch=${TIME_SINCE_FETCH}s ago)"

    # Check if OAuth token is expired
    CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        log "ERROR ❌ OAuth background fetch: no credentials file, skipping"
        exit 0
    fi

    EXPIRES_AT=$(jq -r '.claudeAiOauth.expiresAt // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$EXPIRES_AT" ]; then
        log "ERROR ❌ OAuth background fetch: no expiresAt in credentials, skipping"
        exit 0
    fi

    if echo "$EXPIRES_AT" | grep -qE '^[0-9]+$'; then
        EXPIRES_EPOCH=$((EXPIRES_AT / 1000))
    else
        EXPIRES_EPOCH=$(date -d "$EXPIRES_AT" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${EXPIRES_AT%.*}" +%s 2>/dev/null || echo 0)
    fi
    if [ "$EXPIRES_EPOCH" -eq 0 ] || [ "$CURRENT_TIME" -ge "$EXPIRES_EPOCH" ]; then
        log "ERROR ❌ OAuth background fetch: token expired, skipping"
        exit 0
    fi

    # Token is valid, fetch OAuth usage/profile data
    ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$ACCESS_TOKEN" ]; then
        log "ERROR ❌ OAuth background fetch: no access token, skipping"
        exit 0
    fi

    # Fetch usage data (2s timeout)
    debug_log "USAGE API payload: URL=https://api.anthropic.com/api/oauth/usage Headers=Authorization: Bearer <redacted>, Content-Type: application/json, anthropic-beta: oauth-2025-04-20, Accept: application/json"
    USAGE_RAW=$(curl -s --max-time 2 -w "\n%{http_code}" \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" 2>/dev/null)
    debug_log "USAGE API raw result: $USAGE_RAW"
    USAGE_HTTP_CODE=$(echo "$USAGE_RAW" | tail -1)
    USAGE_RESPONSE=$(echo "$USAGE_RAW" | sed '$d')
    if [ "$USAGE_HTTP_CODE" != "200" ] || [ -z "$USAGE_RESPONSE" ]; then
        log "ERROR ❌ USAGE API bad response: HTTP $USAGE_HTTP_CODE, response empty? $([ -z "$USAGE_RESPONSE" ] && echo yes || echo no)"
    fi

    SEVEN_DAY_UTIL="null"
    SEVEN_DAY_RESETS="null"
    FIVE_HOUR_UTIL="null"
    FIVE_HOUR_RESETS="null"
    SEVEN_DAY_SONNET_UTIL="null"
    SEVEN_DAY_SONNET_RESETS="null"

    if [ "$USAGE_HTTP_CODE" = "200" ] && [ -n "$USAGE_RESPONSE" ]; then
        { read -r SEVEN_DAY_UTIL; read -r SEVEN_DAY_RESETS; read -r FIVE_HOUR_UTIL; read -r FIVE_HOUR_RESETS; read -r SEVEN_DAY_SONNET_UTIL; read -r SEVEN_DAY_SONNET_RESETS; } < <(
            echo "$USAGE_RESPONSE" | jq -r '
                (.seven_day.utilization // "null"),
                (.seven_day.resets_at // "null"),
                (.five_hour.utilization // "null"),
                (.five_hour.resets_at // "null"),
                (.seven_day_sonnet.utilization // "null"),
                (.seven_day_sonnet.resets_at // "null")
            '
        )
    fi

    # Log fetch results
    if [ "$USAGE_HTTP_CODE" = "200" ]; then
        debug_log "OAuth background fetch: success (7d=${SEVEN_DAY_UTIL}%, 5h=${FIVE_HOUR_UTIL}%)"
    else
        log "WARN  ⚠️  OAuth background fetch: usage HTTP $USAGE_HTTP_CODE"
    fi

    # Write cache atomically
    atomic_write_file "$USAGE_CACHE_FILE" "$(jq -n \
        --argjson fetched_at "$CURRENT_TIME" \
        --argjson seven_day_util "$SEVEN_DAY_UTIL" \
        --arg seven_day_resets "$SEVEN_DAY_RESETS" \
        --argjson five_hour_util "$FIVE_HOUR_UTIL" \
        --arg five_hour_resets "$FIVE_HOUR_RESETS" \
        --argjson seven_day_sonnet_util "$SEVEN_DAY_SONNET_UTIL" \
        --arg seven_day_sonnet_resets "$SEVEN_DAY_SONNET_RESETS" \
        '{
            fetched_at: $fetched_at,
            seven_day_utilization: $seven_day_util,
            seven_day_resets_at: (if $seven_day_resets == "null" then null else $seven_day_resets end),
            five_hour_utilization: $five_hour_util,
            five_hour_resets_at: (if $five_hour_resets == "null" then null else $five_hour_resets end),
            seven_day_sonnet_utilization: $seven_day_sonnet_util,
            seven_day_sonnet_resets_at: (if $seven_day_sonnet_resets == "null" then null else $seven_day_sonnet_resets end)
        }'
    )"
) &

## Extract session metrics from input JSON
# MODEL: Model name
# USED_PCT: Context window usage percentage
# COST_USD: Session/project cost in USD
# PROJECT_DIR: Project directory
{ read -r MODEL; read -r USED_PCT; read -r COST_USD; read -r PROJECT_DIR; } < <(
    echo "$INPUT" | jq -r '
        (.model.display_name // .model.id // "Unknown"),
        (.context_window.used_percentage // 0),
        (.cost.total_cost_usd // 0),
        (.workspace.project_dir // "")
    '
)
debug_log "Extracted metrics: MODEL=$MODEL USED_PCT=$USED_PCT COST_USD=$COST_USD PROJECT_DIR=$PROJECT_DIR"

## format_model(model)
# Formats model name to 10 characters, right-padded.
# Params: $1: Model name
format_model() {
    local model="$1"
    printf "%-10.10s" "$model"
}

## format_percentage(pct)
# Formats percentage as 2 digits plus "%".
# Params: $1: Percentage value
format_percentage() {
    local pct="$1"
    local rounded=$(awk "BEGIN {printf \"%.0f\", $pct}")
    printf "%02d%%" "$rounded"
}

## format_cost(cost)
# Formats cost as $0.0-$999.
# Params: $1: Cost value
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
        if [ "$tenths" -ge 10 ]; then
            printf "\$1.0"
        else
            printf "\$0.%s" "$tenths"
        fi
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

## format_project_dir(path)
# Formats project directory as last two path components.
# Params: $1: Full project path
format_project_dir() {
    local path="$1"

    # Return empty if missing
    if [ -z "$path" ]; then
        echo ""
        return
    fi

    # Extract last two path components
    local parent=$(basename "$(dirname "$path")")
    local leaf=$(basename "$path")
    if [ "$parent" = "/" ] || [ "$parent" = "." ]; then
        path="$leaf"
    else
        path="${parent}/${leaf}"
    fi

    echo "$path"
}

## format_reset_time(resets_at)
# Formats reset time from ISO to "XhXXm" or "XdXXh". Returns placeholder if invalid.
# Params: $1: ISO timestamp
format_reset_time() {
    local resets_at="$1"

    if [ -z "$resets_at" ] || [ "$resets_at" = "null" ]; then
        echo "-----"
        return
    fi

    # Parse ISO timestamp to epoch seconds
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

## format_utilization()
# Reads OAuth cache and formats utilization display.
# Always shows 5h limits; shows 7d warning if exceeding sustainable rate.
format_utilization() {

    # No OAuth data available
    if [ ! -f "$USAGE_CACHE_FILE" ]; then
        echo "(-- -----)"
        return
    fi

    local five_hour_util seven_day_util five_hour_resets seven_day_resets
    local _cache_data
    _cache_data=$(jq -r '
        (.five_hour_utilization // "null"),
        (.seven_day_utilization // "null"),
        (.five_hour_resets_at // "null"),
        (.seven_day_resets_at // "null")
    ' "$USAGE_CACHE_FILE" 2>/dev/null) || _cache_data=$'null\nnull\nnull\nnull'
    { read -r five_hour_util; read -r seven_day_util; read -r five_hour_resets; read -r seven_day_resets; } <<< "$_cache_data"

    local have_5h=false have_7d=false
    if [ "$five_hour_util" != "null" ] && [ -n "$five_hour_util" ]; then
        have_5h=true
    fi
    if [ "$seven_day_util" != "null" ] && [ -n "$seven_day_util" ]; then
        have_7d=true
    fi

    # Neither utilization available
    if [ "$have_5h" = "false" ] && [ "$have_7d" = "false" ]; then
        echo "(-- -----)"
        return
    fi

    # 5h utilization is required; if missing, show placeholder
    if [ "$have_5h" = "false" ]; then
        echo "(-- -----)"
        return
    fi

    # Calculate remaining percentage for 5h (100 - utilization)
    local five_hour_remaining
    five_hour_remaining=$(awk "BEGIN {r = 100 - $five_hour_util; printf \"%.0f\", (r < 0 ? 0 : r)}")

    # Always format 5h as primary display
    local five_hour_fmt reset_fmt
    reset_fmt=$(format_reset_time "$five_hour_resets")
    five_hour_fmt=$(printf "(%2d%% %5s)" "$five_hour_remaining" "$reset_fmt")

    # Show 7d warning if utilization exceeds sustainable threshold
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

        # Convert to days (fractional)
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
            seven_day_remaining=$(awk "BEGIN {r = 100 - $seven_day_util; printf \"%.0f\", (r < 0 ? 0 : r)}")
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
UTIL_FMT=$(format_utilization)
PROJECT_FMT=$(format_project_dir "$PROJECT_DIR")
debug_log "Formatted metrics: MODEL_FMT=$MODEL_FMT PCT_FMT=$PCT_FMT COST_FMT=$COST_FMT UTIL_FMT=$UTIL_FMT PROJECT_FMT=$PROJECT_FMT"

## Output statusline: [Model]%/$usd (remaining% reset) parent/project
STATUSLINE_OUTPUT="[${MODEL_FMT}]${PCT_FMT}/${COST_FMT} ${UTIL_FMT} ${PROJECT_FMT}"

# Output to stdout (displayed in CLI mode)
echo "$STATUSLINE_OUTPUT"

exit 0
