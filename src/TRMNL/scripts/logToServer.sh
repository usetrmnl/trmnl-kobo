#!/bin/sh

curl "${trmnl_apiurl}/log" -L \
	 -H "ID: $trmnl_id" \
	 -H "Access-Token: $trmnl_token" \
	 -H "Content-Type: application/json" \
	 -H "Percent-Charged: $batteryCapacity" \
	 -H "RSSI: $rssi" \
	 -H "FW-Version: ${trmnl_firmware_version}" \
	 --request POST \
	 --data '{"log":["'"$1"'"]}'

