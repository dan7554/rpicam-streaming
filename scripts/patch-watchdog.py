#!/usr/bin/env python3
"""Patch rpicam-stream.sh watchdog to detect CLOSE-WAIT connections."""
import sys

with open("/opt/rpicam-stream/rpicam-stream.sh", "r") as f:
    lines = f.readlines()

# Find the watchdog function boundaries
start_idx = None
end_idx = None
brace_depth = 0
for i, line in enumerate(lines):
    if line.strip() == "start_watchdog() {":
        start_idx = i
        brace_depth = 1
        continue
    if start_idx is not None and brace_depth > 0:
        brace_depth += line.count("{") - line.count("}")
        if brace_depth <= 0:
            end_idx = i
            break

if start_idx is None or end_idx is None:
    print("ERROR: Could not find start_watchdog function")
    sys.exit(1)

print(f"Found start_watchdog at lines {start_idx+1}-{end_idx+1}")

new_watchdog = '''start_watchdog() {
    local gst_pid="$1"
    local strikes=0
    local closewait_strikes=0
    while kill -0 "$gst_pid" 2>/dev/null; do
        sleep "$WATCHDOG_INTERVAL"

        # Check for CLOSE-WAIT (server disconnected, GStreamer didn't notice)
        local close_wait
        close_wait=$(ss -tnp 2>/dev/null | grep ":${RTMP_PORT}" | grep -c "CLOSE-WAIT" || true)
        if [ "${close_wait:-0}" -gt 0 ]; then
            closewait_strikes=$((closewait_strikes + 1))
            log "WATCHDOG: CLOSE-WAIT detected (strike $closewait_strikes/2)"
            if [ "$closewait_strikes" -ge 2 ]; then
                log "WATCHDOG: server gone (CLOSE-WAIT), killing GStreamer (pid $gst_pid)"
                kill "$gst_pid" 2>/dev/null
                sleep 1
                kill -9 "$gst_pid" 2>/dev/null
                return
            fi
        else
            closewait_strikes=0
        fi

        # Check for stuck send buffer
        local send_q
        send_q=$(ss -tnp 2>/dev/null | grep ":${RTMP_PORT}" | grep -v "FIN\|CLOSE\|TIME" | awk '{print $3}' | sort -rn | head -1)
        send_q="${send_q:-0}"

        if [ "$send_q" -gt "$WATCHDOG_THRESHOLD" ]; then
            strikes=$((strikes + 1))
            log "WATCHDOG: send buffer ${send_q} bytes (strike $strikes/$WATCHDOG_MAX_STRIKES)"
            if [ "$strikes" -ge "$WATCHDOG_MAX_STRIKES" ]; then
                log "WATCHDOG: connection stuck, killing GStreamer (pid $gst_pid)"
                kill "$gst_pid" 2>/dev/null
                sleep 1
                kill -9 "$gst_pid" 2>/dev/null
                return
            fi
        else
            strikes=0
        fi
    done
}
'''

# Replace the function
lines[start_idx:end_idx+1] = [new_watchdog]

with open("/opt/rpicam-stream/rpicam-stream.sh", "w") as f:
    f.writelines(lines)

print("Watchdog patched successfully")
