#!/bin/sh

# Wait for an IPv4 address on any interface but lo, i.e. wifi associated and DHCP done.
# Usage: wait-for-ip.sh [timeout_seconds]. Exits 0 once found, 1 on timeout.

timeout=${1:-8}
case "$timeout" in # config.json is user edited
    '' | *[!0-9]*) timeout=8 ;;
esac

# No-arg ifconfig lists only interfaces that are up (do not switch to -a).
# 169.254/16 is dhcpcd's IPv4LL fallback, i.e. DHCP failed, so it is not success.
# The wifi interface is not always wlan0 (INTERFACE defaults to eth0 on Kobo).
FindIp() {
    ifconfig 2>/dev/null | awk '
        /^[^ \t]/ { iface = $1; sub(/:$/, "", iface) }   # stanza header
        /inet6/   { next }
        /inet/ {
            if (iface == "lo") next
            addr = $0
            sub(/^.*inet[ \t]*(addr:)?[ \t]*/, "", addr)
            sub(/[^0-9.].*$/, "", addr)
            if (addr != "" && addr != "0.0.0.0" && addr !~ /^169\.254\./) {
                print iface " " addr
                found = 1
                exit
            }
        }
        END { exit !found }
    '
}

ticks=0 # 250ms each
max_ticks=$((timeout * 4))
while :; do
    if found_ip=$(FindIp); then
        echo "[$(date)] wait-for-ip.sh: got ${found_ip} after $((ticks / 4))s"
        exit 0
    fi

    if [ ${ticks} -ge ${max_ticks} ]; then
        # measured, not ${timeout}: they diverge if usleep is missing and the loop spins
        echo "[$(date)] wait-for-ip.sh: still no IP after $((ticks / 4))s, giving up"
        exit 1
    fi

    usleep 250000
    ticks=$((ticks + 1))
done
