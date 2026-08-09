#!/bin/sh

function ErrorOnCurl(){
    if [ "$trmnl_loop_ignore_curl_errors" = "true" ]; then
        ./scripts/log.sh "Ignoring curl error as per configuration"
        return
    else
        ./bin/fbink/fbdepth -r 0
        ./bin/fbink/fbink -q -g file=./bin/error.png,valign=CENTER,halign=CENTER,h=-2,w=0 -c -f > /dev/null 2>&1
        ./bin/fbink/fbink -m -y 5 "Retrieve TRMNL Display info failed ($curl_status)"  > /dev/null 2>&1
        ./bin/fbink/fbdepth -r -1
        sleep 15s
    fi
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

curl "${trmnl_apiurl}/display" -L \
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
    curl -L -o /tmp/trmnl.$trmnl_image_format "${image_url}" >>/tmp/debug.log 2>&1
    curl_status=$?
    ./scripts/log.sh "TRMNL fetch image from ${image_url} returned ${curl_status}" "DEBUG"
    if [ $curl_status -ne 0 ]; then
        ErrorOnCurl
    else
        # With png image is already in portrait, no need to rotate, with bmp/legacy, rotation is needed, it here that we should support reverse orientation
        if [ "$trmnl_image_format" = "bmp" ]; then
            # Rotation -r 0 break BMP rendering, rotate it 180 more to go from portrait to landscape inverted
            ./bin/fbink/fbdepth -r 2
        fi
        ./bin/fbink/fbink -g file=/tmp/trmnl.$trmnl_image_format,valign=CENTER,halign=CENTER,h=-2,w=0 -c -f

        # rotate back to portrait mode
        ./bin/fbink/fbdepth -r -1

        ./scripts/log.sh "disabling wifi" "DEBUG"
        ./scripts/disable-wifi.sh >>/tmp/debug.log 2>&1

        refresh_rate=$(jq -r '.refresh_rate' /tmp/trmnl.json)
        ./scripts/log.sh "Should sleep for ${refresh_rate}" "DEBUG"
        sleep 5s

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
        ./bin/busybox_kobo rtcwake -a -s $refresh_rate -m mem >>/tmp/debug.log 2>&1
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
    fi
fi
