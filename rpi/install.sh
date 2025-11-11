chmod +x /home/dan7554/rpicam-stream.sh
sudo mv /home/dan7554/rpicam-stream.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rpicam-stream.service
sudo systemctl start rpicam-stream.service



# ffmpeg -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 30 -i /dev/video0   -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline   -pix_fmt yuv420p -g 15 -keyint_min 15 -sc_threshold 0   -f rtsp rtsp://192.168.50.208:8554/rpicam1