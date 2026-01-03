#!/bin/bash
# ECS Agent configuration for Amazon Linux 2023 ECS-optimized AMI
exec > /var/log/ecs-startup.log 2>&1
set -x

echo "=== Starting ECS configuration at $(date) ==="

# Configure ECS cluster
mkdir -p /etc/ecs
cat > /etc/ecs/ecs.config <<'ECSCONFIG'
ECS_CLUSTER=broadcast-cluster
ECS_ENABLE_CONTAINER_METADATA=true
ECS_ENABLE_TASK_IAM_ROLE=true
ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true
ECSCONFIG

# Ensure Docker is running (should already be enabled on ECS-optimized AMI)
systemctl enable docker || true
systemctl start docker || true

# Ensure ECS agent is running (should already be enabled on ECS-optimized AMI)
systemctl enable ecs || true
systemctl restart ecs || true

# Wait for ECS agent to start
sleep 5

echo "=== ECS configuration complete at $(date) ==="
echo "Docker status:"
systemctl status docker --no-pager || true
echo "ECS agent status:"
systemctl status ecs --no-pager || true
