#!/bin/bash
NLB_DNS="broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com"

echo "🎬 PRODUCTION STREAM TEST - NLB Connection"
echo "=========================================="
echo ""
echo "Testing RTSP stream from NLB..."
echo "Stream URL: rtsp://$NLB_DNS:8554/rpicam2"
echo ""

# Test with ffprobe
if /usr/local/bin/ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_type,width,height,r_frame_rate \
    -of csv=p=0 "rtsp://$NLB_DNS:8554/rpicam2" 2>/dev/null; then
    echo ""
    echo "✅ SUCCESS! Stream is ACTIVE on NLB"
else
    echo ""
    echo "⏳ Stream not yet visible (checking again...)"
    sleep 5
    
    # Try again
    if /usr/local/bin/ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_type,width,height,r_frame_rate \
        -of csv=p=0 "rtsp://$NLB_DNS:8554/rpicam2" 2>/dev/null; then
        echo ""
        echo "✅ SUCCESS! Stream is now ACTIVE on NLB"
    else
        echo ""
        echo "⚠️  Stream not detected yet"
        echo "Checking ECS task status..."
        aws ecs describe-services --cluster broadcast-cluster --services mediamtx-service --region us-east-1 --query 'services[0].{Running: runningCount, Desired: desiredCount}' --output json
    fi
fi
