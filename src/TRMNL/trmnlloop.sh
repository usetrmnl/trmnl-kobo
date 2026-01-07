#!/bin/sh

./scripts/ledToggle.sh 8 >>/tmp/debug.log 2>&1

./scripts/log.sh "enable wifi"
./scripts/enable-wifi.sh >>/tmp/debug.log 2>&1

./scripts/log.sh "restore wifi"
./scripts/restore-wifi-async.sh >>/tmp/debug.log 2>&1

# Wait for Wi-Fi
./scripts/log.sh "Waiting for Wi-Fi to be up..."
for i in $(seq 1 ${trmnl_loop_connected_grace_period:-30}); do
    if ping -W 1 -c 1 ${trmnl_network_check_ping_host:-1.1.1.1}; then
	./scripts/log.sh "Wi-Fi is up"
        break
    fi
    sleep 1
done
./scripts/log.sh "Proceeding after Wi-Fi connection check"

retry=5

# Check if the battery directory exists
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
  echo "Error: Could not find battery information." >&2
fi

# 4.08 = 90% => 4.19 = 100 %
# 3.12 = 10% => 3.00 = 0 %

trmnl_low_mv=3000
trmnl_high_mv=4195

range_mv=$((trmnl_high_mv - trmnl_low_mv))
voltage_mv=$(( (batteryCapacity * range_mv / 100) + trmnl_low_mv ))

# Convert back to voltage with decimal using string manipulation
trmnl_fake_voltage="${voltage_mv:0:${#voltage_mv}-3}.${voltage_mv: -3}"

./scripts/log.sh "Battery capacity: ${batteryCapacity}%- Status: ${batteryStatus} - Voltage for API: ${trmnl_fake_voltage}V"

# get signal quality
rssi=$(./scripts/getrssi.sh)

curl "${trmnl_apiurl}/display" -L \
    -H "ID: $trmnl_id" \
    -H "Access-Token: $trmnl_token" \
    -H "Battery-Voltage: $trmnl_fake_voltage" \
    -H "RSSI: $rssi" \
    -H "FW-Version: ${trmnl_firmware_version}" \
    -o /tmp/trmnl.json >>/tmp/debug.log 2>&1
curl_status=$?

json_content=$(cat /tmp/trmnl.json)
./scripts/log.sh "TRMNL api display returned $curl_status with ${json_content}"
if [ $curl_status -ne 0 ]; then
    ./bin/fbink/fbdepth -r 0
    ./bin/fbink/fbink -q -g file=./bin/error.png,valign=CENTER,halign=CENTER,h=-2,w=0 -c -f > /dev/null 2>&1
    ./bin/fbink/fbink -m -y 5 "Retrieve TRMNL Display info failed ($curl_status)"  > /dev/null 2>&1
    ./bin/fbink/fbdepth -r -1
    sleep 15s
else
    image_url=$(jq -r '.image_url' /tmp/trmnl.json)
    curl -L -o /tmp/trmnl.$trmnl_image_format "${image_url}" >>/tmp/debug.log 2>&1
    curl_status=$?
    ./scripts/log.sh "TRMNL fetch image from ${image_url} returned ${curl_status}"
    if [ $curl_status -ne 0 ]; then
        ./bin/fbink/fbdepth -r 0
        ./bin/fbink/fbink -q -g file=./bin/error.png,valign=CENTER,halign=CENTER,h=-2,w=0 -c -f > /dev/null 2>&1
        ./bin/fbink/fbink -q -m -y -5 "Retrieve TRMNL S3 $trmnl_image_format failed ($curl_status)"  > /dev/null 2>&1
        ./bin/fbink/fbdepth -r -1
        sleep 15s
    else
        # With png image is already in portrait, no need to rotate, with bmp/legacy, rotation is needed, it here that we should support reverse orientation
        if [ "$trmnl_image_format" = "bmp" ]; then
            # Rotation -r 0 break BMP rendering, rotate it 180 more to go from portrait to landscape inverted
            ./bin/fbink/fbdepth -r 2
        fi
        ./bin/fbink/fbink -g file=/tmp/trmnl.$trmnl_image_format,valign=CENTER,halign=CENTER,h=-2,w=0 -c -f

        # rotate back to portrait mode
        ./bin/fbink/fbdepth -r -1

        ./scripts/log.sh "disabling wifi"
        ./scripts/disable-wifi.sh >>/tmp/debug.log 2>&1

        refresh_rate=$(jq -r '.refresh_rate' /tmp/trmnl.json)
        ./scripts/log.sh "Should sleep for ${refresh_rate}"
        sleep 5s

        ./scripts/log.sh "Enable suspend state"
        echo 1 >/sys/power/state-extended >>/tmp/debug.log 2>&1
        if [ $? -eq 0 ]; then
            ./scripts/log.sh "Enabled suspend state ok"
        else
            ./scripts/log.sh "Enable suspend state failed"
        fi

        ./scripts/log.sh "Setting up rtcwake alarm"

        # Record the start time
        start_time=$(date +%s)
        ./bin/busybox_kobo rtcwake -a -s $refresh_rate -m mem >>/tmp/debug.log 2>&1
        if [ $? -eq 0 ]; then
            ./scripts/log.sh "rtcwake ok"
        else
            ./scripts/log.sh "rtcwake failed, will try secondary suspend to memory next"
        fi

        # Calculate the elapsed time
        elapsed_time_in_rtcwake=$(($(date +%s) - start_time))

        # Check if the elapsed time is greater than 10 seconds
        if [ "$elapsed_time_in_rtcwake" -gt 10 ]; then
            ./scripts/log.sh "rtcwake took more than 10 seconds, skipping suspend to mem in power state"
        else
            ./scripts/log.sh  "rtcwake took ${elapsed_time_in_rtcwake}, writing suspend to mem in power state"
            ./scripts/ledToggle.sh 0  >>/tmp/debug.log 2>&1
            sleep 1s
            sync
            sleep 2s
            echo mem >/sys/power/state
            if [ $? -eq 0 ]; then
                ./scripts/log.sh "Suspend to mem ok"
            else
                ./scripts/log.sh "Suspend to mem failed"
            fi

            ./scripts/log.sh "Disable suspend state"
            echo 0 >/sys/power/state-extended >>/tmp/debug.log 2>&1
            if [ $? -eq 0 ]; then
                ./scripts/log.sh "Disabled suspend state ok"
            else
                ./scripts/log.sh "Disable suspend state failed"
            fi
        fi
    fi
fi
