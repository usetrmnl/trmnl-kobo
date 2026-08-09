#!/bin/sh

# The server takes its entries from a "logs" array of objects and silently ignores
# any other shape while still answering 200, so a flat {"log":["msg"]} stored
# nothing. jq builds the body so quotes and backslashes in the message, which our
# own log lines carry, cannot produce invalid json.
jq -nc --arg msg "$1" --arg ts "$(date +%s)" \
	'{logs:[{message:$msg,creation_timestamp:($ts|tonumber)}]}' |
# -s -o /dev/null: this runs once per log line, the progress meter and the response
# body were going straight to the console
curl "${trmnl_apiurl}/log" -L -s -o /dev/null \
	 --fail --connect-timeout 15 --max-time 30 \
	 -H "ID: $trmnl_id" \
	 -H "Access-Token: $trmnl_token" \
	 -H "Content-Type: application/json" \
	 -H "Percent-Charged: $batteryCapacity" \
	 -H "RSSI: $rssi" \
	 -H "FW-Version: ${trmnl_firmware_version}" \
	 --request POST \
	 --data @-
status=$?
if [ $status -ne 0 ]; then # straight to the log, log.sh would recurse back here
	echo "[$(date)] logToServer.sh: POST failed ($status)" >>/tmp/debug.log
fi
