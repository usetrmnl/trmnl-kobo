#!/bin/sh
export LC_ALL="en_US.UTF-8"

# Set your TRMNL Mac Address in Id:
export trmnl_id="$(jq -r '.TrmnlId' config.json)"

# Set your TRMNL API Key in Token
export trmnl_token="$(jq -r '.TrmnlToken' config.json)"

# Change if BYOS, no trailing slash
export trmnl_apiurl="$(jq -r '.TrmnlApiUrl' config.json)"

# Do not log to screen if 0, otherwise log to screen too
export debug_to_screen=$(jq -r '.DebugToScreen' config.json)

# Set a maximum iteration, if 0, do not stop
export trmnl_loop_iteration_stop=$(jq -r '.LoopMaxIteration' config.json)

# If 0, do not wait once connected to wifi, otherwise wait X sec to let user connect to SSH and troubleshoot
export trmnl_loop_connected_grace_period=$(jq -r '.ConnectedGracePeriod' config.json)

# Must me Major.Minor.Revision format
export trmnl_firmware_version=$(cat version.txt)

# Compute our working directory in an extremely defensive manner
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# NOTE: We need to remember the *actual* TRMNL_DIR, not the relocalized version in /tmp...
export TRMNL_DIR="${TRMNL_DIR:-${SCRIPT_DIR}}"

# We rely on starting from our working directory, and it needs to be set, sane and absolute.
cd "${TRMNL_DIR:-/dev/null}" || exit

# To make USBMS behave, relocalize ourselves outside of onboard
if [ "${SCRIPT_DIR}" != "/tmp" ]; then
    cp -pf "${0}" "/tmp/trmnl.sh"
    chmod 777 "/tmp/trmnl.sh"
    exec "/tmp/trmnl.sh" "$@"
fi

# Attempt to switch to a sensible CPUFreq governor when that's not already the case...
# Swap every CPU at once if available
if [ -d "/sys/devices/system/cpu/cpufreq/policy0" ]; then
    CPUFREQ_SYSFS_PATH="/sys/devices/system/cpu/cpufreq/policy0"
else
    CPUFREQ_SYSFS_PATH="/sys/devices/system/cpu/cpu0/cpufreq"
fi
IFS= read -r current_cpufreq_gov <"${CPUFREQ_SYSFS_PATH}/scaling_governor"
# NOTE: What's available depends on the HW, so, we'll have to take it step by step...
#       Roughly follow Nickel's behavior (which prefers interactive), and prefer interactive, then ondemand, and finally conservative/dvfs.
if [ "${current_cpufreq_gov}" != "interactive" ]; then
    if grep -q "interactive" "${CPUFREQ_SYSFS_PATH}/scaling_available_governors"; then
        ORIG_CPUFREQ_GOV="${current_cpufreq_gov}"
        echo "interactive" >"${CPUFREQ_SYSFS_PATH}/scaling_governor"
    elif [ "${current_cpufreq_gov}" != "ondemand" ]; then
        if grep -q "ondemand" "${CPUFREQ_SYSFS_PATH}/scaling_available_governors"; then
            # NOTE: This should never really happen: every kernel that supports ondemand already supports interactive ;).
            #       They were both introduced on Mk. 6
            ORIG_CPUFREQ_GOV="${current_cpufreq_gov}"
            echo "ondemand" >"${CPUFREQ_SYSFS_PATH}/scaling_governor"
        elif [ -e "/sys/devices/platform/mxc_dvfs_core.0/enable" ]; then
            # The rest of this block assumes userspace is available...
            if grep -q "userspace" "${CPUFREQ_SYSFS_PATH}/scaling_available_governors"; then
                ORIG_CPUFREQ_GOV="${current_cpufreq_gov}"
                export CPUFREQ_DVFS="true"

                # If we can use conservative, do so, but we'll tweak it a bit to make it somewhat useful given our load patterns...
                # We unfortunately don't have any better choices on those kernels,
                # the only other governors available are powersave & performance (c.f., #4114)...
                if grep -q "conservative" "${CPUFREQ_SYSFS_PATH}/scaling_available_governors"; then
                    export CPUFREQ_CONSERVATIVE="true"
                    echo "conservative" >"${CPUFREQ_SYSFS_PATH}/scaling_governor"
                    # NOTE: The knobs survive a governor switch, which is why we do this now ;).
                    echo "2" >"/sys/devices/system/cpu/cpufreq/conservative/sampling_down_factor"
                    echo "50" >"/sys/devices/system/cpu/cpufreq/conservative/freq_step"
                    echo "11" >"/sys/devices/system/cpu/cpufreq/conservative/down_threshold"
                    echo "12" >"/sys/devices/system/cpu/cpufreq/conservative/up_threshold"
                    # NOTE: The default sampling_rate is a bit high for my tastes,
                    #       but it unfortunately defaults to its lowest possible setting...
                fi

                # NOTE: Now, here comes the freaky stuff... On a H2O, DVFS is only enabled when Wi-Fi is *on*.
                #       When it's off, DVFS is off, which pegs the CPU @ max clock given that DVFS means the userspace governor.
                #       The flip may originally have been switched by the sdio_wifi_pwr module itself,
                #       via ntx_wifi_power_ctrl @ arch/arm/mach-mx5/mx50_ntx_io.c (which is also the CM_WIFI_CTRL (208) ntx_io ioctl),
                #       but the code in the published H2O kernel sources actually does the reverse, and is commented out ;).
                #       It is now entirely handled by Nickel, right *before* loading/unloading that module.
                #       (There's also a bug(?) where that behavior is inverted for the *first* Wi-Fi session after a cold boot...)
                if grep -q "^sdio_wifi_pwr " "/proc/modules"; then
                    # Wi-Fi is enabled, make sure DVFS is on
                    echo "userspace" >"${CPUFREQ_SYSFS_PATH}/scaling_governor"
                    echo "1" >"/sys/devices/platform/mxc_dvfs_core.0/enable"
                else
                    # Wi-Fi is disabled, make sure DVFS is off
                    echo "0" >"/sys/devices/platform/mxc_dvfs_core.0/enable"

                    # Switch to conservative to avoid being stuck at max clock if we can...
                    if [ -n "${CPUFREQ_CONSERVATIVE}" ]; then
                        echo "conservative" >"${CPUFREQ_SYSFS_PATH}/scaling_governor"
                    else
                        # Otherwise, we'll be pegged at max clock...
                        echo "userspace" >"${CPUFREQ_SYSFS_PATH}/scaling_governor"
                        # The kernel should already be taking care of that...
                        cat "${CPUFREQ_SYSFS_PATH}/scaling_max_freq" >"${CPUFREQ_SYSFS_PATH}/scaling_setspeed"
                    fi
                fi
            fi
        fi
    fi
fi

# Quick'n dirty way of checking if we were started while Nickel was running (e.g., KFMon),
# or from another launcher entirely, outside of Nickel (e.g., KSM).
VIA_NICKEL="false"
if pkill -0 nickel; then
    VIA_NICKEL="true"
fi
# NOTE: Do not delete this line because KSM detects newer versions of KOReader by the presence of the phrase 'from_nickel'.

if [ "${VIA_NICKEL}" = "true" ]; then
    # Detect if we were started from KFMon
    FROM_KFMON="false"
    if pkill -0 kfmon; then
        # That's a start, now check if KFMon truly is our parent...
        if [ "$(pidof -s kfmon)" -eq "${PPID}" ]; then
            FROM_KFMON="true"
        fi
    fi

    # Check if Nickel is our parent...
    FROM_NICKEL="false"
    if [ -n "${NICKEL_HOME}" ]; then
        FROM_NICKEL="true"
    fi

    # If we were spawned outside of Nickel, we'll need a few extra bits from its own env...
    if [ "${FROM_NICKEL}" = "false" ]; then
        # Siphon a few things from nickel's env (namely, stuff exported by rcS *after* on-animator.sh has been launched)...
        # shellcheck disable=SC2046
        export $(grep -s -E -e '^(DBUS_SESSION_BUS_ADDRESS|NICKEL_HOME|WIFI_MODULE|LANG|INTERFACE)=' "/proc/$(pidof -s nickel)/environ")
    fi

    # If bluetooth is enabled, kill it.
    if [ -e "/sys/devices/platform/bt/rfkill/rfkill0/state" ]; then
        # That's on sunxi, at least
        IFS= read -r bt_state <"/sys/devices/platform/bt/rfkill/rfkill0/state"
        if [ "${bt_state}" = "1" ]; then
            echo "0" >"/sys/devices/platform/bt/rfkill/rfkill0/state"

            # Power the chip down
            ./bin/luajit frontend/device/kobo/ntx_io.lua 126 0
        fi
    fi
    if grep -q "^sdio_bt_pwr " "/proc/modules"; then
        # And that's on NXP SoCs
        rmmod sdio_bt_pwr
    fi

    # Flush disks, might help avoid trashing nickel's DB...
    sync
    # And we can now stop the full Kobo software stack
    # NOTE: We don't need to kill KFMon, it's smart enough not to allow running anything else while we're up
    # NOTE: We kill Nickel's master dhcpcd daemon on purpose,
    #       as we want to be able to use our own per-if processes w/ custom args later on.
    #       A SIGTERM does not break anything, it'll just prevent automatic lease renewal until the time
    #       KOReader actually sets the if up itself (i.e., it'll do)...
    killall -q -TERM nickel hindenburg sickel fickel strickel fontickel adobehost foxitpdf iink dhcpcd-dbus dhcpcd bluealsa bluetoothd fmon nanoclock.lua

    # Wait for Nickel to die... (oh, procps with killall -w, how I miss you...)
    kill_timeout=0
    while pkill -0 nickel; do
        # Stop waiting after 4s
        if [ ${kill_timeout} -ge 15 ]; then
            break
        fi
        usleep 250000
        kill_timeout=$((kill_timeout + 1))
    done
    # Remove Nickel's FIFO to avoid udev & udhcpc scripts hanging on open() on it...
    rm -f /tmp/nickel-hardware-status
fi

# check whether PLATFORM & PRODUCT have a value assigned by rcS
if [ -z "${PRODUCT}" ]; then
    # shellcheck disable=SC2046
    export $(grep -s -e '^PRODUCT=' "/proc/$(pidof -s udevd)/environ")
fi

if [ -z "${PRODUCT}" ]; then
    PRODUCT="$(/bin/kobo_config.sh 2>/dev/null)"
    export PRODUCT
fi

# PLATFORM is used in koreader for the path to the Wi-Fi drivers (as well as when restarting nickel)
if [ -z "${PLATFORM}" ]; then
    # shellcheck disable=SC2046
    export $(grep -s -e '^PLATFORM=' "/proc/$(pidof -s udevd)/environ")
fi

if [ -z "${PLATFORM}" ]; then
    PLATFORM="freescale"
    if dd if="/dev/mmcblk0" bs=512 skip=1024 count=1 | grep -q "HW CONFIG"; then
        CPU="$(ntx_hwconfig -s -p /dev/mmcblk0 CPU 2>/dev/null)"
        PLATFORM="${CPU}-ntx"
    fi

    if [ "${PLATFORM}" != "freescale" ] && [ ! -e "/etc/u-boot/${PLATFORM}/u-boot.mmc" ]; then
        PLATFORM="ntx508"
    fi
    export PLATFORM
fi

# Make sure we have a sane-ish INTERFACE env var set...
if [ -z "${INTERFACE}" ]; then
    # That's what we used to hardcode anyway
    INTERFACE="eth0"
    export INTERFACE
fi

# We'll enforce UR in ko_do_fbdepth, so make sure further FBInk usage (USBMS)
# will also enforce UR... (Only actually meaningful on sunxi).
if [ "${PLATFORM}" = "b300-ntx" ]; then
    export FBINK_FORCE_ROTA=0
    # On sunxi, non-REAGL waveform modes suffer from weird merging quirks...
    FBINK_WFM="REAGL"
    # And we also cannot use batched updates for the crash screen, as buffers are private,
    # so each invocation essentially draws in a different buffer...
    FBINK_BATCH_FLAG=""
    # Same idea for backgroundless...
    FBINK_BGLESS_FLAG="-B GRAY9"
    # It also means we need explicit background padding in the OT codepath...
    FBINK_OT_PADDING=",padding=BOTH"

    # Make sure we poke the right input device
    KOBO_TS_INPUT="/dev/input/by-path/platform-0-0010-event"
else
    FBINK_WFM="GL16"
    FBINK_BATCH_FLAG="-b"
    FBINK_BGLESS_FLAG="-O"
    FBINK_OT_PADDING=""
    KOBO_TS_INPUT="/dev/input/event1"
fi

# We'll want to ensure Portrait rotation to allow us to use faster blitting codepaths @ 8bpp,
# so remember the current one before fbdepth does its thing.
IFS= read -r ORIG_FB_ROTA <"/sys/class/graphics/fb0/rotate"
echo "Original fb rotation is set @ ${ORIG_FB_ROTA}" >>/tmp/debug.log 2>&1

# In the same vein, swap to 8bpp,
# because 16bpp is the worst idea in the history of time, as RGB565 is generally a PITA without hardware blitting,
# and 32bpp usually gains us nothing except a performance hit (we're not Qt5 with its QPainter constraints).
# The reduced size & complexity should hopefully make things snappier,
# (and hopefully prevent the JIT from going crazy on high-density screens...).
# NOTE: Even though both pickel & Nickel appear to restore their preferred fb setup, we'll have to do it ourselves,
#       as they fail to flip the grayscale flag properly. Plus, we get to play nice with every launch method that way.
#       So, remember the current bitdepth, so we can restore it on exit.
IFS= read -r ORIG_FB_BPP <"/sys/class/graphics/fb0/bits_per_pixel"
echo "Original fb bitdepth is set @ ${ORIG_FB_BPP}bpp" >>/tmp/debug.log 2>&1
# Sanity check...
case "${ORIG_FB_BPP}" in
8) ;;
16) ;;
32) ;;
*)
    # Uh oh? Don't do anything...
    unset ORIG_FB_BPP
    ;;
esac

# The actual swap is done in a function, because we can disable it in the Developer settings, and we want to honor it on restart.
ko_do_fbdepth() {
    # On sunxi, the fb state is meaningless, and the minimal disp fb doesn't actually support 8bpp anyway...
    if [ "${PLATFORM}" = "b300-ntx" ]; then
        # NOTE: The fb state is *completely* meaningless on this platform.
        #       This is effectively a noop, we're just keeping it for logging purposes...
        echo "Making sure that rotation is set to Portrait" >>/tmp/debug.log 2>&1
        fbdepth -R UR >>/tmp/debug.log 2>&1
        # We haven't actually done anything, so don't do anything on exit either ;).
        unset ORIG_FB_BPP

        return
    fi

    # On color panels, we target 32bpp for, well, color, and sane addressing (it also happens to be their default) ;o).
    eval "$(fbink -e | tr ';' '\n' | grep -e hasColorPanel | tr '\n' ';')"
    # shellcheck disable=SC2154
    if [ "${hasColorPanel}" = "1" ]; then
        # If color rendering has been disabled by the user, switch to 8bpp to completely skip CFA processing
        if grep -q '\["color_rendering"\] = false' 'settings.reader.lua' 2>/dev/null; then
            echo "Switching fb bitdepth to 8bpp (to disable CFA) & rotation to Portrait" >>/tmp/debug.log 2>&1
            fbdepth -d 8 -R UR >>/tmp/debug.log 2>&1
        else
            echo "Switching fb bitdepth to 32bpp & rotation to Portrait" >>/tmp/debug.log 2>&1
            fbdepth -d 32 -R UR >>/tmp/debug.log 2>&1
        fi

        return
    fi

    # Check if the swap has been disabled...
    if grep -q '\["dev_startup_no_fbdepth"\] = true' 'settings.reader.lua' 2>/dev/null; then
        # Swap back to the original bitdepth (in case this was a restart)
        if [ -n "${ORIG_FB_BPP}" ]; then
            # Unless we're a Forma/Libra, don't even bother to swap rotation if the fb is @ 16bpp, because RGB565 is terrible anyways,
            # so there's no faster codepath to achieve, and running in Portrait @ 16bpp might actually be broken on some setups...
            if [ "${ORIG_FB_BPP}" -eq "16" ] && [ "${PRODUCT}" != "frost" ] && [ "${PRODUCT}" != "storm" ]; then
                echo "Making sure we're using the original fb bitdepth @ ${ORIG_FB_BPP}bpp & rotation @ ${ORIG_FB_ROTA}" >>/tmp/debug.log 2>&1
                fbdepth -d "${ORIG_FB_BPP}" -r "${ORIG_FB_ROTA}" >>/tmp/debug.log 2>&1
            else
                echo "Making sure we're using the original fb bitdepth @ ${ORIG_FB_BPP}bpp, and that rotation is set to Portrait" >>/tmp/debug.log 2>&1
                fbdepth -d "${ORIG_FB_BPP}" -R UR >>/tmp/debug.log 2>&1
            fi
        fi
    else
        # Swap to 8bpp if things looke sane
        if [ -n "${ORIG_FB_BPP}" ]; then
            echo "Switching fb bitdepth to 8bpp & rotation to Portrait" >>/tmp/debug.log 2>&1
            fbdepth -d 8 -R UR >>/tmp/debug.log 2>&1
        fi
    fi
}

# Ensure we start with a valid nameserver in resolv.conf, otherwise we're stuck with broken name resolution (#6421, #6424).
# Fun fact: this wouldn't be necessary if Kobo were using a non-prehistoric glibc... (it was fixed in glibc 2.26).
ko_do_dns() {
    # If there aren't any servers listed, append CloudFlare's
    if ! grep -q '^nameserver' "/etc/resolv.conf"; then
        echo "# Added by KOReader because your setup is broken" >>"/etc/resolv.conf"
        echo "nameserver 1.1.1.1" >>"/etc/resolv.conf"
    fi
}

# Remount the SD card RW if it's inserted and currently RO
if awk '$4~/(^|,)ro($|,)/' /proc/mounts | grep ' /mnt/sd '; then
    mount -o remount,rw /mnt/sd
fi

# Do or double-check the fb depth switch, or restore original bitdepth if requested
ko_do_fbdepth
# Make sure we have a sane resolv.conf
ko_do_dns

# ensure hardware clock and system time are in sync
hwclock -w -u

while true; do
    count=$((count + 1))
    ./scripts/log.sh "$(date +%T) >> Loop ${count}"
    echo  >>/tmp/debug.log 2>&1

    # logging everything block the suspend
    ./trmnlloop.sh
    if [ $count -eq $trmnl_loop_iteration_stop ] && [ $trmnl_loop_iteration_stop -ne 0 ]; then
        ./scripts/log.sh "Stopping script after $count iterations."
        break
    fi
done

# Wipe the clones on exit
rm -f "/tmp/trmnl.sh"
# we keep at most 500KB worth of crash log
if [ -e /tmp/debug.log ]; then
    tail -c 500000 /tmp/debug.log >/tmp/debug.log.new
    mv -f /tmp/debug.log.new /tmp/debug.log
fi
cp /tmp/debug.log debug.log

reboot
exit 0
