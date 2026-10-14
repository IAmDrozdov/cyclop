#!/bin/bash
# Shoots the README pictures from the demo build: one PNG per scene, cropped to the panel body.
# Usage: shoot.sh [--no-build] [--out DIR] [scene...]   (default: every scene, out .local/readme/shots)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP="$ROOT/build/Cyclop Demo.app"
EXE="$APP/Contents/MacOS/Cyclop"
DOMAIN="com.cyclop.app.demo"
OUT="$ROOT/.local/readme/shots"
BUILD=1
MAX_BYTES=300000

# name:tab[:request]. The request scene sends one permission request through the real hook relay.
ALL_SCENES=(claude-request:claude:request shelf:shelf clipboard:clipboard snippets:snippets translate:translate
    caffeine:caffeine currency:currency teleprompter:teleprompter meetings:meetings claude:claude)

SCENES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --out) OUT="$2"; shift ;;
        -h|--help) sed -n 2,3p "$0"; exit 0 ;;
        *) SCENES+=("$1") ;;
    esac
    shift
done
if [ ${#SCENES[@]} -eq 0 ]; then
    SCENES=("${ALL_SCENES[@]}")
else
    picked=()
    for want in "${SCENES[@]}"; do
        match=""
        for scene in "${ALL_SCENES[@]}"; do [ "${scene%%:*}" = "$want" ] && match="$scene"; done
        [ -n "$match" ] || { echo "!!! unknown scene: $want" >&2; exit 2; }
        picked+=("$match")
    done
    SCENES=("${picked[@]}")
fi

die() { echo "!!! $*" >&2; exit 1; }

# Anchored: a shell whose command line merely mentions the path is not the app.
if pgrep -f "^$EXE( |\$)" >/dev/null; then
    die "a Cyclop Demo is already running; quit it first"
fi

DEMO=""
APP_PID=""
RELAY_PID=""
CLEANED=0
cleanup() {
    [ "$CLEANED" = 1 ] && return
    CLEANED=1
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
    [ -n "$APP_PID" ] && stop_app || true
    [ -n "$DEMO" ] && rm -rf "$DEMO"
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$DOMAIN.plist"
    echo "==> cleaned up"
}
trap cleanup EXIT
trap 'echo "!!! interrupted" >&2; exit 130' INT TERM

if [ "$BUILD" = 1 ] || [ ! -x "$EXE" ]; then
    "$ROOT/Scripts/bundle.sh" demo
fi

DEMO="$(mktemp -d "${TMPDIR:-/tmp}/cyclop-demo.XXXXXX")"
# The Claude socket inside it must fit in sun_path (104 bytes, the NUL included).
SOCKET="$DEMO/support/claude.sock"
[ ${#SOCKET} -lt 104 ] || die "the demo folder path is too long for a socket ($SOCKET); set a shorter TMPDIR"
mkdir -p "$DEMO/claude" "$OUT"
# The demo build refuses a folder without this mark.
: >"$DEMO/.cyclop-demo"
defaults delete "$DOMAIN" >/dev/null 2>&1 || true

stop_app() {  # TERM, then KILL after 10 s
    kill "$APP_PID" 2>/dev/null || true
    local deadline=$((SECONDS + 10))
    while kill -0 "$APP_PID" 2>/dev/null && [ $SECONDS -lt $deadline ]; do sleep 0.25; done
    kill -9 "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
}

wait_for() {  # file, seconds
    local file="$1" deadline=$((SECONDS + $2))
    while [ ! -s "$file" ]; do
        [ $SECONDS -lt $deadline ] || return 1
        kill -0 "$APP_PID" 2>/dev/null || die "the demo app exited; log: $(tail -5 "$DEMO/app.log")"
        sleep 0.25
    done
}

json() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$@"; }

shoot() {
    local name="$1" tab="$2" request="${3:-}"
    rm -f "$DEMO/ready.json" "$DEMO/request.ready"
    CYCLOP_DEMO_DIR="$DEMO" CYCLOP_DEMO_TAB="$tab" CYCLOP_CLAUDE_SETTINGS="$DEMO/claude/settings.json" \
        "$EXE" -AppleLanguages '(en)' -AppleLocale en_US >"$DEMO/app.log" 2>&1 &
    APP_PID=$!
    # The first launch records and transcribes the demo meetings before it opens.
    wait_for "$DEMO/ready.json" 120 || die "$name: the panel did not report ready in time"

    if [ -n "$request" ]; then
        sed "s|@CWD@|/Users/demo/code/storefront|" >"$DEMO/request.json" <<'JSON'
{"session_id":"5d0c6a52-8f1e-4b7a-9c3d-2e61f0a4b917","transcript_path":"/Users/demo/.claude/projects/storefront/5d0c6a52.jsonl","cwd":"@CWD@","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test -- --runInBand checkout.spec.ts","description":"Run the checkout tests serially"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}
JSON
        "$EXE" --claude-relay "$SOCKET" <"$DEMO/request.json" >/dev/null 2>&1 &
        RELAY_PID=$!
        wait_for "$DEMO/request.ready" 20 || die "$name: the request card did not appear"
    fi

    local window scale x y width height
    window="$(json "$DEMO/ready.json" window)"
    scale="$(json "$DEMO/ready.json" scale)"
    x="$(json "$DEMO/ready.json" x)"; y="$(json "$DEMO/ready.json" y)"
    width="$(json "$DEMO/ready.json" width)"; height="$(json "$DEMO/ready.json" height)"

    local raw="$DEMO/raw-$name.png" png="$OUT/$name.png"
    if ! screencapture -x -o -l"$window" "$raw" 2>"$DEMO/capture.err" || [ ! -s "$raw" ]; then
        die "screencapture could not read the window ($(cat "$DEMO/capture.err")). Give Screen Recording to the app this script runs in (System Settings > Privacy & Security > Screen & System Audio Recording), then run it again."
    fi
    local px=$(/usr/bin/python3 -c "print(round($x*$scale), round($y*$scale), round($width*$scale), round($height*$scale))")
    read -r cx cy cw ch <<<"$px"
    sips -c "$ch" "$cw" --cropOffset "$cy" "$cx" "$raw" --out "$png" >/dev/null
    local bytes; bytes=$(stat -f %z "$png")
    # A capture without the permission comes back as an empty, transparent window.
    [ "$bytes" -gt 20000 ] || die "$name: the picture is nearly empty ($bytes bytes): Screen Recording is probably missing for the app this script runs in."
    [ "$bytes" -le "$MAX_BYTES" ] || echo "    warning: $name.png is $bytes bytes, over $MAX_BYTES"
    echo "    $name.png  ${cw}x${ch}  $bytes bytes"

    [ -n "$RELAY_PID" ] && { kill "$RELAY_PID" 2>/dev/null || true; RELAY_PID=""; }
    stop_app
}

echo "==> shooting into $OUT"
for scene in "${SCENES[@]}"; do
    IFS=: read -r name tab request <<<"$scene"
    shoot "$name" "$tab" "$request"
done
echo "==> done: ${#SCENES[@]} pictures"
