#!/bin/sh

# Hand the Kobo back to its own UI without a reboot, following KOReader's
# platform/kobo/nickel.sh. trmnl.sh killed nickel, switched the framebuffer and
# changed the cpu governor on the way in, so all of that has to be undone first.
# Must run from the TRMNL directory, before the cd below.

if [ ! -x /usr/local/Kobo/nickel ]; then
    ./scripts/log.sh "No nickel to restore, leaving the device as it is" "WARN"
    exit 1
fi

# Nickel does not like finding the wifi up (koreader #1520)
./scripts/log.sh "Restoring nickel, disabling wifi first" "DEBUG"
./scripts/disable-wifi.sh >>/tmp/debug.log 2>&1

# Put the framebuffer back the way nickel expects it, or its UI comes up garbled
if [ -n "${ORIG_FB_BPP}" ]; then
    ./bin/fbink/fbdepth -d "${ORIG_FB_BPP}" -r "${ORIG_FB_ROTA}" >>/tmp/debug.log 2>&1
fi
if [ -n "${ORIG_CPUFREQ_GOV}" ] && [ -n "${CPUFREQ_SYSFS_PATH}" ]; then
    echo "${ORIG_CPUFREQ_GOV}" >"${CPUFREQ_SYSFS_PATH}/scaling_governor"
fi

# Clear our own stuff out of the environment, USBMS gets wonky otherwise
cd / || exit 1
unset OLDPWD
unset LC_ALL
export LD_LIBRARY_PATH="/usr/local/Kobo"

if [ -e "/etc/init.d/on-animator.sh" ]; then
    # nickel kills on-animator.sh on start, so there is nothing to reap
    (
        usleep 400000
        /etc/init.d/on-animator.sh
    ) &
fi

if [ -e "/etc/init.d/z-nickel-hardware-status" ]; then
    # FW 5 has its own startup scripts, the prefix gets prepended by them
    unset LD_LIBRARY_PATH
    /etc/init.d/z-nickel-hardware-status
    sync
    /etc/rc.local
else
    # Recreate the FIFO rcS makes and trmnl.sh removed: udev writes to it and
    # nickel reads it
    rm -f /tmp/nickel-hardware-status
    mkfifo /tmp/nickel-hardware-status

    sync

    /usr/local/Kobo/hindenburg &
    LIBC_FATAL_STDERR_=1 /usr/local/Kobo/nickel -platform kobo -skipFontLoad &
    [ "${PLATFORM}" != "freescale" ] && udevadm trigger &
fi

exit 0
