#!/bin/bash
# GPU Upscaler management script
# Runs on the GPU EC2 instance

set -euo pipefail

SCRIPT_DIR="/opt/upscaler"
VENV_DIR="$SCRIPT_DIR/venv"
SERVICE_NAME="gpu-upscaler"

install() {
    echo "=== Installing GPU Upscaler ==="
    sudo mkdir -p "$SCRIPT_DIR"
    sudo cp upscale-stream.py "$SCRIPT_DIR/"
    
    # Create systemd service
    sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null << 'EOF'
[Unit]
Description=AI Video Upscaler (Maxine Super Resolution)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Environment=PATH=/home/ubuntu/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=LD_LIBRARY_PATH=/usr/local/lib:/usr/lib
ExecStart=/usr/bin/python3 /opt/upscaler/upscale-stream.py \
    --input rtmp://10.0.1.210:1935/cam3 \
    --output rtmp://10.0.1.210:1935/cam3-4k \
    --scale 2 \
    --bitrate 15000k \
    --quality medium \
    --sharpen \
    --target-fps 30
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    echo "=== Installed. Use: sudo systemctl start ${SERVICE_NAME} ==="
}

start() {
    sudo systemctl start ${SERVICE_NAME}
    sleep 2
    sudo systemctl status ${SERVICE_NAME} --no-pager | head -10
}

stop() {
    sudo systemctl stop ${SERVICE_NAME}
    echo "Upscaler stopped"
}

status() {
    sudo systemctl status ${SERVICE_NAME} --no-pager | head -15
    echo "---"
    nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader
}

logs() {
    sudo journalctl -u ${SERVICE_NAME} --no-pager -n 30
}

case "${1:-help}" in
    install) install ;;
    start)   start ;;
    stop)    stop ;;
    status)  status ;;
    logs)    logs ;;
    *)       echo "Usage: $0 {install|start|stop|status|logs}" ;;
esac
