#!/bin/sh

curl "${trmnl_apiurl}/log" -L \
	 -H "ID: $trmnl_id" \
	 -H "Access-Token: $trmnl_token" \
	 -H "Content-Type: application/json" \
	 -H "Battery-Voltage: $trmnl_fake_voltage" \
	 -H "RSSI: $rssi" \
	 -H "FW-Version: ${trmnl_firmware_version}" \
	 --request POST \
	 --data '{"log":["'"$1"'"]}'

