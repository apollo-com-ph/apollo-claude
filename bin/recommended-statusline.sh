#!/bin/bash
set -euo pipefail

# Claude Code Statusline Script
# Displays session metrics and API utilization in the format:
#   [Model]XX%/$YY.YY (remaining% reset) parent/project
#
# - Caches OAuth usage/profile data in $HOME/.claude/statusline_usage_cache.json
# to test: bash statusline_test.sh

## Constants
FETCH_INTERVAL_SECS=480    # 8 minutes between OAuth API fetches
SUSTAINABLE_RATE=14.28     # 100/7 — daily sustainable usage rate (%)

## Logging setup
# LOG_FILE: Path to log file
# DEBUG_ENABLED: Enable debug logging with --debug
LOG_FILE="$HOME/.claude/statusline.log"
LOG_MAX_LINES=2000        # rotate when log exceeds this many lines
LOG_KEEP_LINES=1000       # keep this many lines after rotation
DEBUG_ENABLED=false

if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_LINES" ]; then
    tail -"$LOG_KEEP_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
fi

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
    local tmp="${target}.tmp.${BASHPID}"
    printf '%s\n' "$content" > "$tmp"
    if [ -s "$tmp" ]; then
        if ! mv -f "$tmp" "$target" 2>/dev/null; then
            log "ERROR ❌ Failed to write file: $target"
            rm -f "$tmp"
            return 1
        fi
    else
        log "ERROR ❌ Failed to generate file: $target"
        rm -f "$tmp"
        return 1
    fi
    return 0
}

## Usage/profile cache file (shared for all sessions)
# Can be overridden via environment variable (useful for testing)
USAGE_CACHE_FILE="${USAGE_CACHE_FILE:-$HOME/.claude/statusline_usage_cache.json}"

## Read session data from stdin (expects JSON)
INPUT=$(cat)

debug_log "raw stdin: $INPUT"

if ! jq -e . <<< "$INPUT" > /dev/null 2>&1; then
    debug_log "Invalid JSON input, using fallback output"
    echo "[Unknown   ]00%/\$0.0 (-- -----)"
    exit 0
fi

###############################################################################
# refresh_oauth_cache()
# Fetches usage data from Anthropic API every FETCH_INTERVAL_SECS and caches it.
# Uses flock to prevent concurrent fetches across parallel statusline invocations.
###############################################################################
refresh_oauth_cache() {
    # Prevent concurrent fetches with a lockfile
    local LOCK_FILE="$HOME/.claude/statusline_oauth.lock"
    exec 9>"$LOCK_FILE"
    flock -n 9 || return 0

    # Only fetch if more than FETCH_INTERVAL_SECS since last fetch
    local LAST_FETCH=0
    if [ -f "$USAGE_CACHE_FILE" ]; then
        LAST_FETCH=$(jq -r '.fetched_at // 0' "$USAGE_CACHE_FILE" 2>/dev/null || echo "0")
    fi

    local CURRENT_TIME
    CURRENT_TIME=$(date +%s)
    local TIME_SINCE_FETCH=$((CURRENT_TIME - LAST_FETCH))

    if [ "$TIME_SINCE_FETCH" -lt "$FETCH_INTERVAL_SECS" ]; then
        debug_log "OAuth background fetch: skipping, only ${TIME_SINCE_FETCH}s since last fetch"
        return 0
    fi

    debug_log "OAuth background fetch: starting (last_fetch=${TIME_SINCE_FETCH}s ago)"

    # Check if OAuth token is expired
    local CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        debug_log "OAuth background fetch: no credentials file, skipping"
        return 0
    fi

    local EXPIRES_AT
    EXPIRES_AT=$(jq -r '.claudeAiOauth.expiresAt // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$EXPIRES_AT" ]; then
        debug_log "OAuth background fetch: no expiresAt in credentials, skipping"
        return 0
    fi

    local EXPIRES_EPOCH
    if echo "$EXPIRES_AT" | grep -qE '^[0-9]+$'; then
        EXPIRES_EPOCH=$((EXPIRES_AT / 1000))
    else
        EXPIRES_EPOCH=$(date -d "$EXPIRES_AT" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${EXPIRES_AT%.*}" +%s 2>/dev/null || echo 0)
    fi
    if [ "$EXPIRES_EPOCH" -eq 0 ] || [ "$CURRENT_TIME" -ge "$EXPIRES_EPOCH" ]; then
        log "WARN  ⚠️  OAuth background fetch: token expired, skipping"
        return 0
    fi

    # Token is valid, fetch OAuth usage data
    local ACCESS_TOKEN
    ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$ACCESS_TOKEN" ]; then
        debug_log "OAuth background fetch: no access token, skipping"
        return 0
    fi

    # Fetch usage data (2s timeout, capture headers for Retry-After)
    local USAGE_RAW USAGE_HTTP_CODE USAGE_RESPONSE RETRY_AFTER
    USAGE_RAW=$(curl -si --connect-timeout 2 --max-time 2 -w "\n%{http_code}" \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" 2>/dev/null) || USAGE_RAW=""
    USAGE_HTTP_CODE=$(echo "$USAGE_RAW" | tail -1)
    debug_log "USAGE API: HTTP $USAGE_HTTP_CODE"
    debug_log "USAGE API raw result: $USAGE_RAW"
    # Strip headers: find blank line separating headers from body
    USAGE_RESPONSE=$(echo "$USAGE_RAW" | awk 'found{print} /^\r?$/{found=1}' | sed '$d')
    USAGE_RESPONSE="${USAGE_RESPONSE:-"{}"}"
    RETRY_AFTER=$(echo "$USAGE_RAW" | grep -i '^retry-after:' | head -1 | tr -d '\r' | awk '{print $2}' || true)

    local SEVEN_DAY_UTIL="null"
    local SEVEN_DAY_RESETS="null"
    local FIVE_HOUR_UTIL="null"
    local FIVE_HOUR_RESETS="null"

    if [ "$USAGE_HTTP_CODE" = "200" ] && [ -n "$USAGE_RESPONSE" ]; then
        { read -r SEVEN_DAY_UTIL; read -r SEVEN_DAY_RESETS; read -r FIVE_HOUR_UTIL; read -r FIVE_HOUR_RESETS; } < <(
            echo "$USAGE_RESPONSE" | jq -r '
                (.seven_day.utilization // "null"),
                (.seven_day.resets_at // "null"),
                (.five_hour.utilization // "null"),
                (.five_hour.resets_at // "null")
            '
        )
    fi

    # Write cache atomically (only on success — preserve existing data on API errors)
    if [ "$USAGE_HTTP_CODE" = "200" ]; then
        atomic_write_file "$USAGE_CACHE_FILE" "$(jq -n \
            --argjson fetched_at "$CURRENT_TIME" \
            --argjson seven_day_util "$SEVEN_DAY_UTIL" \
            --arg seven_day_resets "$SEVEN_DAY_RESETS" \
            --argjson five_hour_util "$FIVE_HOUR_UTIL" \
            --arg five_hour_resets "$FIVE_HOUR_RESETS" \
            '{
                fetched_at: $fetched_at,
                seven_day_utilization: $seven_day_util,
                seven_day_resets_at: (if $seven_day_resets == "null" then null else $seven_day_resets end),
                five_hour_utilization: $five_hour_util,
                five_hour_resets_at: (if $five_hour_resets == "null" then null else $five_hour_resets end)
            }'
        )"
        debug_log "OAuth background fetch: success (7d=${SEVEN_DAY_UTIL}%, 5h=${FIVE_HOUR_UTIL}%)"
    else
        # On API error: preserve existing utilization data, but push fetched_at forward
        # so we don't retry until the rate limit window expires (Retry-After header).
        local NEXT_FETCH_AT="$CURRENT_TIME"
        if [ -n "$RETRY_AFTER" ] && echo "$RETRY_AFTER" | grep -qE '^[0-9]+$' && [ "$RETRY_AFTER" -gt 0 ]; then
            # Schedule next fetch for exactly when the rate limit window clears
            NEXT_FETCH_AT=$((CURRENT_TIME + RETRY_AFTER - FETCH_INTERVAL_SECS))
            log "WARN  ⚠️  OAuth background fetch: usage HTTP $USAGE_HTTP_CODE — retry-after ${RETRY_AFTER}s, next fetch in $((NEXT_FETCH_AT - CURRENT_TIME + FETCH_INTERVAL_SECS))s"
        else
            log "WARN  ⚠️  OAuth background fetch: usage HTTP $USAGE_HTTP_CODE"
        fi
        if [ -f "$USAGE_CACHE_FILE" ]; then
            local _existing
            _existing=$(jq --argjson now "$NEXT_FETCH_AT" '.fetched_at = $now' "$USAGE_CACHE_FILE" 2>/dev/null) \
                && atomic_write_file "$USAGE_CACHE_FILE" "$_existing"
        fi
    fi
}

# Run OAuth fetch in background — does not block statusline output
refresh_oauth_cache 2>>"$LOG_FILE" &

## Extract session metrics from input JSON
# MODEL: Model name
# USED_PCT: Context window usage percentage
# COST_USD: Session/project cost in USD
# PROJECT_DIR: Project directory
{ read -r MODEL; read -r USED_PCT; read -r COST_USD; read -r PROJECT_DIR; } < <(
    jq -r '
        (.model.display_name // .model.id // "Unknown"),
        (.context_window.used_percentage // 0),
        (.cost.total_cost_usd // 0),
        (.workspace.project_dir // "")
    ' <<< "$INPUT"
)

## format_model(model)
# Formats model name to 10 characters, right-padded.
# Params: $1: Model name
format_model() {
    printf "%-10.10s" "$1"
}

## format_percentage(pct)
# Formats percentage as 2 digits plus "%".
# Params: $1: Percentage value (may be fractional)
format_percentage() {
    awk -v pct="$1" 'BEGIN {printf "%02d%%", int(pct + 0.5)}'
}

## format_cost(cost)
# Formats cost as $0.0–$999 or $1k+ (always 4 chars).
# Params: $1: Cost value
format_cost() {
    awk -v cost="$1" 'BEGIN {
        c = cost + 0
        if (c < 0.05)  { printf "$0.0";       exit }
        if (c < 1.0)   { t = int(c * 10 + 0.5); if (t >= 10) printf "$1.0"; else printf "$0.%d", t; exit }
        if (c < 9.95)   { printf "$%.1f", c;   exit }
        if (c < 99.5)   { printf "$%2.0f ", c;  exit }
        if (c < 999.5)  { printf "$%3.0f", c;   exit }
        printf "$1k+"
    }'
}

## format_project_dir(path)
# Formats project directory as last two path components.
# Params: $1: Full project path
format_project_dir() {
    local path="$1"
    if [ -z "$path" ]; then echo ""; return; fi
    local leaf="${path##*/}"
    local parent_path="${path%/*}"
    local parent="${parent_path##*/}"
    if [ -z "$parent" ] || [ "$parent" = "$path" ]; then
        echo "$leaf"
    else
        echo "${parent}/${leaf}"
    fi
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
    local reset_epoch
    reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${resets_at%.*}" +%s 2>/dev/null || echo 0)
    if [ "$reset_epoch" -eq 0 ]; then
        echo "-----"
        return
    fi
    local now_epoch diff_seconds
    now_epoch=$(date +%s)
    diff_seconds=$((reset_epoch - now_epoch))
    if [ "$diff_seconds" -le 0 ]; then
        echo "0h00m"
        return
    fi
    local total_hours remaining_minutes
    total_hours=$((diff_seconds / 3600))
    remaining_minutes=$(( (diff_seconds % 3600) / 60 ))
    if [ "$total_hours" -ge 24 ]; then
        printf "%dd%02dh" "$((total_hours / 24))" "$((total_hours % 24))"
    else
        printf "%dh%02dm" "$total_hours" "$remaining_minutes"
    fi
}

## format_utilization()
# Reads OAuth cache and formats utilization display.
# Always shows 5h limits; shows 7d warning if exceeding sustainable rate.
# Output (7 lines):
#   1: util_string (display)
#   2: five_hour_reset_in (display)
#   3: seven_day_reset_in (display)
#   4-7: raw cache values (five_hour_util, five_hour_resets, seven_day_util, seven_day_resets)
#        passed back via stdout since this runs in a process substitution subshell
format_utilization() {
    # -s checks both existence and non-empty; jq returns exit 0 on empty files
    # but produces no output, which would cause read to fail under set -e
    if [ ! -s "$USAGE_CACHE_FILE" ]; then
        printf '%s\n%s\n%s\nnull\nnull\nnull\nnull\n' "(-- -----)" "-----" "-----"
        return
    fi

    local five_hour_util seven_day_util five_hour_resets seven_day_resets
    { read -r five_hour_util; read -r seven_day_util; read -r five_hour_resets; read -r seven_day_resets; } < <(
        jq -r '
            (.five_hour_utilization // "null"),
            (.seven_day_utilization // "null"),
            (.five_hour_resets_at // "null"),
            (.seven_day_resets_at // "null")
        ' "$USAGE_CACHE_FILE" 2>/dev/null || printf 'null\nnull\nnull\nnull\n'
    )
    debug_log "Cache: 5h=${five_hour_util}% 7d=${seven_day_util}%"

    # 5h utilization is required; if missing, show placeholder
    if [ "$five_hour_util" = "null" ] || [ -z "$five_hour_util" ]; then
        printf '%s\n%s\n%s\nnull\nnull\n%s\n%s\n' \
            "(-- -----)" "-----" "-----" "$seven_day_util" "$seven_day_resets"
        return
    fi

    local reset_fmt seven_reset_fmt
    reset_fmt=$(format_reset_time "$five_hour_resets")
    seven_reset_fmt=$(format_reset_time "$seven_day_resets")

    # Compute 5h remaining and optional 7d warning in a single awk call
    local now_epoch seven_day_resets_epoch=0
    now_epoch=$(date +%s)
    if [ "$seven_day_util" != "null" ] && [ -n "$seven_day_util" ] && [ "$seven_day_resets" != "null" ]; then
        seven_day_resets_epoch=$(date -d "$seven_day_resets" +%s 2>/dev/null || echo 0)
    fi

    local awk_result
    awk_result=$(awk \
        -v five_util="$five_hour_util" \
        -v seven_util="$seven_day_util" \
        -v now="$now_epoch" \
        -v seven_reset_epoch="$seven_day_resets_epoch" \
        -v sustainable_rate="$SUSTAINABLE_RATE" \
        'BEGIN {
            r5 = 100 - (five_util + 0)
            if (r5 < 0) r5 = 0
            printf "%d\n", int(r5 + 0.5)

            if (seven_util != "null" && seven_util != "") {
                seconds_remaining = seven_reset_epoch - now
                if (seconds_remaining < 0) seconds_remaining = 0
                days_remaining = seconds_remaining / 86400
                if (days_remaining > 7) days_remaining = 7
                days_elapsed = 7 - days_remaining
                sustainable_threshold = days_elapsed * sustainable_rate
                if (days_elapsed >= 1 && (seven_util + 0) > sustainable_threshold) {
                    r7 = 100 - (seven_util + 0)
                    if (r7 < 0) r7 = 0
                    printf "warn:%d\n", int(r7 + 0.5)
                }
            }
        }')

    local five_hour_remaining seven_day_warning="" warn_line=""
    while IFS= read -r _line; do
        case "$_line" in
            warn:*) warn_line="$_line" ;;
            *)      five_hour_remaining="$_line" ;;
        esac
    done <<< "$awk_result"
    if [ -n "$warn_line" ]; then
        local seven_day_remaining="${warn_line#warn:}"
        debug_log "7d warning: util=${seven_day_util}% > threshold, ${seven_day_remaining}% remaining"
        seven_day_warning=$(printf " !%d%% %s!" "$seven_day_remaining" "$seven_reset_fmt")
    fi

    local five_hour_fmt
    five_hour_fmt=$(printf "(%2d%% %5s)" "$five_hour_remaining" "$reset_fmt")
    # Output 7 lines: 3 display + 4 raw cache values for the JSON output block
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "${five_hour_fmt}${seven_day_warning}" "$reset_fmt" "$seven_reset_fmt" \
        "$five_hour_util" "$five_hour_resets" "$seven_day_util" "$seven_day_resets"
}

# Apply formatting
MODEL_FMT=$(format_model "$MODEL")
PCT_FMT=$(format_percentage "$USED_PCT")
COST_FMT=$(format_cost "$COST_USD")
{ read -r UTIL_FMT; read -r FIVE_HOUR_RESET_IN; read -r SEVEN_DAY_RESET_IN
  read -r _G_FIVE_HOUR_UTIL; read -r _G_FIVE_HOUR_RESETS
  read -r _G_SEVEN_DAY_UTIL; read -r _G_SEVEN_DAY_RESETS; } < <(format_utilization)
PROJECT_FMT=$(format_project_dir "$PROJECT_DIR")
debug_log "Formatted metrics: MODEL_FMT=$MODEL_FMT PCT_FMT=$PCT_FMT COST_FMT=$COST_FMT UTIL_FMT=$UTIL_FMT PROJECT_FMT=$PROJECT_FMT"

## Output statusline: [Model]%/$usd (remaining% reset) parent/project
STATUSLINE_OUTPUT="[${MODEL_FMT}]${PCT_FMT}/${COST_FMT} ${UTIL_FMT} ${PROJECT_FMT}"
echo "$STATUSLINE_OUTPUT"
debug_log "Output: $STATUSLINE_OUTPUT"

# Also save structured JSON to /tmp/statusline.json for external consumption.
# Reuses cache values already extracted by format_utilization() via globals.
{
    _sl_json=$(jq -n \
        --arg     model                "$MODEL" \
        --argjson context_pct          "$USED_PCT" \
        --argjson cost_usd             "$COST_USD" \
        --arg     project              "$PROJECT_FMT" \
        --argjson five_hour_util       "$([ "$_G_FIVE_HOUR_UTIL"  = "null" ] && echo "null" || echo "$_G_FIVE_HOUR_UTIL")" \
        --arg     five_hour_reset      "$([ "$_G_FIVE_HOUR_RESETS" = "null" ] && echo "" || echo "$_G_FIVE_HOUR_RESETS")" \
        --arg     five_hour_reset_in   "$FIVE_HOUR_RESET_IN" \
        --argjson seven_day_util       "$([ "$_G_SEVEN_DAY_UTIL"  = "null" ] && echo "null" || echo "$_G_SEVEN_DAY_UTIL")" \
        --arg     seven_day_reset      "$([ "$_G_SEVEN_DAY_RESETS" = "null" ] && echo "" || echo "$_G_SEVEN_DAY_RESETS")" \
        --arg     seven_day_reset_in   "$SEVEN_DAY_RESET_IN" \
        '{
            model:              $model,
            context_pct:        $context_pct,
            cost_usd:           $cost_usd,
            five_hour_util:     $five_hour_util,
            five_hour_reset:    $five_hour_reset,
            five_hour_reset_in: $five_hour_reset_in,
            seven_day_util:     $seven_day_util,
            seven_day_reset:    $seven_day_reset,
            seven_day_reset_in: $seven_day_reset_in,
            project:            $project
        }')

    atomic_write_file "/tmp/statusline.json" "$_sl_json"
}

exit 0
