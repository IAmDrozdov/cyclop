#!/bin/bash
# Restart build/Cyclop.app and check that it survives launch. `relaunch.sh stop`
# only quits it. Touches only the build/ copy; another running Cyclop stops the
# script with exit 2, since two copies both draw a panel.
set -u

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1
APP="$ROOT/build/Cyclop.app"
BIN="$APP/Contents/MacOS/Cyclop"
WAIT="${WAIT:-10}"

stop() {
    pkill -f "$BIN" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$BIN" >/dev/null || return 0
        sleep 0.3
    done
    echo "!!! $BIN is still running" >&2
    return 1
}

# Cyclop processes started from anywhere but build/, as "pid command".
others() {
    for pid in $(pgrep -x Cyclop); do
        cmd="$(ps -ww -o command= -p "$pid")"
        case "$cmd" in "$BIN"*) ;; *) echo "$pid $cmd" ;; esac
    done
}

if [ "${1:-}" = "stop" ]; then
    stop && echo "==> stopped"
    exit $?
fi

[ -x "$BIN" ] || { echo "!!! no $APP: run ./Scripts/bundle.sh first" >&2; exit 1; }
OTHERS="$(others)"
if [ -n "$OTHERS" ]; then
    echo "!!! another Cyclop is running; ask the owner whether to quit it:" >&2
    echo "$OTHERS" >&2
    exit 2
fi
stop || exit 1

STARTED="$(date '+%Y-%m-%d %H:%M:%S')"
MARK="$(mktemp)"
trap 'rm -f "$MARK"' EXIT
open "$APP" || exit 1
sleep "$WAIT"

if PID="$(pgrep -f "$BIN")"; then
    echo "==> Cyclop is running (pid $PID) after ${WAIT}s"
    if pgrep -f "$APP/Contents/Resources/libcyclopmedia" >/dev/null; then
        echo "==> Now Playing helper is running"
    else
        echo "==> Now Playing helper is not running: Music is switched off, or the helper failed (see the log)"
    fi
    exit 0
fi

echo "!!! Cyclop exited within ${WAIT}s" >&2
echo "--- log since launch ---" >&2
log show --start "$STARTED" --style compact --predicate 'process == "Cyclop"' 2>/dev/null | tail -40 >&2
REPORT="$(ls -t "$HOME"/Library/Logs/DiagnosticReports/Cyclop*.ips 2>/dev/null | head -1)"
if [ -n "$REPORT" ] && [ "$REPORT" -nt "$MARK" ]; then
    echo "--- $REPORT ---" >&2
    head -c 4000 "$REPORT" >&2
fi
exit 1
