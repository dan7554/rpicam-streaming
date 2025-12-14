# AWS Region Migration: us-east-2 → us-east-1

## Summary
Successfully migrated from **us-east-2 (Ohio)** to **us-east-1 (North Virginia)** on December 12, 2025.

---

## Cleanup in us-east-2 ✅

### Deleted Resources:
- ✅ ECS Cluster: `broadcast-cluster`
- ✅ Security Groups:
  - `broadcast-alb-sg` (sg-0f75e6b8a2de93f3a)
  - `mediamtx-security-group` (sg-0f3af3515a82a0074)
  - `test-alb-sg` (sg-0d2c1323814e3dd62)
  - `broadcast-sg` (sg-05eef265a656d5580)

---

## New Infrastructure in us-east-1 ✅

### ECS Cluster
- **Name**: `broadcast-cluster`
- **Region**: us-east-1 (North Virginia)
- **Status**: ACTIVE

### Security Groups
1. **broadcast-alb-sg** (sg-0693f1de9c2f66aef)
   - Ingress Rules:
     - HTTP (80) from 0.0.0.0/0
     - HTTPS (443) from 0.0.0.0/0
     - RTSP (8554) from 0.0.0.0/0
     - HLS (8888) from 0.0.0.0/0
     - WebRTC (8889) from 0.0.0.0/0

2. **broadcast-sg** (sg-084ba18877836077a)
   - Ingress Rules:
     - RTSP (8554) from 0.0.0.0/0
     - HLS (8888) from 0.0.0.0/0
     - WebRTC (8889) from 0.0.0.0/0

### Application Load Balancer
- **Name**: `broadcast-alb`
- **DNS Name**: `broadcast-alb-525661146.us-east-1.elb.amazonaws.com`
- **ARN**: `arn:aws:elasticloadbalancing:us-east-1:457553343935:loadbalancer/app/broadcast-alb/e5575f042e2b6251`
- **Status**: Provisioning

### Target Group
- **Name**: `broadcast-targets`
- **Protocol**: HTTP
- **Port**: 8888
- **Type**: IP
- **ARN**: `arn:aws:elasticloadbalancing:us-east-1:457553343935:targetgroup/broadcast-targets/2c6315d3d4e3ef26`

### Listener
- **Protocol**: HTTP
- **Port**: 80
- **Target Group**: `broadcast-targets`
- **ARN**: `arn:aws:elasticloadbalancing:us-east-1:457553343935:listener/app/broadcast-alb/e5575f042e2b6251/cc46fb7f9d69084a`

### ECS Task Definition
- **Name**: `mediamtx-task`
- **Revision**: 1
- **Launch Type**: FARGATE
- **CPU**: 512
- **Memory**: 1024
- **ECR Repository**: `457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:latest`
- **ARN**: `arn:aws:ecs:us-east-1:457553343935:task-definition/mediamtx-task:1`

### ECS Service
- **Name**: `broadcast-service`
- **Cluster**: `broadcast-cluster`
- **Status**: ACTIVE
- **Desired Count**: 1
- **Running Count**: 0 (starting up)
- **Load Balancer**: Connected to `broadcast-alb`
- **Network**: 
  - Subnet: subnet-0f1c0059915c44410
  - Security Group: sg-084ba18877836077a
  - Public IP: Enabled

---

## Configuration Files Updated ✅

1. **broadcast-system/mediamtx-ecs-task-definition.json**
   - ECR repository: us-east-2 → us-east-1
   - CloudWatch Logs region: us-east-2 → us-east-1

2. **Makefile**
   - AWS_REGION default: us-east-2 → us-east-1
   - All ECS/EC2 CLI calls: us-east-2 → us-east-1

3. **update-rpi-ip.sh**
   - AWS_REGION: us-east-2 → us-east-1

4. **scripts/cloudflare-dns-update-all.sh**
   - All AWS CLI calls: us-east-2 → us-east-1

5. **BROADCAST_ALB_SOLUTION.md**
   - AWS_REGION export: us-east-2 → us-east-1

---

## Next Steps

### 1. Verify Service is Running
```bash
aws ecs describe-services \
  --cluster broadcast-cluster \
  --services broadcast-service \
  --region us-east-1 \
  --query 'services[0].[serviceName,status,runningCount,desiredCount]' \
  --output table
```

### 2. Get Task IP Address
```bash
TASK_ARN=$(aws ecs list-tasks \
  --cluster broadcast-cluster \
  --desired-status RUNNING \
  --region us-east-1 \
  --query 'taskArns[0]' \
  --output text)

aws ecs describe-tasks \
  --cluster broadcast-cluster \
  --tasks $TASK_ARN \
  --region us-east-1 \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text
```

### 3. Update DNS Records
Update your domain's CNAME record to point to:
```
broadcast-alb-525661146.us-east-1.elb.amazonaws.com
```

### 4. Test Access
```bash
# Test via ALB
curl http://broadcast-alb-525661146.us-east-1.elb.amazonaws.com/health

# Test RTSP
ffplay rtsp://broadcast-alb-525661146.us-east-1.elb.amazonaws.com:8554/live
```

---

## Account Details
- **AWS Account ID**: 457553343935
- **VPC**: vpc-070fc6caa87f0f18d
- **IAM Role**: ecsTaskExecutionRole

## Status
✅ **Migration Complete** - All resources deployed to us-east-1 (North Virginia)
