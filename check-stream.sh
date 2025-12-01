ffplay -rtsp_transport tcp rtsp://rtsp.racetrackstreaming.com:8554/rpicam2 -vf "drawtext=text='TEST':x=10:y=10:fontsize=24:fontcolor=white" 2>&1 | head -40 &
sleep 2 && echo "FFplay should be attempting to display the stream..." &
wait
