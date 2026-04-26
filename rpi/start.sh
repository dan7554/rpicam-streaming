#!/bin/bash
sudo systemctl start rpicam-stream.service
echo "Service started. Check: journalctl -fu rpicam-stream"
