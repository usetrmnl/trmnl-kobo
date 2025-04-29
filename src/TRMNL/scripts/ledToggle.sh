#!/bin/sh
CHARGING_LED=""
if [ -d "/sys/class/leds/LED" ] ; then
	CHARGING_LED="/sys/class/leds/LED/brightness"
elif [ -d "/sys/class/leds/GLED" ] ; then
        CHARGING_LED="/sys/class/leds/GLED/brightness"
elif [ -d "/sys/class/leds/bd71828-green-led" ] ; then
        CHARGING_LED="/sys/class/leds/bd71828-green-led/brightness"
elif [ -d "/sys/class/leds/pmic_ledsg" ] ; then
        CHARGING_LED="/sys/class/leds/pmic_ledsg/brightness"
fi

# Now, test if CHARGING_LED was set
if [ -z "$CHARGING_LED" ]; then
    # This block runs if none of the paths were found
    echo "Error: Couldn't find the charging led." >&2 # Print errors to stderr
    exit 1 # Exit with a non-zero status indicating failure
fi
echo "Found charging LED path: $CHARGING_LED setting value $1"
echo "$1" > "$CHARGING_LED" 
exit 0
