#!/bin/sh

# Every trmnlloop.sh run is its own process, so the backoff state lives in /tmp,
# which survives suspend to memory
LAST_REFRESH_FILE=/tmp/trmnl_last_refresh
FAILURE_COUNT_FILE=/tmp/trmnl_failures
FIRST_RETRY_DELAY=60
DEFAULT_REFRESH=900
MAX_SUSPEND_ATTEMPTS=5

# Echo $1 if it is a positive integer, $2 otherwise
SaneSeconds() {
    case "$1" in
        '' | *[!0-9]* | 0) echo "$2" ;;
        *) echo "$1" ;;
    esac
}

# One suspend attempt, for $1 seconds
SuspendOnce() {
    suspend_seconds=$1

    ./scripts/log.sh "Enable suspend state" "DEBUG"
    echo 1 >/sys/power/state-extended >>/tmp/debug.log 2>&1
    if [ $? -eq 0 ]; then
        ./scripts/log.sh "Enabled suspend state ok" "DEBUG"
    else
        ./scripts/log.sh "Enable suspend state failed" "WARN"
    fi

    ./scripts/log.sh "Setting up rtcwake alarm" "DEBUG"

    # Record the start time
    start_time=$(date +%s)
    ./bin/busybox_kobo rtcwake -a -s $suspend_seconds -m mem >>/tmp/debug.log 2>&1
    if [ $? -eq 0 ]; then
        ./scripts/log.sh "rtcwake ok"
    else
        ./scripts/log.sh "rtcwake failed, will try secondary suspend to memory next" "WARN"
    fi

    # Calculate the elapsed time
    elapsed_time_in_rtcwake=$(($(date +%s) - start_time))

    # Check if the elapsed time is greater than 10 seconds
    if [ "$elapsed_time_in_rtcwake" -gt 10 ]; then
        ./scripts/log.sh "rtcwake took more than 10 seconds, skipping suspend to mem in power state" "WARN"
    else
        ./scripts/log.sh  "rtcwake took ${elapsed_time_in_rtcwake}, writing suspend to mem in power state" "DEBUG"
        # rtcwake turns the alarm back off when it resumes, so the suspend below
        # would have no wakeup source at all and only stir on an outside event
        echo 0 >/sys/class/rtc/rtc0/wakealarm 2>>/tmp/debug.log
        echo "+${suspend_seconds}" >/sys/class/rtc/rtc0/wakealarm 2>>/tmp/debug.log
        wakealarm=$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null)
        if [ -n "$wakealarm" ] && [ "$wakealarm" != "0" ]; then
            ./scripts/log.sh "wakealarm armed for ${suspend_seconds}s (at ${wakealarm})" "DEBUG"
        else
            ./scripts/log.sh "could not arm wakealarm, suspend has no timer" "WARN"
        fi
        ./scripts/ledToggle.sh 0  >>/tmp/debug.log 2>&1
        sleep 1s
        sync
        sleep 2s
        echo mem >/sys/power/state
        if [ $? -eq 0 ]; then
            ./scripts/log.sh "Suspend to mem ok" "DEBUG"
        else
            ./scripts/log.sh "Suspend to mem failed" "DEBUG"
        fi

        ./scripts/log.sh "Disable suspend state" "DEBUG"
        echo 0 >/sys/power/state-extended >>/tmp/debug.log 2>&1
        if [ $? -eq 0 ]; then
            ./scripts/log.sh "Disabled suspend state ok" "DEBUG"
        else
            ./scripts/log.sh "Disable suspend state failed" "WARN"
        fi
    fi
}

# Shut the wifi down and stay suspended for $1 seconds. A suspend can come back
# early, from a stray wakeup source rather than our alarm, and simply carrying on
# would spend a whole wifi-and-fetch iteration well before the refresh is due, so
# serve out the remaining time instead. Bounded, so something waking us
# constantly cannot trap us here.
SuspendFor() {
    total_seconds=$1

    # A RestoreWifi still in its wpa wait would otherwise thaw after the suspend
    # and tear down the wifi the next iteration just brought up
    pkill -f restore-wifi-async.sh

    ./scripts/log.sh "disabling wifi" "DEBUG"
    ./scripts/disable-wifi.sh >>/tmp/debug.log 2>&1

    ./scripts/log.sh "Should sleep for ${total_seconds}" "DEBUG"
    sleep 5s

    deadline=$(($(date +%s) + total_seconds))
    attempt=0
    while :; do
        remaining=$((deadline - $(date +%s)))
        # close enough, another suspend would cost more than it saves
        [ $remaining -le 10 ] && break

        attempt=$((attempt + 1))
        if [ $attempt -gt $MAX_SUSPEND_ATTEMPTS ]; then
            ./scripts/log.sh "still ${remaining}s short after ${MAX_SUSPEND_ATTEMPTS} suspends, carrying on" "WARN"
            break
        fi
        [ $attempt -gt 1 ] && ./scripts/log.sh "woken ${remaining}s early, suspending again" "WARN"

        SuspendOnce $remaining
    done
}

function ErrorOnCurl(){
    if [ "$trmnl_loop_ignore_curl_errors" = "true" ]; then
        ./scripts/log.sh "Ignoring curl error as per configuration"
        return
    fi

    ./bin/fbink/fbdepth -r 0 >>/tmp/debug.log 2>&1
    ./bin/fbink/fbink -q -g file=./bin/error.png,valign=CENTER,halign=CENTER,h=-2,w=0 -c -f >>/tmp/debug.log 2>&1
    ./bin/fbink/fbink -m -y 5 "Retrieve TRMNL Display info failed ($curl_status)" >>/tmp/debug.log 2>&1
    ./bin/fbink/fbdepth -r -1 >>/tmp/debug.log 2>&1

    failures=$(cat "$FAILURE_COUNT_FILE" 2>/dev/null)
    failures=$(($(SaneSeconds "$failures" 0) + 1))
    echo "$failures" >"$FAILURE_COUNT_FILE"

    if [ $failures -eq 1 ]; then
        # One quick retry, the network is often back within the minute
        retry_in=$FIRST_RETRY_DELAY
    else
        # Still down, settle back to whatever rate the server last asked for
        retry_in=$(SaneSeconds "$(cat "$LAST_REFRESH_FILE" 2>/dev/null)" $DEFAULT_REFRESH)
    fi

    ./scripts/log.sh "Failure ${failures}, suspending for ${retry_in}s" "WARN"
    SuspendFor $retry_in
}


./scripts/ledToggle.sh 8 >>/tmp/debug.log 2>&1

./scripts/log.sh "enable wifi" "DEBUG"
./scripts/enable-wifi.sh >>/tmp/debug.log 2>&1

./scripts/log.sh "restore wifi" "DEBUG"
./scripts/restore-wifi-async.sh >>/tmp/debug.log 2>&1

# restore-wifi-async.sh connects in the background: wait for the IP instead of a
# fixed sleep, so the radio is powered back down sooner. ConnectedGracePeriod
# stretches the budget for slow connections.
# NOTE: ErrorOnCurl leaves the wifi up, so after a failed iteration this returns
#       at once on the previous lease, which release-ip.sh is about to drop. That
#       curl likely fails too, and the iteration after it connects normally.
grace=$trmnl_loop_connected_grace_period
case "$grace" in # "null" if missing from config.json
    '' | *[!0-9]*) grace=0 ;;
esac
./scripts/wait-for-ip.sh $((8 + grace)) >>/tmp/debug.log 2>&1 ||
    ./scripts/log.sh "No IP obtained, trying to reach TRMNL anyway" "WARN"


# Check if the battery directory exists
# (exported so logToServer.sh, which runs as a grandchild, can report it too)
export batteryCapacity
if [ -d /sys/class/power_supply/mc13892_bat ]; then
  # Set variables from the second possible path
  batteryCapacity=$(cat /sys/class/power_supply/mc13892_bat/capacity)
  batteryStatus=$(cat /sys/class/power_supply/mc13892_bat/status)
elif [ -d /sys/class/power_supply/battery ]; then
  # Set variables from the first possible path
  batteryCapacity=$(cat /sys/class/power_supply/battery/capacity)
  batteryStatus=$(cat /sys/class/power_supply/battery/status)
else
  # Handle the case where neither directory is found
  batteryCapacity=50
  batteryStatus="N/A"
  ./scripts/log.sh "Error: Could not find battery information." "DEBUG"
fi

# Battery-Charging is a 0/1 boolean. power_supply status is one of Charging,
# Discharging, Not charging, Full or Unknown, so only the first one counts.
case "$batteryStatus" in
    Charging) batteryCharging=1 ;;
    *) batteryCharging=0 ;;
esac

./scripts/log.sh "Battery capacity: ${batteryCapacity}% - Status: ${batteryStatus}" "DEBUG"

# get signal quality
# (exported so logToServer.sh, which runs as a grandchild, can report it too)
export rssi
rssi=$(./scripts/getrssi.sh)

# --fail so an HTTP error is not parsed as a payload, and time limits so a
# stalled server cannot hold the radio on indefinitely
curl "${trmnl_apiurl}/display" -L --fail --connect-timeout 15 --max-time 30 \
    -H "ID: $trmnl_id" \
    -H "Access-Token: $trmnl_token" \
    -H "Percent-Charged: $batteryCapacity" \
    -H "Battery-Charging: $batteryCharging" \
    -H "RSSI: $rssi" \
    -H "FW-Version: ${trmnl_firmware_version}" \
    -o /tmp/trmnl.json >>/tmp/debug.log 2>&1
curl_status=$?

json_content=$(jq tojson /tmp/trmnl.json)
./scripts/log.sh "TRMNL api display returned $curl_status with ${json_content:1:${#json_content}-2}" "DEBUG"
if [ $curl_status -ne 0 ]; then
    ErrorOnCurl
else
    image_url=$(jq -r '.image_url' /tmp/trmnl.json)
    # Longer ceiling than the display request, the image is much bigger
    curl -L --fail --connect-timeout 15 --max-time 60 \
        -o /tmp/trmnl.$trmnl_image_format "${image_url}" >>/tmp/debug.log 2>&1
    curl_status=$?
    ./scripts/log.sh "TRMNL fetch image from ${image_url} returned ${curl_status}" "DEBUG"
    if [ $curl_status -ne 0 ]; then
        ErrorOnCurl
    else
        # With png image is already in portrait, no need to rotate, with bmp/legacy, rotation is needed, it here that we should support reverse orientation
        if [ "$trmnl_image_format" = "bmp" ]; then
            # Rotation -r 0 break BMP rendering, rotate it 180 more to go from portrait to landscape inverted
            ./bin/fbink/fbdepth -r 2 >>/tmp/debug.log 2>&1
        fi
        ./bin/fbink/fbink -g file=/tmp/trmnl.$trmnl_image_format,valign=CENTER,halign=CENTER,h=-2,w=0 -c -f >>/tmp/debug.log 2>&1
        fbink_status=$?
        image_bytes=$(wc -c < /tmp/trmnl.$trmnl_image_format 2>/dev/null)
        if [ $fbink_status -eq 0 ]; then
            ./scripts/log.sh "Displayed ${trmnl_image_format} image of ${image_bytes} bytes" "DEBUG"
        else
            ./scripts/log.sh "fbink failed on ${trmnl_image_format} image of ${image_bytes} bytes (${fbink_status})" "WARN"
        fi

        # rotate back to portrait mode
        ./bin/fbink/fbdepth -r -1 >>/tmp/debug.log 2>&1

        refresh_rate=$(SaneSeconds "$(jq -r '.refresh_rate' /tmp/trmnl.json)" $DEFAULT_REFRESH)
        echo "$refresh_rate" >"$LAST_REFRESH_FILE"
        rm -f "$FAILURE_COUNT_FILE"
        SuspendFor $refresh_rate
    fi
fi
