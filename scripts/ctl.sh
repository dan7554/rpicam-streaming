#!/usr/bin/env bash
# Control the media-mtx server from the command line.
# Usage: ./ctl.sh <command> [args...]
set -euo pipefail

API="${API_URL:-http://localhost:8080}"

usage() {
    cat <<EOF
Usage: $0 <command> [args...]

Commands:
  status                        Show current state
  streams                       List all streams
  switch <cam>                  Switch active camera (cam1, cam2, cam3)
  live-start <cam> [rtmp_dest]  Start RTMP output (default: local live-output)
  live-stop                     Stop RTMP output
  overlay-start <url|event_id> [session_id] [max_rows]
                                Start timing overlay from MYLAPS SpeedHive
                                Accepts a full SpeedHive URL or event/session IDs
  overlay-stop                  Stop timing overlay
  overlay-status                Show overlay state

Environment:
  API_URL   Server URL (default: http://localhost:8080)

Examples:
  $0 status
  $0 switch cam2
  $0 live-start cam1
  $0 live-start cam1 rtmp://a.rtmp.youtube.com/live2/YOUR-KEY
  $0 overlay-start https://speedhive.mylaps.com/livetiming/1CDCD1BA383B88F4-2147485280/sessions/...
  $0 overlay-start 1CDCD1BA383B88F4-2147485280
  $0 overlay-start 1CDCD1BA383B88F4-2147485280 1CDCD1BA383B88F4-2147485280-1073743690 8
EOF
    exit 1
}

post() { curl -s -X POST "$API$1" -H 'Content-Type: application/json' -d "$2"; }
get()  { curl -s "$API$1"; }
pp()   { python3 -m json.tool 2>/dev/null || cat; }

[ $# -ge 1 ] || usage

case "$1" in
    status)
        get /api/status | pp
        ;;
    streams)
        get /api/streams | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('items',[]):
    ready = '✓' if s['ready'] else '·'
    tracks = len(s.get('tracks',[]))
    print(f'  {ready} {s[\"name\"]:15s} {tracks} tracks')
" 2>/dev/null || get /api/streams | pp
        ;;
    switch)
        [ $# -ge 2 ] || { echo "Usage: $0 switch <cam>"; exit 1; }
        post /api/switch "{\"stream\":\"$2\"}" | pp
        ;;
    live-start)
        [ $# -ge 2 ] || { echo "Usage: $0 live-start <cam> [rtmp_dest]"; exit 1; }
        cam="$2"
        if [ $# -ge 3 ]; then
            post /api/live/start "{\"stream\":\"$cam\",\"rtmp_dest\":\"$3\"}" | pp
        else
            post /api/live/start "{\"stream\":\"$cam\"}" | pp
        fi
        ;;
    live-stop)
        post /api/live/stop '{}' | pp
        ;;
    overlay-start)
        [ $# -ge 2 ] || { echo "Usage: $0 overlay-start <url|event_id> [session_id] [max_rows]"; exit 1; }
        arg="$2"
        if [[ "$arg" == http* ]]; then
            max_rows="${3:-10}"
            body="{\"url\":\"$arg\",\"max_rows\":$max_rows}"
        else
            event_id="$arg"
            session_id="${3:-}"
            max_rows="${4:-10}"
            body="{\"event_id\":\"$event_id\""
            [ -n "$session_id" ] && body="$body,\"session_id\":\"$session_id\""
            body="$body,\"max_rows\":$max_rows}"
        fi
        post /api/overlay/start "$body" | pp
        ;;
    overlay-stop)
        post /api/overlay/stop '{}' | pp
        ;;
    overlay-status)
        get /api/overlay/status | pp
        ;;
    *)
        echo "Unknown command: $1"
        usage
        ;;
esac
