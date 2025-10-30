# RPiCam RTSP Stream Setup Instructions

## Files Created:
1. `rpicam-stream.service` - Systemd service file
2. `rpicam-stream.sh` - Main script with retry logic

## Installation Steps:

### 1. Copy files to Raspberry Pi:
```bash
# Copy the script to Pi
scp rpicam-stream.sh pi@192.168.50.96:/home/pi/
scp rpicam-stream.service pi@192.168.50.96:/home/pi/

# SSH to Pi
ssh pi@192.168.50.96
```

### 2. Set up the script:
```bash
# Make script executable
chmod +x /home/pi/rpicam-stream.sh

# Move service file to systemd directory
sudo mv /home/pi/rpicam-stream.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable rpicam-stream.service
```

### 3. Start and manage the service:
```bash
# Start the service
sudo systemctl start rpicam-stream.service

# Check status
sudo systemctl status rpicam-stream.service

# View logs
sudo journalctl -u rpicam-stream.service -f

# Stop the service
sudo systemctl stop rpicam-stream.service

# Restart the service
sudo systemctl restart rpicam-stream.service
```

## Features:

### Automatic Retry:
- Checks RTSP server availability before connecting
- Infinite retries by default (configurable)
- 5-second delay between retries (configurable)
- 30-second connection timeout (configurable)

### Logging:
- All output goes to systemd journal
- View logs with: `sudo journalctl -u rpicam-stream.service -f`
- Timestamps on all log messages

### Configuration:
Edit `/home/pi/rpicam-stream.sh` to modify:
- `RTSP_SERVER="mac:8554"` - Change server address
- `STREAM_NAME="rpicam"` - Change stream name
- `MAX_RETRIES=0` - Set retry limit (0 = infinite)
- `RETRY_DELAY=5` - Seconds between retries
- `CONNECTION_TIMEOUT=30` - Server connection timeout

### Service Management:
- Automatically starts on boot
- Restarts if it crashes
- Runs as 'pi' user with 'video' group access
- Proper signal handling for clean shutdown