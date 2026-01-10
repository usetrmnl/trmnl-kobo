if [ "$trmnl_loop_wpa_network_id" -lt 0 ]; then
    ./scripts/log.sh "Forcefully connecting to wifi"
    wpa_cli enable_network $trmnl_loop_wpa_network_id > /dev/null 2>&1
else
    ./scripts/log.sh "No valid wpa network id to force connect"
fi