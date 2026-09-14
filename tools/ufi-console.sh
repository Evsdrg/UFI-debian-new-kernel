#!/usr/bin/env bash
# Bounded serial access to the UFI103s console.
#
# PORT/BAUD are discovered facts, not assumptions: the CH343 adapter on this
# bench enumerates as cdc_acm and needs 57600 baud (a nominal 115200 setting
# comes out as garbage because of the adapter's clock).  Run `ufi-console.sh id`
# after any re-plug, since the USB path and tty name can change.
set -u

PORT="${UFI_CONSOLE_PORT:-/dev/ttyACM0}"
BAUD="${UFI_CONSOLE_BAUD:-57600}"
SUDO_PW="${SUDO_PW:-REDACTED}"

sudo_do() { echo "$SUDO_PW" | sudo -S "$@" 2>/dev/null; }

configure() {
    sudo_do stty -F "$PORT" "$BAUD" cs8 -cstopb -parenb raw -echo
}

# Read the console for N seconds, optionally sending command lines first.
# Usage: ufi-console.sh read <seconds>
#        ufi-console.sh send <seconds> <line> [line...]
read_for() {
    local secs=$1; shift
    configure
    local f
    f=$(mktemp /tmp/ufi-console.XXXXXX)
    sudo_do timeout "$secs" cat "$PORT" >"$f" &
    local catpid=$!
    if [ "$#" -gt 0 ]; then
        sleep 1
        local line
        for line in "$@"; do
            sudo_do sh -c "printf '%s\r' > '$PORT'"
            sleep 2
        done
    fi
    wait "$catpid" 2>/dev/null
    cat "$f"
    rm -f "$f"
}

case "${1:-}" in
    id)
        echo "port=$PORT baud=$BAUD"
        echo "resolved: $(readlink -f "$PORT" 2>/dev/null)"
        readlink -f "/sys/class/tty/${PORT##*/}/device" 2>/dev/null
        ;;
    read) shift; read_for "${1:-5}" ;;
    send) shift; read_for "${1:-8}" "${@:2}" ;;
    *)
        echo "usage: $0 {id|read <secs>|send <secs> <line>...}" >&2
        exit 2
        ;;
esac
