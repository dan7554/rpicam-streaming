chmod +x /home/dan7554/rpicam-stream.sh
sudo mv /home/dan7554/rpicam-stream.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rpicam-stream.service
sudo systemctl start rpicam-stream.service

