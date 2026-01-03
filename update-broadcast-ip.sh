#!/bin/bash
# Update broadcast task to use direct IP instead of DNS

set -e

echo "📋 Registering broadcast task definition with IP-based MediaMTX URL..."

aws ecs register-task-definition \
  --family broadcast-task \
  --network-mode awsvpc \
  --cpu 256 \
  --memory 512 \
  --requires-compatibilities FARGATE \
  --execution-role-arn arn:aws:iam::457553343935:role/ecsTaskExecutionRole \
  --container-definitions '[
    {
      "name": "broadcast-system",
      "image": "457553343935.dkr.ecr.us-east-1.amazonaws.com/broadcast-system:latest",
      "cpu": 256,
      "memory": 512,
      "portMappings": [
        {"containerPort": 80, "hostPort": 80, "protocol": "tcp"},
        {"containerPort": 443, "hostPort": 443, "protocol": "tcp"}
      ],
      "essential": true,
      "environment": [
        {"name": "PORT", "value": "80"},
        {"name": "MEDIAMTX_URL", "value": "http://3.94.206.123:8888"},
        {"name": "NODE_ENV", "value": "production"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/broadcast",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "broadcast"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 30
      }
    }
  ]' \
  --region us-east-1 > /dev/null

echo "✅ Task definition registered"

echo "🚀 Updating broadcast service with new task definition..."

aws ecs update-service \
  --cluster broadcast-cluster \
  --service broadcast-service \
  --task-definition broadcast-task \
  --force-new-deployment \
  --region us-east-1 > /dev/null

echo "✅ Service updated"
echo ""
echo "⏳ Waiting for deployment to complete (1-2 minutes)..."

aws ecs wait services-stable \
  --cluster broadcast-cluster \
  --services broadcast-service \
  --region us-east-1

echo "✅ Deployment complete! Broadcast should now be able to connect to MediaMTX"
