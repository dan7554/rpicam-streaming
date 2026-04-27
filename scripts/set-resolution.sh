#!/bin/bash
# Switch Pi camera resolution between 720p and 1080p.
# Usage: ./scripts/set-resolution.sh 1080    (switch to 1920x1080)
#        ./scripts/set-resolution.sh 720     (switch to 1280x720)
#        ./scripts/set-resolution.sh         (show current resolution)

PIES="${PIES:-rpicam2 rpicam3}"

case "${1:-}" in
    1080)
        W=1920; H=1080
        # Bump bitrate for 1080p (2.25x more pixels than 720p)
        BITRATE=6000
        ;;
    720)
        W=1280; H=720
        BITRATE=3000
        ;;
    "")
        echo "Current resolution on each Pi:"
        for pi in $PIES; do
            echo -n "  $pi: "
            ssh "$pi" 'grep -E "^(WIDTH|HEIGHT)" /etc/rpicam-stream.conf 2>/dev/null || echo "default (1280x720)"'
        done
        exit 0
        ;;
    *)
        echo "Usage: $0 [720|1080]"
        exit 1
        ;;
esac

echo "Setting all cameras to ${W}x${H} (bitrate=${BITRATE}kbps)..."

for pi in $PIES; do
    echo "  $pi: updating /etc/rpicam-stream.conf..."
    ssh "$pi" "
        # Preserve existing MEDIAMTX_HOST if set, otherwise use Tailscale IP
        HOST=\$(grep '^MEDIAMTX_HOST=' /etc/rpicam-stream.conf 2>/dev/null || echo 'MEDIAMTX_HOST=100.100.74.51')
        sudo tee /etc/rpicam-stream.conf > /dev/null << EOF
WIDTH=$W
HEIGHT=$H
BITRATE=$BITRATE
\${HOST}
EOF
"
    echo "  $pi: restarting rpicam-stream..."
    ssh "$pi" "sudo systemctl restart rpicam-stream"
done

echo "Waiting for streams to reconnect..."
sleep 5

# Verify
for pi in $PIES; do
    cam=$(echo "$pi" | sed 's/rpicam/cam/')
    res=$(curl -s 'http://localhost:9997/v3/paths/list' 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data['items']:
    if p['name'] == '$cam':
        for t in p.get('tracks2', []):
            if t['codec'] == 'H264':
                cp = t.get('codecProps', {})
                print(f\"{cp.get('width','?')}x{cp.get('height','?')}\")
" 2>/dev/null)
    echo "  $cam: ${res:-not ready yet}"
done

echo "Done. Restart live session to pick up new resolution."
