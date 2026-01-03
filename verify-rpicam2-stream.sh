#!/bin/bash

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║           Verifying rpicam2 → MediaMTX Stream Connection                  ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"

REGION="us-east-1"
CLUSTER="broadcast-cluster"
SERVICE="mediamtx-service"
NLB_DNS="broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com"

echo ""
echo "📡 STEP 1: Verify RPi Stream Source"
echo "═══════════════════════════════════════════════════════════════════════════"

echo "Connecting to RPi at 100.80.96.23..."
RPICAM=$(ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=5 dan7554@100.80.96.23 "pgrep -f rpicam-vid" 2>/dev/null)
FFMPEG=$(ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=5 dan7554@100.80.96.23 "pgrep -f 'ffmpeg.*broadcast-nlb'" 2>/dev/null)

if [ -n "$RPICAM" ] && [ -n "$FFMPEG" ]; then
  echo "✅ RPi processes ACTIVE"
  echo "   rpicam-vid PID: $RPICAM"
  echo "   ffmpeg PID: $FFMPEG"
  
  # Get ffmpeg command details
  echo ""
  echo "   ffmpeg command:"
  ssh -i ~/.ssh/id_ed25519 dan7554@100.80.96.23 "ps aux | grep ffmpeg | grep -v grep | sed 's/^/     /'" 2>/dev/null
  echo ""
  echo "   Suggested ffmpeg command to fix non-monotonic timestamps (run on the RPi):"
  echo "     ffmpeg -re -fflags +genpts -use_wallclock_as_timestamps 1 -avoid_negative_ts make_zero -fflags nobuffer -f h264 -i /tmp/camera.h264 -c:v copy -f rtsp -rtsp_transport tcp rtsp://$NLB_DNS:8554/rpicam2"
  echo ""
  echo "   Example SSH restart (does not run automatically):"
  echo "     ssh -i ~/.ssh/id_ed25519 dan7554@100.80.96.23 \"pkill -f 'ffmpeg.*broadcast-nlb' || true; nohup ffmpeg -re -fflags +genpts -use_wallclock_as_timestamps 1 -avoid_negative_ts make_zero -fflags nobuffer -f h264 -i /tmp/camera.h264 -c:v copy -f rtsp -rtsp_transport tcp rtsp://$NLB_DNS:8554/rpicam2 > /tmp/ffmpeg.log 2>&1 &\""
else
  echo "❌ RPi processes NOT RUNNING"
  echo "   rpicam-vid: $([ -n "$RPICAM" ] && echo "RUNNING" || echo "STOPPED")"
  echo "   ffmpeg: $([ -n "$FFMPEG" ] && echo "RUNNING" || echo "STOPPED")"
  exit 1
fi

echo ""
echo "🔗 STEP 2: Verify NLB Configuration"
echo "═══════════════════════════════════════════════════════════════════════════"

echo "NLB DNS: $NLB_DNS"

NLB_STATUS=$(aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[?contains(DNSName, 'broadcast-nlb-rtmp')].State.Code" --output text 2>/dev/null)
echo "NLB Status: $NLB_STATUS"

echo ""
echo "RTSP Target Group (Port 8554):"
RTSP_TG=$(aws elbv2 describe-target-groups --region $REGION --names mediamtx-rtsp --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
if [ -n "$RTSP_TG" ]; then
  echo "✅ RTSP Target Group found: $RTSP_TG"
  echo ""
  echo "   Target health status:"
  aws elbv2 describe-target-health --target-group-arn $RTSP_TG --region $REGION --query 'TargetHealthDescriptions[*].[Target.Id,Target.Port,TargetHealth.State,TargetHealth.Reason]' --output table 2>/dev/null | sed 's/^/   /'
else
  echo "❌ RTSP Target Group NOT FOUND"
fi

echo ""
echo "📊 STEP 3: Verify MediaMTX Service Status"
echo "═══════════════════════════════════════════════════════════════════════════"

SERVICE_JSON=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION --output json 2>/dev/null)
RUNNING=$(echo "$SERVICE_JSON" | jq -r '.services[0].runningCount' 2>/dev/null)
DESIRED=$(echo "$SERVICE_JSON" | jq -r '.services[0].desiredCount' 2>/dev/null)
STATUS=$(echo "$SERVICE_JSON" | jq -r '.services[0].status' 2>/dev/null)

echo "Service: $SERVICE"
echo "Status: $STATUS"
echo "Running: $RUNNING/$DESIRED"

if [ "$RUNNING" -ge "$DESIRED" ]; then
  echo "✅ Sufficient tasks running"
else
  echo "⚠️ Degraded: Only $RUNNING/$DESIRED tasks running"
fi

echo ""
echo "🏃 STEP 4: Running Tasks and Their IPs"
echo "═══════════════════════════════════════════════════════════════════════════"

TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns' --output text 2>/dev/null)

if [ -z "$TASKS" ]; then
  echo "❌ No running tasks found"
  exit 1
fi

TASK_COUNT=$(echo "$TASKS" | wc -w)
echo "✅ $TASK_COUNT tasks running"
echo ""

aws ecs describe-tasks --cluster $CLUSTER --tasks $TASKS --region $REGION --output json 2>/dev/null | jq -r '.tasks[] | "\(.taskArn | split("/")[-1]): \(.lastStatus) - IP: \(.attachments[] | select(.name=="ElasticNetworkInterface") | .details[] | select(.name=="privateIPv4Address") | .value)"' | while read line; do
  echo "   $line"
done

echo ""
echo "🔌 STEP 5: Test Stream Connection"
echo "═══════════════════════════════════════════════════════════════════════════"

echo "Testing NLB RTSP port connectivity..."
if timeout 3 bash -c "exec 3<>/dev/tcp/$NLB_DNS/8554" 2>/dev/null; then
  echo "✅ NLB port 8554 is reachable"
else
  echo "⚠️ NLB port 8554 not reachable (may be firewall)"
fi

echo ""
echo "Testing RTSP stream endpoint..."
RTSP_TEST=$(timeout 5 ffprobe -rtsp_transport tcp -i "rtsp://$NLB_DNS:8554/rpicam2" -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 2>&1 | head -1)

if [ -n "$RTSP_TEST" ]; then
  echo "✅ RTSP stream accessible via ffprobe"
  echo "   Duration detected: $RTSP_TEST"
else
  echo "⚠️ RTSP stream not accessible via ffprobe (may be firewall or stream not active)"
fi

echo ""
echo "📋 STEP 6: MediaMTX Service Details"
echo "═══════════════════════════════════════════════════════════════════════════"

TASK_DEF=$(echo "$SERVICE_JSON" | jq -r '.services[0].taskDefinition' 2>/dev/null)
echo "Task Definition: $TASK_DEF"

echo ""
echo "Environment variables (MediaMTX config):"
aws ecs describe-task-definition --task-definition "$TASK_DEF" --region $REGION --query 'taskDefinition.containerDefinitions[0].environment[*].[name,value]' --output text 2>/dev/null | grep -i "mtx\|rtsp\|hls" | while read name value; do
  echo "   $name = $value"
done

echo ""
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                           VERIFICATION SUMMARY                            ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"

echo ""
echo "Stream Path:"
echo "  RPi (100.80.96.23)"
echo "  ↓ rpicam-vid (H.264 capture)"
echo "  ↓ ffmpeg RTSP push"
echo "  → NLB:8554 (broadcast-nlb-rtmp-...)"
echo "  ↓ RTSP target group"
echo "  → MediaMTX Service (Fargate tasks)"
echo "  ↓ Stream Processing"
echo "  → HLS (8888) / RTMP (1935) / WebRTC (8889) outputs"

echo ""
if [ "$RUNNING" -ge "$DESIRED" ] && [ -n "$RPICAM" ] && [ -n "$FFMPEG" ]; then
  echo "✅ VERIFICATION COMPLETE - Stream path is operational"
else
  echo "⚠️ VERIFICATION INCOMPLETE - Check components above"
fi

echo ""
