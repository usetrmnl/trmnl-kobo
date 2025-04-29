#!/bin/sh
if [ $debug_to_screen -ne 0 ]; then
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
    fbink -x 1 -y $value_to_save -S 2 "$1" > /dev/null 2>&1
fi

echo "$1" >>/tmp/crash.log 2>&1
