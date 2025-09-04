#!/bin/sh

test_string=$( iwconfig | grep -i "Signal level=" )

# --- Percentage to dBm Conversion Function ---
# IMPORTANT: This is an EXAMPLE formula. Adjust it for your device!
# This one assumes 'percentage_val' is a number like 88 (for 88%).
convert_percentage_to_dbm() (
  # Run in a subshell `( ... )` to keep variables effectively local
  percentage_val=$1
  dbm_val=""

  # Validate percentage_val is a number (integer or signed integer)
  # expr will output the number if valid, or error.
  # We check exit status and if the output matches the input (to disallow "123foo").
  num_check_for_func=$(expr "$percentage_val" + 0 2>/dev/null)
  if [ $? -ne 0 ] || [ "$num_check_for_func" != "$percentage_val" ]; then
      # Error message will be printed by the calling logic based on empty return
      # To ensure $(...) captures empty on error, we exit the subshell.
      exit 1
  fi

  # Formula: (Percentage / 2) - 100
  dbm_val=$(echo "scale=2; ($percentage_val / 2) - 100" | busybox bc)

  if [ -z "$dbm_val" ]; then # bc might return empty if input was bad or for other reasons
    # Error message will be printed by the calling logic
    exit 1 # Exits the subshell
  fi
  printf "%.0f" "$dbm_val" # Round to nearest integer. POSIX printf should handle this.
)

# --- Main Logic ---

# 1. Extract the "Signal level=VALUE" part
# Using awk to isolate the part after "Signal level=", then another awk to get value before " Noise level="
# xargs is used to trim leading/trailing whitespace.
raw_signal_info=""
if [ -n "$test_string" ]; then # Process only if test_string is not empty
    raw_signal_info=$(echo "$test_string" | awk -F 'Signal level=' '
        NF > 1 {
            # If "Signal level=" is found, $2 contains the rest of the line.
            # Now, isolate the value before " Noise level=" if it exists.
            # We use a general field separator for the second awk.
            print $2
        }' | awk -F '[[:space:]]+Noise level=' '{print $1}' | xargs) # xargs trims
fi

# Check if extraction was successful
if [ -z "$raw_signal_info" ]; then
  echo "Error: Could not extract signal level information from: '$test_string'" >&2
  exit 1
fi

# 2. Determine format and process
export signal_dbm=""

case "$raw_signal_info" in
  *"/"*)
    # It's a percentage like "88/100"
    numerator=$(echo "$raw_signal_info" | cut -d'/' -f1)
    denominator=$(echo "$raw_signal_info" | cut -d'/' -f2)

    # Validate numerator (must be an integer or signed integer)
    num_check_num=$(expr "$numerator" + 0 2>/dev/null)
    if [ $? -ne 0 ] || [ "$num_check_num" != "$numerator" ]; then
        echo "Error: Numerator '$numerator' is not a valid number in '$raw_signal_info'" >&2
        exit 1
    fi

    # Validate denominator (must be a positive integer)
    case "$denominator" in
        ''|*[!0-9]*) # Empty, or contains non-digits
            echo "Error: Denominator '$denominator' is not a positive integer in '$raw_signal_info'" >&2
            exit 1
            ;;
        0)
            echo "Error: Denominator is zero in '$raw_signal_info'" >&2
            exit 1
            ;;
        *) # Is a sequence of digits, not zero. Should be a positive integer.
           # To be absolutely sure it's only digits and correctly interpreted by expr:
           num_check_den=$(expr "$denominator" + 0 2>/dev/null)
           if [ $? -ne 0 ] || [ "$num_check_den" != "$denominator" ] || [ "$num_check_den" -le 0 ]; then
               echo "Error: Denominator '$denominator' is not a valid positive integer in '$raw_signal_info'" >&2
               exit 1
           fi
            ;;
    esac

    percentage_value_for_formula=$numerator
    #echo "Info: Detected percentage signal: $raw_signal_info. Using $percentage_value_for_formula for conversion."
    signal_dbm=$(convert_percentage_to_dbm "$percentage_value_for_formula")

    if [ -z "$signal_dbm" ]; then # Check if conversion function failed
        echo "Error: Conversion from percentage failed for '$raw_signal_info' (numerator: $percentage_value_for_formula)." >&2
        exit 1
    fi
    ;; # End of "/" case

  *"dBm"*)
    # It's already in dBm, like "-52 dBm" or "-52dBm"
    # Remove " dBm" or "dBm" from the end of the string
    value_no_dbm=$(echo "$raw_signal_info" | sed 's/[[:space:]]*dBm$//')

    # Validate that value_no_dbm is a number (integer or signed integer)
    num_check_dbm=$(expr "$value_no_dbm" + 0 2>/dev/null)
    if [ $? -ne 0 ] || [ "$num_check_dbm" != "$value_no_dbm" ]; then
        echo "Error: Extracted dBm value '$value_no_dbm' (from '$raw_signal_info') is not a valid number." >&2
        exit 1
    fi
    signal_dbm=$value_no_dbm
    ;; # End of "dBm" case

  *)
    # Not percentage, not dBm. Check if it's a plain number (integer or signed integer).
    is_integer=0
    if [ -n "$raw_signal_info" ]; then # Ensure not empty
        # expr "$val" + 0: check exit status AND if output matches input string
        integer_check_val=$(expr "$raw_signal_info" + 0 2>/dev/null)
        if [ $? -eq 0 ] && [ "$integer_check_val" = "$raw_signal_info" ]; then
            is_integer=1
        fi
    fi

    if [ "$is_integer" -eq 1 ]; then
      signal_dbm=$raw_signal_info
    else
      echo "Error: Unrecognized signal level format: '$raw_signal_info'" >&2
      exit 1
    fi
    ;; # End of default case
esac

# Final check (should be redundant if all paths set signal_dbm or exit)
if [ -z "$signal_dbm" ] && [ "$?" -eq 0 ]; then # $? check to avoid false positive if script exited due to error
  echo "Internal Error: signal_dbm not set for '$raw_signal_info'." >&2
  exit 1
fi

# Output the final dBm value
if [ -n "$signal_dbm" ]; then
  echo "$signal_dbm"
  exit 0 # Indicate success
else
  # Optionally print an error to stderr if signal_dbm couldn't be determined
  echo "Error: Could not determine signal_dbm from '$test_string' and '$raw_signal_info'" >&2
  exit 1 # Indicate failure
fi
