#!/bin/sh

DEBUG_LOG_FILE="/tmp/debug.log"
DEBUG_LOG_MAX_BYTES=500000
MAX_QUEUE_LINES=200

trim_debug_log() {
    if [ ! -e "$DEBUG_LOG_FILE" ]; then
        return
    fi

    current_size=$(wc -c < "$DEBUG_LOG_FILE" 2>/dev/null)
    case "$current_size" in
        ''|*[!0-9]*)
            return
            ;;
    esac

    if [ "$current_size" -gt "$DEBUG_LOG_MAX_BYTES" ]; then
        tail -c "$DEBUG_LOG_MAX_BYTES" "$DEBUG_LOG_FILE" > "${DEBUG_LOG_FILE}.new" 2>/dev/null
        mv -f "${DEBUG_LOG_FILE}.new" "$DEBUG_LOG_FILE"
    fi
}

log_message="$1"
log_level="${2:-info}"

if [ "${debug_to_screen:-0}" -ne 0 ]; then
    COUNTER_FILE="/tmp/.trmnl_log_counter"

    start_line=5
    max_line=65

    # --- Read the current counter value ---
    current_count=0 # Default if file doesn't exist or is invalid
    if [ -f "$COUNTER_FILE" ]; then
        # Read the file content
        read_value=$(cat "$COUNTER_FILE")

        # Check if it's a valid non-negative integer using POSIX tools (case)
        case "$read_value" in
        # Pattern: matches if the string contains *any* non-digit character
        *[!0-9]*)
            echo "Warning: Invalid content '$read_value' in $COUNTER_FILE. Resetting counter to 0." >&2
            current_count=0
            # Optionally, fix the file content here: echo "0" > "$COUNTER_FILE"
            ;;
        # Pattern: matches if the string is empty
        "")
            # Treat empty file as 0 (already the default)
            current_count=0
            ;;
        # Pattern: matches anything else (must be all digits if it didn't match above)
        *)
            current_count=$read_value
            ;;
        esac
    fi

    next_count=$((current_count + 1))
    value_to_save=$next_count

    if [ "$next_count" -gt $max_line ]; then
        echo "Counter reached $next_count, resetting."
        value_to_save=$start_line
    fi

    # --- Write the value for the NEXT run back to the file ---
    echo "$value_to_save" > "$COUNTER_FILE"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to write counter value to $COUNTER_FILE" >&2
        exit 1
    fi
    fbink -x 1 -y "$value_to_save" -S 2 "$log_message" > /dev/null 2>&1
fi

echo "$log_message" >> "$DEBUG_LOG_FILE" 2>&1
trim_debug_log

case "${trmnl_log_upload_enabled:-0}" in
    1)
        ;;
    *)
        exit 0
        ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

queue_file="${trmnl_log_queue_file:-/tmp/trmnl-log-queue.ndjson}"
battery_json="null"
wifi_json="null"

case "${trmnl_last_battery_capacity:-}" in
    ''|*[!0-9]*)
        ;;
    *)
        battery_json="${trmnl_last_battery_capacity}"
        ;;
esac

wifi_candidate="${trmnl_last_rssi:-}"
case "$wifi_candidate" in
    '')
        ;;
    -*)
        wifi_abs="${wifi_candidate#-}"
        case "$wifi_abs" in
            ''|*[!0-9]*)
                ;;
            *)
                wifi_json="$wifi_candidate"
                ;;
        esac
        ;;
    *[!0-9]*)
        ;;
    *)
        wifi_json="$wifi_candidate"
        ;;
esac

timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)"
if [ -z "$timestamp" ]; then
    timestamp="$(date +"%Y-%m-%dT%H:%M:%SZ")"
fi

fw_version="${trmnl_firmware_version:-unknown}"
battery_voltage="${trmnl_last_battery_voltage:-}"

log_entry=$(jq -c -n \
    --arg level "$log_level" \
    --arg message "$log_message" \
    --arg timestamp "$timestamp" \
    --arg firmware "$fw_version" \
    --arg source "trmnl-kobo" \
    --arg battery_voltage "$battery_voltage" \
    --argjson battery "$battery_json" \
    --argjson wifi "$wifi_json" \
    '{
      level: $level,
      message: $message,
      metadata: {
        timestamp: $timestamp,
        source: $source,
        firmware_version: $firmware,
        battery: $battery,
        battery_voltage: (if $battery_voltage == "" then null else $battery_voltage end),
        wifi: $wifi
      }
    }' 2>/dev/null)

if [ -z "$log_entry" ]; then
    exit 0
fi

echo "$log_entry" >> "$queue_file" 2>/dev/null

line_count=$(wc -l < "$queue_file" 2>/dev/null)
case "$line_count" in
    ''|*[!0-9]*)
        exit 0
        ;;
esac

if [ "$line_count" -gt "$MAX_QUEUE_LINES" ]; then
    tail -n "$MAX_QUEUE_LINES" "$queue_file" > "${queue_file}.new" 2>/dev/null
    mv -f "${queue_file}.new" "$queue_file"
fi
