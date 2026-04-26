#!/bin/bash
# Manual install — prefer using deploy.sh from the server instead
set -e
sudo mkdir -p /opt/rpicam-stream
sudo cp rpicam-stream.sh /opt/rpicam-stream/rpicam-stream.sh
sudo chmod +x /opt/rpicam-stream/rpicam-stream.sh
sudo cp rpicam-stream.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rpicam-stream
echo "Installed. Set MEDIAMTX_HOST in /etc/rpicam-stream.conf"
echo "Then: sudo systemctl start rpicam-stream"