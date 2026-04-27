#!/usr/bin/env bash
# Start the Go server in the foreground for monitoring.
# Always rebuilds before starting.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building Go server..."
go build -o bin/server ./cmd/server/

# Wait for MediaMTX to be ready
echo "==> Waiting for MediaMTX..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:9997/v3/paths/list > /dev/null 2>&1; then
        echo "    MediaMTX ready."
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "!!! MediaMTX not reachable. Start it first: ./scripts/start-mediamtx.sh"
        exit 1
    fi
    sleep 1
done

echo "==> Starting Go server (foreground)..."
echo "    UI:  http://localhost:8080"
echo "    API: http://localhost:8080/api/status"
echo "    Press Ctrl+C to stop."
echo "---"
exec ./bin/server
