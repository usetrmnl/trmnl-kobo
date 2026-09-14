#!/bin/sh

# Drop $1 when the home button is pressed, so the loop can stop without the
# hold-power reboot.
#
# NOTE: Nickel grabs the input device exclusively, so this sees nothing until
#       trmnl.sh has killed it. That is the normal case here.
# NOTE: The home button shares its node with the power button, which is how the
#       device is woken, so the key code matters: reacting to any key would stop
#       the loop on every wake.

FLAG=${1:-/tmp/trmnl_stop}
KEY_HOME=102

# input_scan prints its matches as CSV, take the first
device=$(./bin/fbink/input_scan -q -p -m home -x touchscreen 2>/dev/null | cut -d, -f1)
if [ -z "$device" ] || [ ! -e "$device" ]; then
    ./scripts/log.sh "No home button found, it cannot be used to stop the loop" "WARN"
    exit 0
fi

./scripts/log.sh "Watching ${device} for the home button" "DEBUG"
exec ./bin/luajit lua/watch_key.lua "$device" "$KEY_HOME" "$FLAG"
