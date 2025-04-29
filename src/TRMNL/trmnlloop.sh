#!/bin/sh

./scripts/ledToggle.sh 8 >>/tmp/crash.log 2>&1

./scripts/log.sh "enable wifi"
./scripts/enable-wifi.sh >>/tmp/crash.log 2>&1

./scripts/log.sh "restore wifi"
./scripts/restore-wifi-async.sh >>/tmp/crash.log 2>&1
sleep 5s

sleep $trmnl_loop_connected_grace_period

batteryCapacity=$( cat /sys/class/power_supply/mc13892_bat/capacity )
batteryStatus=$( cat /sys/class/power_supply/mc13892_bat/status )
trmnl_low_voltage=3.11
trmnl_high_voltage=4.08
trmnl_fake_voltage=$(echo "scale=3; ($batteryCapacity / 100) * ($trmnl_high_voltage-$trmnl_low_voltage) + $trmnl_low_voltage" | bc)

echo "Battery capacity: ${batteryCapacity} - Status: ${batteryStatus} - Voltage for API: $trmnl_fake_voltage" >>/tmp/crash.log 2>&1

curl https://usetrmnl.com/api/display -H "ID: $trmnl_id" -H "Access-Token: $trmnl_token" -H "Battery-Voltage: $trmnl_fake_voltage" -o /tmp/trmnl.json
curl_status=$?

./scripts/log.sh "TRMNL api display returned $curl_status"
if [ $curl_status -ne 0 ]; then
    fbink -g file=noserver.png,valign=CENTER,halign=CENTER,h=-2,w=0 > /dev/null 2>&1
    fbink -x 1 -y 5 "Retrieve TRMNL Display info failed"  > /dev/null 2>&1
    sleep 15s
else
    curl -o /tmp/trmnl.bmp "$(jq -r '.image_url' /tmp/trmnl.json)"
    curl_status=$?
    if [ $curl_status -ne 0 ]; then
        ./scripts/log.sh "TRMNL fetch image returned $curl_status"
        fbink -g file=noserver.png,valign=CENTER,halign=CENTER,h=-2,w=0 > /dev/null 2>&1
        fbink -x 1 -y 5 "Retrieve TRMNL S3 bitmap failed"  > /dev/null 2>&1
        sleep 15s
    else
        #with fbdepth -r 0 convert not needed
        convert /tmp/trmnl.bmp -rotate 90 /tmp/trmnl_r.bmp
        fbink -g file=/tmp/trmnl_r.bmp,valign=CENTER,halign=CENTER,h=-2,w=0 -c -f
        sleep 10s

        ./scripts/log.sh "disabling wifi"
        ./scripts/disable-wifi.sh >>/tmp/crash.log 2>&1

        refresh_rate=$(jq -r '.refresh_rate' /tmp/trmnl.json)
        ./scripts/log.sh "Should sleep for ${refresh_rate}"
        sleep 5s

        ./scripts/log.sh "Enable suspend state"
        echo 1 >/sys/power/state-extended >>/tmp/crash.log 2>&1
        if [ $? -eq 0 ]; then
            ./scripts/log.sh "Enabled suspend state ok"
        else
            ./scripts/log.sh "Enable suspend state failed"
        fi

        ./scripts/log.sh "Setting up rtcwake alarm"

        # Record the start time
        start_time=$(date +%s)
        ./bin/busybox_kobo rtcwake -a -s $refresh_rate -m mem >>/tmp/crash.log 2>&1
        if [ $? -eq 0 ]; then
            ./scripts/log.sh "rtcwake ok"
        else
            ./scripts/log.sh "rtcwake failed"
        fi

        # Calculate the elapsed time
        elapsed_time_in_rtcwake=$(($(date +%s) - start_time))

        # Check if the elapsed time is greater than 10 seconds
        if [ "$elapsed_time_in_rtcwake" -gt 10 ]; then
            ./scripts/log.sh "rtcwake took more than 10 seconds, skipping suspend to mem in power state"
        else
            ./scripts/log.sh  "rtcwake took ${elapsed_time_in_rtcwake}, writing suspend to mem in power state"
            ./scripts/ledToggle.sh 0  >>/tmp/crash.log 2>&1
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
            echo 0 >/sys/power/state-extended >>/tmp/crash.log 2>&1
            if [ $? -eq 0 ]; then
                ./scripts/log.sh "Disabled suspend state ok"
            else
                ./scripts/log.sh "Disable suspend state failed"
            fi
        fi
    fi
fi
