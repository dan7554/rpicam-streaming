#!/bin/bash

# Configuration
PI_USER="dan7554"
PI_HOST="rpicam3.local"
PI_PASSWORD="!Dan1007554"  # Set your password here or use environment variable: export PI_PASSWORD="yourpassword"

# Check if password is set
if [ -z "$PI_PASSWORD" ]; then
    echo "Warning: PI_PASSWORD not set. You'll need to enter password manually for each connection."
    echo "To set password: export PI_PASSWORD=\"yourpassword\" or edit this script"
    echo ""
    # Use regular scp/ssh without password
    SCP_CMD="scp"
    SSH_CMD="ssh"
else
    # Check if sshpass is installed
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "Error: sshpass is required for password authentication but not installed"
        echo "Install with: brew install sshpass (macOS) or apt-get install sshpass (Linux)"
        echo "Or remove password and use SSH keys instead"
        exit 1
    fi
    # Use sshpass for password authentication
    SCP_CMD="sshpass -p \"$PI_PASSWORD\" scp"
    SSH_CMD="sshpass -p \"$PI_PASSWORD\" ssh"
fi

echo "Copying files to Raspberry Pi..."
eval $SCP_CMD rpi/install.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/logs.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/stop.sh $PI_USER@$PI_HOST:/home/dan7554/

eval $SCP_CMD rpi/rpicam-stream.sh $PI_USER@$PI_HOST:/home/dan7554/
eval $SCP_CMD rpi/rpicam-stream.service $PI_USER@$PI_HOST:/home/dan7554/

echo "Installing and starting service..."
eval $SSH_CMD $PI_USER@$PI_HOST << 'EOF'
chmod +x /home/dan7554/rpicam-stream.sh
sudo cp /home/dan7554/rpicam-stream.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rpicam-stream.service
sudo systemctl start rpicam-stream.service
echo "Service status:"
sudo systemctl status rpicam-stream.service --no-pager
EOF

echo "Done! Service should be running on Raspberry Pi."