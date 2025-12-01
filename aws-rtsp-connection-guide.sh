#!/bin/bash

# Troubleshooting Guide for RTSP Connection on AWS
# Since ALB doesn't support TCP and creating new NLB is restricted,
# here are the available options:

echo "=== RTSP Port 8554 Connection Options ==="
echo ""
echo "Issue: ALB only supports HTTP/HTTPS, and NLB creation is restricted"
echo ""
echo "Current Task IP: 172.31.8.36 (Private)"
echo "Region: us-east-2"
echo ""
echo "=== OPTION 1: Use Private IP Directly (VPC/Tailscale/VPN) ==="
echo "If you have access to the VPC via:"
echo "  - Bastion host"
echo "  - VPN"
echo "  - AWS Systems Manager Session Manager"
echo "  - Tailscale network"
echo ""
echo "Connect to: rtsp://172.31.8.36:8554/rpicam2"
echo ""
echo ""
echo "=== OPTION 2: Enable Task Public IP ==="
echo "To automatically assign public IP to ECS tasks:"
echo "  aws ecs update-service \\"
echo "    --cluster mediamtx-cluster \\"
echo "    --service mediamtx-service \\"
echo "    --network-configuration 'awsvpcConfiguration={assignPublicIp=ENABLED}' \\"
echo "    --region us-east-2"
echo ""
echo "Then update rpicam-stream.sh to use the public IP"
echo ""
echo ""
echo "=== OPTION 3: Use AWS Systems Manager Port Forward ==="
echo "Forward port 8554 from the task through AWS Systems Manager:"
echo "  aws ssm start-session --region us-east-2 --parameters 'portNumber=8554,localPortNumber=8554' \\"
echo "    --target ecs:mediamtx-cluster_mediamtx-service_0281e94af5ff489e8340614fe64d042e"
echo ""
echo ""
echo "=== OPTION 4: Contact AWS Support ==="
echo "Request to remove the ELB creation restriction on the account"
echo ""
echo ""
echo "=== OPTION 5: Use Tailscale for Remote Access ==="
echo "If you have Tailscale set up on the ECS host:"
echo "  1. Verify Tailscale is running in the task or on the EC2 instance"
echo "  2. Connect via Tailscale IP"
echo ""
echo ""
echo "=== Current Configuration Status ==="
aws ecs describe-services \
  --cluster mediamtx-cluster \
  --services mediamtx-service \
  --region us-east-2 \
  --query 'services[0].[serviceName,status,runningCount,desiredCount]' \
  --output table

echo ""
echo "=== Recommended Next Steps ==="
echo ""
echo "1. Check current network configuration:"
echo "   aws ecs describe-services --cluster mediamtx-cluster --services mediamtx-service --region us-east-2 | jq '.services[0].networkConfiguration'"
echo ""
echo "2. Verify security groups allow 8554:"
echo "   aws ec2 describe-security-groups --region us-east-2 --filters 'Name=vpc-id,Values=vpc-02ade1b99b9c8087e' --query 'SecurityGroups[*].[GroupId,GroupName,IpPermissions[?FromPort==\`8554\`]]'"
echo ""
echo "3. For immediate testing from a connected machine:"
echo "   timeout 5 bash -c '</dev/tcp/172.31.8.36/8554' && echo 'Connected' || echo 'Not connected'"
echo ""

