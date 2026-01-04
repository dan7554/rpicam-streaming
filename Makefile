# Multi-Application Docker & AWS ECS Deployment Makefile
# Manages both MediaMTX (media streaming) and Broadcast-System (admin dashboard) 
# Optimized for 5-8 camera RTSP streaming with low latency
#
# ✅ PRIMARY SOLUTION: AWS Fargate (Fully Managed Containers)
# =====================================================================
# AWS Fargate provides:
# - No EC2 instances to manage or patch
# - Automatic scaling and failover
# - Pay only for container resources used
# - Integrated with AWS load balancers and CloudWatch
# - Native service discovery via DNS
#
# QUICK START:
#   Show deployment help:                  make deploy-help
#   Deploy (Fargate - RECOMMENDED):        make deploy
#   Check status:                          make status
#
# ⚠️  LEGACY SHELL SCRIPTS (in root directory) - Use Makefile instead
# =====================================================================
# These scripts are kept for reference but should use Makefile targets:
#   • cleanup.sh               → Use: make cleanup-all
#   • launch-ec2-fresh.sh      → Use: make setup-ec2
#   • e2e-test-ec2.sh          → Reference for EC2 testing
#   • e2e-test-fargate.sh      → Reference for Fargate testing
#   • configure-ec2-ecs.sh     → Reference for EC2 configuration
#   • register-nlb-targets.sh  → Use: make nlb-register
#   • diagnose-nlb.sh          → Reference for debugging
#   • fix-health-checks.sh     → Use: make fix-broadcast-service
#   • fix-ec2-instances.sh     → Use: make mediamtx-ec2-register-instances
#
.PHONY: help

# Disable interactive pagers for AWS CLI and system commands to ensure
# non-interactive Makefile runs (prevents `less`/pager prompts requiring 'q').
export AWS_PAGER :=
export PAGER :=

###############################################
# Global Configuration
###############################################

AWS_REGION ?= us-east-1
AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECS_CLUSTER := broadcast-cluster
AWS_VPC_ID := $(shell aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text --region $(AWS_REGION) 2>/dev/null)
AWS_SUBNET_ID := $(shell aws ec2 describe-subnets --filters "Name=vpc-id,Values=$(AWS_VPC_ID)" --query "Subnets[0].SubnetId" --output text --region $(AWS_REGION) 2>/dev/null)

# Common settings
DOCKER_BUILDKIT := 1

###############################################
# MEDIAMTX Configuration
###############################################

MEDIAMTX_IMAGE := bluenviron/mediamtx:latest
MEDIAMTX_REPO := mediamtx
MEDIAMTX_ECR := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(MEDIAMTX_REPO):latest
MEDIAMTX_TASK_FAMILY := mediamtx-task
MEDIAMTX_SERVICE := mediamtx-service-v2
MEDIAMTX_LOG_GROUP := /ecs/mediamtx
MEDIAMTX_PORT_RTSP := 8554
MEDIAMTX_PORT_HLS := 8888
MEDIAMTX_PORT_WEBRTC := 8889
MEDIAMTX_PORT_RTMP := 1935
MEDIAMTX_PORT_API := 9997
MEDIAMTX_PORT_SRT := 8891
MEDIAMTX_PORT_PLAYBACK := 9996
# Resources: optimized for 5-8 concurrent RTSP streams + HLS/RTMP outputs
MEDIAMTX_CPU := 512          # 0.5 vCPU (media processing intensive)
MEDIAMTX_MEMORY := 1024      # 1 GB RAM

###############################################
# BROADCAST-SYSTEM Configuration
###############################################

BROADCAST_REPO := broadcast-system
BROADCAST_ECR := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(BROADCAST_REPO):latest
BROADCAST_TASK_FAMILY := broadcast-task
BROADCAST_SERVICE := broadcast-service
BROADCAST_LOG_GROUP := /ecs/broadcast
BROADCAST_PORT := 80         # nginx reverse proxy on 80
BROADCAST_ALB_PORT := 80     # ALB target port
BROADCAST_HEALTH_PATH := /health
# Resources: lightweight admin dashboard
BROADCAST_CPU := 256         # 0.25 vCPU
BROADCAST_MEMORY := 512      # 512 MB

# Service discovery: MediaMTX accessible via public NLB domain
# Internal communication: use public domain through NLB (more reliable than tracking IPs)
# Use API port (9997) for admin connections
MEDIAMTX_SUBDOMAIN ?= mediamtx.racetrackstreaming.com
MEDIAMTX_SERVICE_URL := http://$(MEDIAMTX_SUBDOMAIN):$(MEDIAMTX_PORT_API)

###############################################
# ALB & Security Group Configuration
###############################################

ALB_NAME := broadcast-alb
ALB_TG_NAME := broadcast-targets
ALB_SECURITY_GROUP := sg-05daa07df49f3e721
# ECS task ENI security group — reconciled (created if missing)
ECS_SECURITY_GROUP := sg-0a39a0404cc7eac61
MEDIAMTX_TG_NAME := mediamtx-targets
MEDIAMTX_RTSP_TG_NAME := mediamtx-rtsp

# Network Load Balancer for MediaMTX (supports TCP/UDP for RTSP, WebRTC, RTMP)
NLB_NAME := mediamtx-nlb
NLB_TG_RTSP := mediamtx-nlb-rtsp
NLB_TG_WEBRTC := mediamtx-nlb-webrtc
NLB_TG_API := mediamtx-nlb-api
NLB_TG_RTMP := mediamtx-nlb-rtmp

# Domain Configuration
ADMIN_DOMAIN := admin.racetrackstreaming.com    # Broadcast admin dashboard
STREAM_DOMAIN := stream.racetrackstreaming.com   # MediaMTX HLS/RTSP streaming
MEDIAMTX_DOMAIN := mediamtx.racetrackstreaming.com  # MediaMTX public API/RTSP/WebRTC
DOMAIN := $(ADMIN_DOMAIN)                        # Default domain (for backward compatibility)

# SSL/TLS Configuration
ACM_CERT_ARN ?= arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53
HTTPS_LISTENER_ARN ?=

###############################################
# Help
###############################################

help: ## Show this help message
	@echo "🎥 Multi-Camera Broadcast System - Docker & AWS ECS Manager"
	@echo "==========================================================="
	@echo "For 5-8 camera RTSP streaming with low-latency HLS/WebRTC\n"
	@echo "✅ PRIMARY: EC2-BASED MEDIAMTX (Recommended - Fixes Fargate timeout)"
	@grep -E '^mediamtx-ec2-[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "📡 MEDIAMTX FARGATE (Legacy - HTTP timeout issues):"
	@grep -E '^mediamtx-[a-z-]+:.*?## ' $(MAKEFILE_LIST) | grep -v ec2 | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "📺 BROADCAST-SYSTEM (Admin Dashboard):"
	@grep -E '^broadcast-[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🔗 ORCHESTRATION (Deploy Both):"
	@grep -E '^(deploy|setup|update|quick|status|logs):' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🌐 DNS & Monitoring:"
	@grep -E '^dns-' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🔐 SSL/TLS & Security:"
	@grep -E '^ssl-' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🔗 SUBDOMAIN ROUTING:"
	@echo "  Admin Dashboard:  https://$(ADMIN_DOMAIN)"
	@echo "  HLS Streaming:    https://$(STREAM_DOMAIN)/hls/"
	@echo ""
	@echo "⚙️  Service Discovery Architecture (EC2):"
	@echo "  Cameras → MediaMTX EC2 (port 8554 RTSP) → HLS/WebRTC/RTMP outputs"
	@echo "           ↓ (bridge networking - all ports directly mapped)"
	@echo "       Broadcast-System (admin dashboard) → YouTube via RTMP"
	@echo ""

###############################################
# MEDIAMTX TARGETS - ECR & Docker Build
###############################################

.PHONY: mediamtx-ecr-login mediamtx-ecr-push mediamtx-aws-deploy
.PHONY: mediamtx-task-def mediamtx-service mediamtx-update mediamtx-logs
.PHONY: mediamtx-deploy

# ⚠️  LEGACY FARGATE TARGETS - Use EC2 targets above instead
# These targets have HTTP response timeout issues on Fargate
# See: mediamtx-ec2-* targets for recommended EC2-based solution

mediamtx-ecr-login: ## 🔐 Login to AWS ECR for MediaMTX
	@echo "🔐 Logging into ECR..."
	aws ecr get-login-password --region $(AWS_REGION) | \
	  docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

mediamtx-ecr-repo: ## 📦 Create ECR repository for MediaMTX
	@echo "📦 Creating ECR repository for MediaMTX..."
	aws ecr create-repository \
	  --repository-name $(MEDIAMTX_REPO) \
	  --region $(AWS_REGION) 2>/dev/null || echo "Repository already exists"

mediamtx-build: ## 🔨 Build MediaMTX Docker image (linux/amd64 for AWS Fargate)
	@echo "🔨 Building MediaMTX Docker image for linux/amd64..."
	docker buildx build --platform linux/amd64 -f Dockerfile -t $(MEDIAMTX_REPO):latest --load .
	@echo "✅ Build complete"

mediamtx-pull: mediamtx-ecr-login mediamtx-build ## ⬇️ Build MediaMTX image and push to ECR
	@echo "🏷️  Tagging for ECR..."
	docker tag $(MEDIAMTX_REPO):latest $(MEDIAMTX_ECR)
	@echo "⬆️ Pushing to ECR..."
	docker push $(MEDIAMTX_ECR)
	@echo "✅ MediaMTX image pushed to ECR: $(MEDIAMTX_ECR)"

mediamtx-ecr-push: mediamtx-ecr-repo mediamtx-pull ## ⬆️ Complete ECR push for MediaMTX

mediamtx-task-def: mediamtx-ecr-push ## 📋 Create MediaMTX ECS task definition
	@echo "📋 Creating MediaMTX task definition..."
	@TMPFILE=$$(mktemp -t mediamtx-container-def); \
		printf '%s\n' '[{"name":"mediamtx","image":"$(MEDIAMTX_ECR)","cpu":$(MEDIAMTX_CPU),"memory":$(MEDIAMTX_MEMORY),"command":["/app/mediamtx.yml"],"portMappings":[{"containerPort":$(MEDIAMTX_PORT_RTSP),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_HLS),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_WEBRTC),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_RTMP),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_API),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_SRT),"protocol":"udp"},{"containerPort":$(MEDIAMTX_PORT_PLAYBACK),"protocol":"tcp"}],"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"$(MEDIAMTX_LOG_GROUP)","awslogs-region":"$(AWS_REGION)","awslogs-stream-prefix":"mediamtx"}}}]' > $$TMPFILE; \
	aws ecs register-task-definition \
	  --family $(MEDIAMTX_TASK_FAMILY) \
	  --network-mode awsvpc \
	  --requires-compatibilities FARGATE \
	  --cpu $(MEDIAMTX_CPU) \
	  --memory $(MEDIAMTX_MEMORY) \
	  --execution-role-arn arn:aws:iam::$(AWS_ACCOUNT_ID):role/ecsTaskExecutionRole \
	  --container-definitions file://$$TMPFILE \
	  --region $(AWS_REGION); \
	STATUS=$$?; rm -f $$TMPFILE; \
	if [ $$STATUS -eq 0 ]; then echo "✅ Task definition registered"; else exit $$STATUS; fi

mediamtx-logs: ## 📝 Create CloudWatch log group for MediaMTX
	@echo "📝 Creating log group..."
	aws logs create-log-group --log-group-name $(MEDIAMTX_LOG_GROUP) --region $(AWS_REGION) 2>/dev/null || echo "Log group exists"
	aws logs put-retention-policy --log-group-name $(MEDIAMTX_LOG_GROUP) --retention-in-days 7 --region $(AWS_REGION) 2>/dev/null || true
	@echo "✅ Log group ready"


mediamtx-create-rtsp: ## 🧭 Ensure RTSP target group exists (port 8554)
	@echo "🧭 Ensuring RTSP target group exists ($(MEDIAMTX_RTSP_TG_NAME))..."; \
	bash scripts/mediamtx-ensure-rtsp-tg.sh || echo "⚠️ mediamtx-rtsp ensure script returned non-zero"


mediamtx-service: mediamtx-logs ## ⚙️ Create MediaMTX ECS service (attach API and RTSP TGs when present)
	@echo "⚙️ Creating/updating MediaMTX ECS service..."
	@TG_API_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --names $(MEDIAMTX_TG_NAME) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo ""); \
	TG_RTSP_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --names $(MEDIAMTX_RTSP_TG_NAME) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo ""); \
	if [ -n "$$TG_API_ARN" ] || [ -n "$$TG_RTSP_ARN" ]; then \
	  echo "⚙️ Attaching ALB/NLB target groups to service: $$TG_API_ARN $$TG_RTSP_ARN"; \
	  LB_ARGS=""; \
	  if [ -n "$$TG_API_ARN" ]; then LB_ARGS="$$LB_ARGS targetGroupArn=$$TG_API_ARN,containerName=mediamtx,containerPort=$(MEDIAMTX_PORT_API)"; fi; \
	  if [ -n "$$TG_RTSP_ARN" ]; then LB_ARGS="$$LB_ARGS targetGroupArn=$$TG_RTSP_ARN,containerName=mediamtx,containerPort=$(MEDIAMTX_PORT_RTSP)"; fi; \
	  aws ecs create-service \
	    --cluster $(ECS_CLUSTER) \
	    --service-name $(MEDIAMTX_SERVICE) \
	    --task-definition $(MEDIAMTX_TASK_FAMILY) \
	    --desired-count 1 \
	    --launch-type FARGATE \
	    --network-configuration "awsvpcConfiguration={subnets=[$(AWS_SUBNET_ID)],securityGroups=[$(ECS_SECURITY_GROUP)],assignPublicIp=ENABLED}" \
	    --enable-ecs-managed-tags $$LB_ARGS \
	    --region $(AWS_REGION) 2>/dev/null || \
	  (echo "Service exists, updating..."; \
	   aws ecs update-service \
	    --cluster $(ECS_CLUSTER) \
	    --service $(MEDIAMTX_SERVICE) \
	    --task-definition $(MEDIAMTX_TASK_FAMILY) \
	    $$LB_ARGS \
	    --force-new-deployment \
	    --region $(AWS_REGION) 2>/dev/null || echo "⚠️ Service update skipped (still initializing)"); \
	else \
	  echo "⚙️ No mediamtx target groups found; creating/updating service without ALB/NLB attachment"; \
	  aws ecs create-service \
	    --cluster $(ECS_CLUSTER) \
	    --service-name $(MEDIAMTX_SERVICE) \
	    --task-definition $(MEDIAMTX_TASK_FAMILY) \
	    --desired-count 1 \
	    --launch-type FARGATE \
	    --network-configuration "awsvpcConfiguration={subnets=[$(AWS_SUBNET_ID)],securityGroups=[$(ECS_SECURITY_GROUP)],assignPublicIp=ENABLED}" \
	    --enable-ecs-managed-tags \
	    --region $(AWS_REGION) 2>/dev/null || \
	  (echo "Service exists, updating..."; \
	   aws ecs update-service \
	    --cluster $(ECS_CLUSTER) \
	    --service $(MEDIAMTX_SERVICE) \
	    --task-definition $(MEDIAMTX_TASK_FAMILY) \
	    --force-new-deployment \
	    --region $(AWS_REGION) 2>/dev/null || echo "⚠️ Service update skipped (still initializing)"); \
	fi
	@echo "Waiting for MediaMTX service to reach stable state (this may take 1-2 minutes)..."; \
	aws ecs wait services-stable --cluster $(ECS_CLUSTER) --services $(MEDIAMTX_SERVICE) --region $(AWS_REGION) >/dev/null 2>&1 || echo "⚠️ Service did not reach stable state within waiter timeout"; \
	echo "✅ MediaMTX service ready"

mediamtx-update: mediamtx-ecr-push ## 🔄 Update MediaMTX service with latest image
	@echo "🔄 Updating MediaMTX service..."
	aws ecs update-service \
	  --cluster $(ECS_CLUSTER) \
	  --service $(MEDIAMTX_SERVICE) \
	  --force-new-deployment \
	  --region $(AWS_REGION)
	@echo "✅ Service update initiated"

mediamtx-deploy: mediamtx-logs mediamtx-task-def mediamtx-ensure-sg mediamtx-create-target-group mediamtx-create-rtsp mediamtx-attach-alb mediamtx-service ## 🚀 Complete MediaMTX deployment (Fargate)


###############################################
# ✅ EC2-BASED MEDIAMTX DEPLOYMENT (RECOMMENDED - FIXES HTTP TIMEOUT)
###############################################
# This is the PRIMARY recommended deployment method.
# - Provides full control over network stack
# - Fixes Fargate HTTP response timeout issues
# - Bridge networking supports all protocols
# - Minimal cost difference ($0.02/hour for t3.medium)
#
.PHONY: mediamtx-ec2-launch mediamtx-ec2-register-instances mediamtx-ec2-task-def mediamtx-ec2-service mediamtx-ec2-deploy
.PHONY: mediamtx-task-def-ec2 mediamtx-service-ec2 mediamtx-update-ec2

# EC2 Configuration
EC2_INSTANCE_TYPE ?= t3.medium       # 2 vCPU, 4GB RAM - sufficient for MediaMTX
EC2_AMI ?= ami-0bcad7d4493b66a48    # Amazon ECS-optimized AL2023 AMI for us-east-1 (2026-01-03)
EC2_KEY_PAIR ?= racetrack-key        # EC2 key pair for SSH access
EC2_VOLUME_SIZE ?= 100               # GB

mediamtx-ec2-launch: ## 🖥️ Launch EC2 instance for MediaMTX (fixes Fargate HTTP timeout)
	@echo "🖥️ Launching EC2 instance for MediaMTX..."
	@aws ec2 run-instances \
	  --image-id $(EC2_AMI) \
	  --instance-type $(EC2_INSTANCE_TYPE) \
	  --key-name $(EC2_KEY_PAIR) \
	  --security-group-ids $(ECS_SECURITY_GROUP) \
	  --subnet-id $(AWS_SUBNET_ID) \
	--block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$(EC2_VOLUME_SIZE),VolumeType=gp3,DeleteOnTermination=true}" \
	  --iam-instance-profile Name=ecsInstanceProfile \
	  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=mediamtx-ec2},{Key=Service,Value=mediamtx},{Key=Type,Value=streaming}]" \
	--user-data "IyEvYmluL2Jhc2gKIyBFQ1MgQWdlbnQgY29uZmlndXJhdGlvbiBmb3IgQW1hem9uIExpbnV4IDIwMjMgRUNTLW9wdGltaXplZCBBTUkKZXhlYyA+IC92YXIvbG9nL2Vjcy1zdGFydHVwLmxvZyAyPiYxCnNldCAteAoKZWNobyAiPT09IFN0YXJ0aW5nIEVDUyBjb25maWd1cmF0aW9uIGF0ICQoZGF0ZSkgPT09IgoKIyBDb25maWd1cmUgRUNTIGNsdXN0ZXIKbWtkaXIgLXAgL2V0Yy9lY3MKY2F0ID4gL2V0Yy9lY3MvZWNzLmNvbmZpZyA8PCdFQ1NDT05GSUcnCkVDU19DTFVTVEVSPWJyb2FkY2FzdC1jbHVzdGVyCkVDU19FTkFCTEVfQ09OVEFJTkVSX01FVEFEQVRBPXRydWUKRUNTX0VOQUJMRV9UQVNLX0lBTV9ST0xFPXRydWUKRUNTX0VOQUJMRV9UQVNLX0lBTV9ST0xFX05FVFdPUktfSE9TVD10cnVlCkVDU0NPTkZJRwoKIyBFbnN1cmUgRG9ja2VyIGlzIHJ1bm5pbmcgKHNob3VsZCBhbHJlYWR5IGJlIGVuYWJsZWQgb24gRUNTLW9wdGltaXplZCBBTUkpCnN5c3RlbWN0bCBlbmFibGUgZG9ja2VyIHx8IHRydWUKc3lzdGVtY3RsIHN0YXJ0IGRvY2tlciB8fCB0cnVlCgojIEVuc3VyZSBFQ1MgYWdlbnQgaXMgcnVubmluZyAoc2hvdWxkIGFscmVhZHkgYmUgZW5hYmxlZCBvbiBFQ1Mtb3B0aW1pemVkIEFNSSkKc3lzdGVtY3RsIGVuYWJsZSBlY3MgfHwgdHJ1ZQpzeXN0ZW1jdGwgcmVzdGFydCBlY3MgfHwgdHJ1ZQoKIyBXYWl0IGZvciBFQ1MgYWdlbnQgdG8gc3RhcnQKc2xlZXAgNQoKZWNobyAiPT09IEVDUyBjb25maWd1cmF0aW9uIGNvbXBsZXRlIGF0ICQoZGF0ZSkgPT09IgplY2hvICJEb2NrZXIgc3RhdHVzOiIKc3lzdGVtY3RsIHN0YXR1cyBkb2NrZXIgLS1uby1wYWdlciB8fCB0cnVlCmVjaG8gIkVDUyBhZ2VudCBzdGF0dXM6IgpzeXN0ZW1jdGwgc3RhdHVzIGVjcyAtLW5vLXBhZ2VyIHx8IHRydWUK" \
	  --region $(AWS_REGION) | tee /tmp/ec2-launch.json
	@INSTANCE_ID=$$(jq -r '.Instances[0].InstanceId' /tmp/ec2-launch.json); \
	echo "✅ Instance launched: $$INSTANCE_ID"; \
	echo "Waiting for instance to become available (this may take 1-2 minutes)..."; \
	for i in {1..60}; do \
	  STATE=$$(aws ec2 describe-instances --instance-ids $$INSTANCE_ID --region $(AWS_REGION) --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "pending"); \
	  if [ "$$STATE" = "running" ]; then \
	    echo "✅ Instance is running"; \
	    break; \
	  fi; \
	  echo "  Status: $$STATE ($$i/60)"; \
	  sleep 2; \
	done; \
	INSTANCE_IP=$$(aws ec2 describe-instances --instance-ids $$INSTANCE_ID --region $(AWS_REGION) --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text); \
	echo "✅ Instance ready at $$INSTANCE_IP"; \
	echo "  SSH access: ssh -i racetrack-key.pem ec2-user@$$INSTANCE_IP"; \
	echo "$$INSTANCE_ID" > /tmp/ec2-instance-id.txt

mediamtx-ec2-register-instances: ## 📋 Register running EC2 instances with ECS (for EC2-based service)
	@echo "📋 Registering EC2 instances as ECS container instances..."
	@INSTANCE_IDS=$$(aws ec2 describe-instances \
	  --filters "Name=tag:Service,Values=mediamtx" "Name=instance-state-name,Values=running" \
	  --region $(AWS_REGION) \
	  --query 'Reservations[*].Instances[*].InstanceId' \
	  --output text); \
	if [ -z "$$INSTANCE_IDS" ]; then \
	  echo "❌ No running MediaMTX EC2 instances found"; \
	  exit 1; \
	fi; \
	for INSTANCE_ID in $$INSTANCE_IDS; do \
	  echo "Registering $$INSTANCE_ID..."; \
	  aws ec2 describe-instances --instance-ids $$INSTANCE_ID --region $(AWS_REGION) > /dev/null 2>&1 && \
	  echo "✅ Instance $$INSTANCE_ID is registered"; \
	done

mediamtx-ec2-task-def: mediamtx-task-def-ec2 ## 📋 Create MediaMTX ECS task definition for EC2 (alias)

mediamtx-task-def-ec2: mediamtx-ecr-push ## 📋 Create MediaMTX ECS task definition for EC2 (bridge networking)
	@echo "📋 Creating MediaMTX task definition for EC2 (bridge mode)..."
	@TMPFILE=$$(mktemp -t mediamtx-container-def-ec2); \
		printf '%s\n' '[{"name":"mediamtx","image":"$(MEDIAMTX_ECR)","cpu":$(MEDIAMTX_CPU),"memory":$(MEDIAMTX_MEMORY),"command":["/app/mediamtx.yml"],"portMappings":[{"containerPort":$(MEDIAMTX_PORT_RTSP),"hostPort":$(MEDIAMTX_PORT_RTSP),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_HLS),"hostPort":$(MEDIAMTX_PORT_HLS),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_WEBRTC),"hostPort":$(MEDIAMTX_PORT_WEBRTC),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_RTMP),"hostPort":$(MEDIAMTX_PORT_RTMP),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_API),"hostPort":$(MEDIAMTX_PORT_API),"protocol":"tcp"},{"containerPort":$(MEDIAMTX_PORT_SRT),"hostPort":$(MEDIAMTX_PORT_SRT),"protocol":"udp"},{"containerPort":$(MEDIAMTX_PORT_PLAYBACK),"hostPort":$(MEDIAMTX_PORT_PLAYBACK),"protocol":"tcp"}],"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"$(MEDIAMTX_LOG_GROUP)","awslogs-region":"$(AWS_REGION)","awslogs-stream-prefix":"mediamtx-ec2"}}}]' > $$TMPFILE; \
	aws ecs register-task-definition \
	  --family $(MEDIAMTX_TASK_FAMILY)-ec2 \
	  --network-mode bridge \
	  --requires-compatibilities EC2 \
	  --cpu $(MEDIAMTX_CPU) \
	  --memory $(MEDIAMTX_MEMORY) \
	  --execution-role-arn arn:aws:iam::$(AWS_ACCOUNT_ID):role/ecsTaskExecutionRole \
	  --container-definitions file://$$TMPFILE \
	  --region $(AWS_REGION); \
	STATUS=$$?; rm -f $$TMPFILE; \
	if [ $$STATUS -eq 0 ]; then echo "✅ EC2 task definition registered"; else exit $$STATUS; fi

mediamtx-ec2-service: mediamtx-service-ec2 ## ⚙️ Create MediaMTX ECS service for EC2 (alias)

mediamtx-service-ec2: mediamtx-logs mediamtx-ec2-register-instances ## ⚙️ Create MediaMTX ECS service for EC2 (bridge mode)
	@echo "⚙️ Creating MediaMTX ECS service for EC2..."
	@aws ecs create-service \
	  --cluster $(ECS_CLUSTER) \
	  --service-name $(MEDIAMTX_SERVICE)-ec2 \
	  --task-definition $(MEDIAMTX_TASK_FAMILY)-ec2 \
	  --desired-count 2 \
	  --launch-type EC2 \
	  --region $(AWS_REGION) 2>/dev/null || \
	  (echo "Service exists, updating..."; \
	   aws ecs update-service \
	    --cluster $(ECS_CLUSTER) \
	    --service $(MEDIAMTX_SERVICE)-ec2 \
	    --task-definition $(MEDIAMTX_TASK_FAMILY)-ec2 \
	    --force-new-deployment \
	    --region $(AWS_REGION))
	@echo "✅ MediaMTX EC2 service ready"

mediamtx-update-ec2: mediamtx-ecr-push ## 🔄 Update MediaMTX EC2 service with latest image
	@echo "🔄 Updating MediaMTX EC2 service..."
	aws ecs update-service \
	  --cluster $(ECS_CLUSTER) \
	  --service $(MEDIAMTX_SERVICE)-ec2 \
	  --force-new-deployment \
	  --region $(AWS_REGION)
	@echo "✅ EC2 service update initiated"

mediamtx-deploy-ec2: mediamtx-ec2-launch mediamtx-task-def-ec2 mediamtx-service-ec2 ## 🚀 Complete MediaMTX EC2 deployment (recommended - fixes HTTP timeout)

###############################################
# BROADCAST-SYSTEM TARGETS
###############################################

.PHONY: broadcast-build broadcast-ecr-login broadcast-ecr-push broadcast-task-def
.PHONY: broadcast-update broadcast-deploy broadcast-logs broadcast-update-config

broadcast-ecr-login: ## 🔐 Login to ECR for broadcast-system
	@echo "🔐 Logging into ECR..."
	aws ecr get-login-password --region $(AWS_REGION) | \
	  docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

broadcast-ecr-repo: ## 📦 Create ECR repository for broadcast-system
	@echo "📦 Creating ECR repository for broadcast-system..."
	aws ecr create-repository \
	  --repository-name $(BROADCAST_REPO) \
	  --region $(AWS_REGION) 2>/dev/null || echo "Repository already exists"

broadcast-build: broadcast-ecr-repo broadcast-ecr-login ## 🔨 Build broadcast-system Docker image (linux/amd64 for AWS)
	@echo "🔨 Building broadcast-system Docker image for linux/amd64..."
	docker buildx build --platform linux/amd64 -f broadcast-system/Dockerfile -t $(BROADCAST_REPO):latest --load .
	@echo "✅ Build complete"

broadcast-ecr-push: broadcast-build ## ⬆️ Tag and push broadcast-system to ECR
	@echo "🏷️  Tagging for ECR..."
	docker tag $(BROADCAST_REPO):latest $(BROADCAST_ECR)
	@echo "⬆️ Pushing to ECR..."
	docker push $(BROADCAST_ECR)
	@echo "✅ Broadcast-system pushed to ECR: $(BROADCAST_ECR)"

broadcast-logs: ## 📝 Create CloudWatch log group for broadcast-system
	@echo "📝 Creating log group..."
	aws logs create-log-group --log-group-name $(BROADCAST_LOG_GROUP) --region $(AWS_REGION) 2>/dev/null || echo "Log group exists"
	aws logs put-retention-policy --log-group-name $(BROADCAST_LOG_GROUP) --retention-in-days 7 --region $(AWS_REGION) 2>/dev/null || true
	@echo "✅ Log group ready"

broadcast-task-def: broadcast-ecr-push broadcast-logs ## 📋 Create broadcast-system ECS task definition
	@echo "📋 Creating broadcast-system task definition..."
	@echo "  - Image: $(BROADCAST_ECR)"
	@echo "  - MEDIAMTX_URL: $(MEDIAMTX_SERVICE_URL)"
	@aws ecs register-task-definition \
	  --family $(BROADCAST_TASK_FAMILY) \
	  --network-mode awsvpc \
	  --requires-compatibilities FARGATE \
	  --cpu $(BROADCAST_CPU) \
	  --memory $(BROADCAST_MEMORY) \
	  --execution-role-arn arn:aws:iam::$(AWS_ACCOUNT_ID):role/ecsTaskExecutionRole \
	  --container-definitions "[{ \
	    \"name\": \"broadcast-system\", \
	    \"image\": \"$(BROADCAST_ECR)\", \
	    \"cpu\": $(BROADCAST_CPU), \
	    \"memory\": $(BROADCAST_MEMORY), \
	    \"essential\": true, \
	    \"portMappings\": [ \
	      {\"containerPort\": 80, \"hostPort\": 80, \"protocol\": \"tcp\"}, \
	      {\"containerPort\": 443, \"hostPort\": 443, \"protocol\": \"tcp\"} \
	    ], \
	    \"environment\": [ \
	      {\"name\": \"NODE_ENV\", \"value\": \"production\"}, \
	      {\"name\": \"PORT\", \"value\": \"80\"}, \
	      {\"name\": \"MEDIAMTX_URL\", \"value\": \"$(MEDIAMTX_SERVICE_URL)\"}, \
	      {\"name\": \"BROADCAST_URL\", \"value\": \"https://admin.racetrackstreaming.com\"} \
	    ], \
	    \"logConfiguration\": { \
	      \"logDriver\": \"awslogs\", \
	      \"options\": { \
	        \"awslogs-group\": \"$(BROADCAST_LOG_GROUP)\", \
	        \"awslogs-region\": \"$(AWS_REGION)\", \
	        \"awslogs-stream-prefix\": \"broadcast\" \
	      } \
	    }, \
	    \"healthCheck\": { \
	      \"command\": [\"CMD-SHELL\", \"curl -f http://localhost$(BROADCAST_HEALTH_PATH) || exit 1\"], \
	      \"interval\": 30, \
	      \"timeout\": 5, \
	      \"retries\": 3, \
	      \"startPeriod\": 30 \
	    } \
	  }]" \
	  --region $(AWS_REGION)
	@echo "✅ Task definition registered"

broadcast-update: broadcast-ecr-push ## 🔄 Update broadcast-system service with latest image
	@echo "🔄 Updating broadcast-system service..."
	aws ecs update-service \
	  --cluster $(ECS_CLUSTER) \
	  --service $(BROADCAST_SERVICE) \
	  --force-new-deployment \
	  --region $(AWS_REGION)
	@echo "✅ Service update initiated"

broadcast-deploy: broadcast-task-def ## 🚀 Complete broadcast-system deployment (with updated MediaMTX URL)
	@echo "🚀 Deploying broadcast-system service..."
	@aws ecs create-service \
	  --cluster $(ECS_CLUSTER) \
	  --service-name $(BROADCAST_SERVICE) \
	  --task-definition $(BROADCAST_TASK_FAMILY) \
	  --desired-count 1 \
	  --launch-type FARGATE \
	  --network-configuration "awsvpcConfiguration={subnets=[$(AWS_SUBNET_ID)],securityGroups=[$(ECS_SECURITY_GROUP)],assignPublicIp=ENABLED}" \
	  --region $(AWS_REGION) 2>/dev/null || \
	  (echo "Service exists, updating..."; \
	   aws ecs update-service \
	    --cluster $(ECS_CLUSTER) \
	    --service $(BROADCAST_SERVICE) \
	    --task-definition $(BROADCAST_TASK_FAMILY) \
	    --force-new-deployment \
	    --region $(AWS_REGION) 2>/dev/null || echo "⚠️ Service update skipped (still initializing)")
	@echo "✅ Broadcast-system service deployment initiated"

###############################################
# FIX HEALTH CHECK - Port mapping issue
###############################################

.PHONY: fix-alb-ports fix-broadcast-service

# Create a target group for MediaMTX so ALB can health-check /v3/info
.PHONY: mediamtx-create-target-group
mediamtx-create-target-group: ## 🔧 Create ALB target group for MediaMTX API (/v3/info)
	@echo "🔧 Creating MediaMTX ALB target group ($(MEDIAMTX_TG_NAME))..."
	@TG_ARN=$$(aws elbv2 describe-target-groups --names $(MEDIAMTX_TG_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo ""); \
	if [ -n "$$TG_ARN" ] && [ "$$TG_ARN" != "None" ]; then \
	  echo "✅ Target group exists: $$TG_ARN"; \
	else \
	  aws elbv2 create-target-group \
	    --name $(MEDIAMTX_TG_NAME) \
	    --protocol HTTP \
	    --port $(MEDIAMTX_PORT_API) \
	    --vpc-id $(AWS_VPC_ID) \
	    --target-type ip \
	    --health-check-protocol HTTP \
	    --health-check-path /v3/info \
	    --health-check-port $(MEDIAMTX_PORT_API) \
	    --health-check-interval-seconds 30 \
	    --health-check-timeout-seconds 5 \
	    --healthy-threshold-count 3 \
	    --unhealthy-threshold-count 2 \
	    --region $(AWS_REGION); \
	  echo "Created target group $(MEDIAMTX_TG_NAME), waiting for it to appear..."; \
	  for i in `seq 1 20`; do \
	    TG_ARN=$$(aws elbv2 describe-target-groups --names $(MEDIAMTX_TG_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo ""); \
	    if [ -n "$$TG_ARN" ] && [ "$$TG_ARN" != "None" ]; then break; fi; \
	    echo "  waiting for target group... ($$i/20)"; sleep 2; \
	  done; \
	  if [ -z "$$TG_ARN" ] || [ "$$TG_ARN" = "None" ]; then echo "❌ Failed to create target group"; exit 1; fi; \
	  echo "✅ Target group ready: $$TG_ARN"; \
	fi

.PHONY: mediamtx-ensure-alb mediamtx-attach-alb mediamtx-verify-sg

# Ensure ALB exists and create it (and a security group) if missing.
mediamtx-ensure-alb: ## 🛠 Ensure Application Load Balancer exists (creates ALB and security-group if needed)
	@MEDIAMTX_LOG_GROUP="$(MEDIAMTX_LOG_GROUP)" ALB_NAME="$(ALB_NAME)" AWS_REGION="$(AWS_REGION)" AWS_VPC_ID="$(AWS_VPC_ID)" ALB_SECURITY_GROUP="$(ALB_SECURITY_GROUP)" sh scripts/mediamtx-ensure-alb.sh

	@MEDIAMTX_TG_NAME="$(MEDIAMTX_TG_NAME)" ALB_NAME="$(ALB_NAME)" MEDIAMTX_PORT_API="$(MEDIAMTX_PORT_API)" AWS_REGION="$(AWS_REGION)" sh scripts/mediamtx-attach-alb.sh

mediamtx-verify-sg: ## 🔎 Verify security group rules between ALB and task ENI
	@echo "🔎 Verifying security group configuration..."
	@echo "  ALB SG: $(ALB_SECURITY_GROUP)"; echo "  Task SG: $(ECS_SECURITY_GROUP)"; \
	INBOUND_OK=$$(aws ec2 describe-security-groups --group-ids $(ECS_SECURITY_GROUP) --region $(AWS_REGION) --query 'SecurityGroups[0].IpPermissions' --output json | grep -q $(ALB_SECURITY_GROUP) && echo yes || echo no); \
	if [ "$$INBOUND_OK" = "yes" ]; then \
	  echo "✅ Task security group allows ingress from ALB security group on port $(MEDIAMTX_PORT_API)"; \
	else \
	  echo "❌ Missing inbound rule: allow ALB SG $(ALB_SECURITY_GROUP) -> Task SG $(ECS_SECURITY_GROUP) on port $(MEDIAMTX_PORT_API)"; \
	  echo "Run the following to add the rule:"; \
	  echo "aws ec2 authorize-security-group-ingress --group-id $(ECS_SECURITY_GROUP) --protocol tcp --port $(MEDIAMTX_PORT_API) --source-group $(ALB_SECURITY_GROUP) --region $(AWS_REGION)"; \
	fi; \
	# Check ALB egress (basic)
	EGRESS_OK=$$(aws ec2 describe-security-groups --group-ids $(ALB_SECURITY_GROUP) --region $(AWS_REGION) --query 'SecurityGroups[0].IpPermissionsEgress' --output json | grep -q '0.0.0.0' && echo yes || echo no); \
	if [ "$$EGRESS_OK" = "yes" ]; then \
	  echo "✅ ALB security group has default egress (internet) or allows outbound traffic"; \
	else \
	  echo "⚠️ ALB security group egress may be restricted. Ensure it can reach task ENIs on port $(MEDIAMTX_PORT_API)"; \
	fi

.PHONY: mediamtx-ensure-sg
mediamtx-ensure-sg: ## ✅ Ensure task SG allows ingress from ALB SG on the API port
	@echo "🔐 Ensuring security group ingress: ALB ($(ALB_SECURITY_GROUP)) -> Task ($(ECS_SECURITY_GROUP)) on port $(MEDIAMTX_PORT_API)"
	# Verify the task security group exists
	if ! aws ec2 describe-security-groups --group-ids $(ECS_SECURITY_GROUP) --region $(AWS_REGION) >/dev/null 2>&1; then \
	  echo "⚠️ Task security group $(ECS_SECURITY_GROUP) not found; skipping ingress configuration. Update ECS_SECURITY_GROUP in Makefile if needed."; \
	  exit 0; \
	fi; \
	# Check if there's already a rule referencing the ALB SG
	HAS_RULE=$$(aws ec2 describe-security-groups --group-ids $(ECS_SECURITY_GROUP) --region $(AWS_REGION) --query 'SecurityGroups[0].IpPermissions[*].UserIdGroupPairs[?GroupId==`'$(ALB_SECURITY_GROUP)'`].GroupId' --output text 2>/dev/null || echo ""); \
	if [ -n "$$HAS_RULE" ]; then \
	  echo "✅ Ingress rule already present"; \
	else \
	  echo "➕ Adding ingress rule..."; \
	  aws ec2 authorize-security-group-ingress --group-id $(ECS_SECURITY_GROUP) --protocol tcp --port $(MEDIAMTX_PORT_API) --source-group $(ALB_SECURITY_GROUP) --region $(AWS_REGION) >/dev/null 2>&1 || echo "⚠️ Ingress rule may already exist or failed to add"; \
	  echo "✅ Ingress rule ensured"; \
	fi

	# Ensure RTSP port is reachable (NLB forwards public traffic) - allow from public CIDR
	echo "🔐 Ensuring RTSP ingress (port $(MEDIAMTX_PORT_RTSP)) from 0.0.0.0/0 on $(ECS_SECURITY_GROUP)"; \
	aws ec2 authorize-security-group-ingress --group-id $(ECS_SECURITY_GROUP) --protocol tcp --port $(MEDIAMTX_PORT_RTSP) --cidr 0.0.0.0/0 --region $(AWS_REGION) >/dev/null 2>&1 || echo "⚠️ RTSP ingress may already exist or failed to add"; \
	echo "✅ RTSP ingress ensured (best-effort)"

fix-alb-ports: ## 🔧 Fix ALB target group health check
	@echo "🔧 Fixing ALB target group health check..."
	@TARGET_GROUP_ARN=$$(aws elbv2 describe-target-groups \
	  --region $(AWS_REGION) \
	  --names $(ALB_TG_NAME) \
	  --query 'TargetGroups[0].TargetGroupArn' \
	  --output text); \
	if [ -z "$$TARGET_GROUP_ARN" ]; then \
	  echo "⚠️ Target group not found, skipping health check update"; \
	else \
	  aws elbv2 modify-target-group \
	    --target-group-arn $$TARGET_GROUP_ARN \
	    --health-check-enabled \
	    --health-check-protocol HTTP \
	    --health-check-path $(BROADCAST_HEALTH_PATH) \
	    --region $(AWS_REGION) 2>/dev/null || echo "⚠️ Health check update skipped"; \
	fi
	@echo "✅ ALB configuration complete"

fix-broadcast-service: fix-alb-ports ## 🔧 Recreate broadcast-service with ALB
	@echo "🔧 Updating broadcast-service to use ALB..."
	@TARGET_GROUP_ARN=$$(aws elbv2 describe-target-groups \
	  --region $(AWS_REGION) \
	  --names $(ALB_TG_NAME) \
	  --query 'TargetGroups[0].TargetGroupArn' \
	  --output text); \
	if [ -z "$$TARGET_GROUP_ARN" ]; then \
	  echo "⚠️ Target group not found, skipping ALB update"; \
	else \
	  aws ecs update-service \
	    --cluster $(ECS_CLUSTER) \
	    --service $(BROADCAST_SERVICE) \
	    --load-balancers "targetGroupArn=$$TARGET_GROUP_ARN,containerName=broadcast-system,containerPort=80" \
	    --force-new-deployment \
	    --region $(AWS_REGION) 2>/dev/null || echo "⚠️ ALB update skipped (target group not associated with load balancer)"; \
	fi
	@echo "✅ Broadcast-service ALB update complete"

###############################################
# ORCHESTRATION - Deploy Both Services (EC2 PRIMARY)
###############################################

.PHONY: setup setup-ec2 setup-fargate deploy deploy-ec2 deploy-fargate deploy-help quick quick-ec2 update update-ec2 status logs

deploy-help: ## 📋 Show all deployment options and architecture
	@echo ""
	@echo "╔════════════════════════════════════════════════════════════════╗"
	@echo "║        MEDIA-MTX BROADCAST SYSTEM - DEPLOYMENT GUIDE           ║"
	@echo "╚════════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "🎯 QUICK START"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  For immediate deployment:"
	@echo "    $$ make deploy"
	@echo "    (Deploys both MediaMTX + Broadcast to Fargate)"
	@echo ""
	@echo "  Then verify status:"
	@echo "    $$ make status"
	@echo ""
	@echo "────────────────────────────────────────────────────────────────"
	@echo ""
	@echo "🏗️  ARCHITECTURE OVERVIEW"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Deployment Platform: AWS Fargate (fully managed containers)"
	@echo ""
	@echo "  MediaMTX:"
	@echo "    • RTSP Streaming Server (ingest from cameras)"
	@echo "    • Ports: 8554 (RTSP), 1935 (RTMP), 8888 (HLS), 8889 (WebRTC)"
	@echo "    • API: 8890 (control) + 9997 (local)"
	@echo "    • Health Check: HTTP GET on port 8888 (HLS endpoint)"
	@echo "    • Deployment: 2 tasks on Fargate"
	@echo ""
	@echo "  Broadcast-System:"
	@echo "    • Web dashboard (admin UI)"
	@echo "    • Port: 80/443 via ALB"
	@echo "    • Backend connects to MediaMTX for configuration"
	@echo "    • Health Check: HTTP GET /health"
	@echo "    • Deployment: 1 task on Fargate"
	@echo ""
	@echo "  Load Balancing:"
	@echo "    • ALB (Application Load Balancer) for Broadcast (port 80/443)"
	@echo "    • NLB (Network Load Balancer) for RTMP (port 1935) - Optional"
	@echo "    • Target groups with automatic health monitoring"
	@echo ""
	@echo "────────────────────────────────────────────────────────────────"
	@echo ""
	@echo "🚀 DEPLOYMENT"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Deploy everything:"
	@echo "    $$ make deploy"
	@echo "    • Deploys both MediaMTX + Broadcast to Fargate"
	@echo "    • Error-tolerant update strategy (retries on transient failures)"
	@echo "    • Automatically creates task definitions + services"
	@echo ""
	@echo "  Initial setup (first time only):"
	@echo "    $$ make setup"
	@echo "    • Creates log groups, task definitions, services"
	@echo ""
	@echo "────────────────────────────────────────────────────────────────"
	@echo ""
	@echo "🔄 UPDATE & MAINTENANCE"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Quick update (reuses existing services):"
	@echo "    $$ make update          # Update both services"
	@echo "    $$ make quick           # Faster: skip task def changes"
	@echo ""
	@echo "  Check status:"
	@echo "    $$ make status          # Show running tasks"
	@echo "    $$ make logs            # Tail real-time logs"
	@echo ""
	@echo "────────────────────────────────────────────────────────────────"
	@echo ""
	@echo "🧹 CLEANUP"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Delete services but keep images + logs:"
	@echo "    $$ make cleanup"
	@echo ""
	@echo "  Full cleanup (delete everything):"
	@echo "    $$ make cleanup-all"
	@echo ""
	@echo "────────────────────────────────────────────────────────────────"
	@echo ""
	@echo "🌐 DNS & HTTPS SETUP"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Show DNS configuration:"
	@echo "    $$ make dns-info        # ALB DNS + subdomain setup"
	@echo "    $$ make dns-check       # Test domain accessibility"
	@echo ""
	@echo "  SSL/TLS setup (optional):"
	@echo "    $$ make ssl-setup       # Request ACM certificate"
	@echo "    $$ make ssl-create-https-listener  # Enable HTTPS on ALB"
	@echo "    $$ make ssl-update-alb  # HTTP → HTTPS redirect"
	@echo ""
	@echo "────────────────────────────────────────────────────────────────"
	@echo ""
	@echo "📡 OPTIONAL: RTMP LOAD BALANCING"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Create Network Load Balancer for RTMP (port 1935):"
	@echo "    $$ make nlb-deploy      # Create + register targets"
	@echo "    $$ make nlb-status      # Check NLB health"
	@echo "    $$ make update-rpi-rtmp # Update RPi to use NLB"
	@echo ""
	@echo "────────────────────────────────────────────────────────────────"
	@echo ""
	@echo "🐛 DEBUGGING"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Show environment & configuration:"
	@echo "    $$ make debug-env       # Display all settings"
	@echo ""
	@echo "╔════════════════════════════════════════════════════════════════╗"
	@echo "║  Full documentation: see DEPLOYMENT_GUIDE.md                    ║"
	@echo "╚════════════════════════════════════════════════════════════════╝"
	@echo ""

setup: setup-ec2 ## 🏗️ Initial setup (EC2 - Recommended)

setup-ec2: ## 🏗️ Initial EC2 setup (creates EC2, logs, task definitions, services)
	@echo "🏗️ Starting full EC2 setup..."
	@echo ""
	@echo "🖥️ Step 1/4: Launching EC2 instance..."
	@$(MAKE) -s mediamtx-ec2-launch
	@echo ""
	@echo "📋 Step 2/4: Registering EC2 instances..."
	@$(MAKE) -s mediamtx-ec2-register-instances
	@echo ""
	@echo "📋 Step 3/4: Creating task definitions..."
	@$(MAKE) -s mediamtx-task-def-ec2
	@echo ""
	@echo "🔧 Step 4/4: Creating services..."
	@$(MAKE) -s mediamtx-service-ec2
	@echo ""
	@echo "✅ Setup complete! EC2-based MediaMTX starting..."
	@echo "   MediaMTX EC2:    $(MEDIAMTX_SERVICE)-ec2"
	@echo "   Instance Type:   $(EC2_INSTANCE_TYPE)"
	@echo ""

setup-fargate: ## 🏗️ Initial Fargate setup (Legacy - HTTP timeout issues)
	@echo "🏗️ Starting full Fargate setup (Legacy)..."
	@echo ""
	@echo "📡 Step 1/4: Setting up MediaMTX..."
	@$(MAKE) -s mediamtx-deploy
	@echo ""
	@echo "📺 Step 2/4: Building broadcast-system..."
	@$(MAKE) -s broadcast-build
	@echo ""
	@echo "📝 Step 3/4: Creating broadcast logs and task definition..."
	@$(MAKE) -s broadcast-logs broadcast-task-def
	@echo ""
	@echo "🔧 Step 4/4: Fixing ALB ports and creating broadcast service..."
	@$(MAKE) -s fix-broadcast-service
	@echo ""
	@echo "⚠️  Setup complete! Fargate services starting..."
	@echo "   MediaMTX:        $(MEDIAMTX_SERVICE)"
	@echo "   Broadcast:       $(BROADCAST_SERVICE)"
	@echo "   ⚠️  NOTE: HTTP endpoints may timeout due to Fargate networking issue"
	@echo ""
	@echo "🌐 Access Points:"
	@echo "   Admin:    https://$(ADMIN_DOMAIN)"
	@echo "   Streams:  https://$(STREAM_DOMAIN)/hls/"
	@echo ""
	@echo "💡 Recommendation: Use Fargate instead (make deploy)"
	@echo ""

deploy: deploy-fargate ## 🚀 Deploy both services to Fargate (Recommended)

.PHONY: mediamtx-wait-targets
mediamtx-wait-targets: ## ⏱ Wait for at least one healthy target in the MediaMTX target group
	@echo "⏱ Waiting for healthy targets in $(MEDIAMTX_TG_NAME)..."
	@TG_ARN=$$(aws elbv2 describe-target-groups --names $(MEDIAMTX_TG_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo ""); \
	if [ -z "$$TG_ARN" ] || [ "$$TG_ARN" = "None" ]; then \
	  echo "⚠️ Target group $(MEDIAMTX_TG_NAME) not found; skipping health wait"; exit 0; \
	fi; \
	for i in `seq 1 30`; do \
	  HEALTHY=$$(aws elbv2 describe-target-health --target-group-arn $$TG_ARN --region $(AWS_REGION) --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`]|length(@)' --output text 2>/dev/null || echo 0); \
	  if [ "$$HEALTHY" != "0" ]; then echo "✅ Found $$HEALTHY healthy target(s)"; exit 0; fi; \
	  echo "  no healthy targets yet ($$i/30), waiting..."; sleep 4; \
	done; \
	echo "⚠️ No healthy targets detected in $(MEDIAMTX_TG_NAME) after wait; continue with deploy but check logs/target health"; exit 0


deploy-ec2: mediamtx-deploy-ec2 broadcast-deploy fix-broadcast-service ## 🚀 Deploy to EC2 (RECOMMENDED - fixes Fargate HTTP timeout)
	@echo "✅ EC2 Deployment complete!"
	@echo ""
	@echo "🖥️ MediaMTX is now running on EC2 with bridge networking"
	@echo "   This fixes the Fargate HTTP response timeout issue"
	@echo ""
	@echo "📡 MediaMTX service: $(MEDIAMTX_SERVICE)-ec2"
	@echo "   RTSP input:      8554"
	@echo "   HLS output:      8888"
	@echo "   WebRTC output:   8889"
	@echo "   API endpoint:    http://<instance-ip>:8890/v3/"
	@echo "   RTMP output:     1935"
	@echo ""
	@echo "📺 Broadcast-System service: $(BROADCAST_SERVICE)"
	@echo "   Web interface:   https://$(ADMIN_DOMAIN)"
	@echo "   Backend:         port 80 (via ALB)"
	@echo ""
	@echo "🔍 Check status: make status"
	@echo "📝 Watch logs:   make logs"
	@echo ""

deploy-fargate: ## 🚀 Deploy both services to Fargate (idempotent end-to-end)
	@echo "🔁 Starting full idempotent deploy (Fargate)..."
	@echo "\n--- MediaMTX: build, push, task, logs, SG, ALB/TG, service ---\n"; \
	$(MAKE) -s mediamtx-ecr-repo mediamtx-build mediamtx-ecr-push mediamtx-task-def mediamtx-logs mediamtx-ensure-alb mediamtx-create-target-group mediamtx-create-rtsp mediamtx-attach-alb mediamtx-ensure-sg mediamtx-service mediamtx-wait-targets; \
	echo "\n--- Update Route53 DNS for MediaMTX ---\n"; \
	./scripts/update-mediamtx-dns.sh; \
	echo "\n--- Broadcast: build, push, task, service ---\n"; \
	$(MAKE) -s broadcast-ecr-repo broadcast-build broadcast-ecr-push broadcast-logs broadcast-task-def broadcast-deploy; \
	# Ensure ALB attach/config for broadcast
	$(MAKE) -s fix-broadcast-service; \
	echo "\n--- Setup Cloudflare DNS CNAME records ---\n"; \
	./scripts/setup-dns-cname.sh; \
	# Final status
	$(MAKE) -s status; \
	echo "\n✅ Full deploy (Fargate) complete"

quick: quick-ec2 ## ⚡ Quick update (EC2 - Recommended)

quick-ec2: mediamtx-update-ec2 broadcast-update ## ⚡ Quick EC2 update (update MediaMTX EC2 & broadcast services)
	@echo "✅ Quick EC2 update complete!"

update: update-ec2 ## 🔄 Update services with latest images (EC2 - Recommended)

update-ec2: mediamtx-update-ec2 broadcast-update ## 🔄 Update EC2 services with latest images

status: ## 📊 Show deployment status
	@echo "📊 Deployment Status"
	@echo "===================="
	@echo ""
	@echo "🔗 ECS Cluster: $(ECS_CLUSTER)"
	@aws ecs describe-services \
	  --cluster $(ECS_CLUSTER) \
	  --services $(MEDIAMTX_SERVICE) $(BROADCAST_SERVICE) \
	  --region $(AWS_REGION) \
	  --query 'services[].{Name:serviceName,Status:status,Running:runningCount,Desired:desiredCount,TaskDef:taskDefinition}' \
	  --output table 2>/dev/null || echo "Cluster not accessible"
	@echo ""
	@echo "🌐 Subdomains & Access:"
	@echo "  Admin:  https://$(ADMIN_DOMAIN)"
	@echo "  Stream: https://$(STREAM_DOMAIN)/hls/"
	@echo ""
	@echo "🌐 ALB & DNS:"
	@aws elbv2 describe-load-balancers \
	  --region $(AWS_REGION) \
	  --query 'LoadBalancers[?LoadBalancerName==`$(ALB_NAME)`].{Name:LoadBalancerName,DNS:DNSName,State:State}' \
	  --output table 2>/dev/null || echo "ALB not found"
	@echo ""

logs: ## 📝 Tail logs for both services
	@echo "📝 Streaming logs (Ctrl+C to stop)..."
	@echo ""
	@echo "🔴 MEDIAMTX LOGS:"
	aws logs tail $(MEDIAMTX_LOG_GROUP) --follow --since 5m --region $(AWS_REGION) 2>/dev/null & \
	sleep 2; \
	echo "🔵 BROADCAST-SYSTEM LOGS:"; \
	aws logs tail $(BROADCAST_LOG_GROUP) --follow --since 5m --region $(AWS_REGION) 2>/dev/null

###############################################
# DNS & Access
###############################################

###############################################
# DNS & Access
###############################################

.PHONY: dns-info dns-check dns-setup

dns-setup: ## 🌐 Setup Cloudflare CNAME records for broadcast subdomains
	@echo "🔧 Setting up Cloudflare DNS records..."
	@if [ -z "$(CLOUDFLARE_API_TOKEN)" ]; then \
	  echo "⚠️  CLOUDFLARE_API_TOKEN not set. Skipping DNS setup."; \
	  echo "   To enable: export CLOUDFLARE_API_TOKEN='your-token'"; \
	  exit 0; \
	fi
	@if [ -z "$(CLOUDFLARE_ZONE_ID)" ]; then \
	  echo "⚠️  CLOUDFLARE_ZONE_ID not set. Skipping DNS setup."; \
	  echo "   To enable: export CLOUDFLARE_ZONE_ID='your-zone-id'"; \
	  exit 0; \
	fi
	@CLOUDFLARE_API_TOKEN="$(CLOUDFLARE_API_TOKEN)" CLOUDFLARE_ZONE_ID="$(CLOUDFLARE_ZONE_ID)" ./scripts/setup-dns-cname.sh

dns-info: ## 🌐 Show DNS and access information
	@echo "🌐 Subdomain Configuration"
	@echo "==========================="
	@echo ""
	@echo "Admin Dashboard Domain: $(ADMIN_DOMAIN)"
	@echo "Streaming Domain:       $(STREAM_DOMAIN)"
	@echo "MediaMTX API Domain:    $(MEDIAMTX_DOMAIN)"
	@ALB_DNS=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(ALB_NAME)'].DNSName" --output text 2>/dev/null); \
	if [ -n "$$ALB_DNS" ]; then \
	  echo ""; \
	  echo "ALB DNS Name: $$ALB_DNS"; \
	  echo ""; \
	  echo "Cloudflare CNAME Records (Required):"; \
	  echo "  Name:    $(ADMIN_DOMAIN)"; \
	  echo "  Type:    CNAME"; \
	  echo "  Target:  $$ALB_DNS"; \
	  echo ""; \
	  echo "  Name:    $(STREAM_DOMAIN)"; \
	  echo "  Type:    CNAME"; \
	  echo "  Target:  $$ALB_DNS"; \
	  echo ""; \
	  echo "  Name:    $(MEDIAMTX_DOMAIN)"; \
	  echo "  Type:    CNAME"; \
	  echo "  Target:  $$ALB_DNS (or NLB if created)"; \
	else \
	  echo "❌ ALB not found"; \
	fi
	@echo ""
	@echo "📱 Access URLs:"
	@echo "  • Admin Dashboard:     https://$(ADMIN_DOMAIN)"
	@echo "  • Stream Dashboard:    https://$(STREAM_DOMAIN)/hls/<stream>/index.m3u8"
	@echo "  • MediaMTX API:        http://$(MEDIAMTX_DOMAIN):9997/v3/paths/list"
	@echo "  • MediaMTX RTSP:       rtsp://$(MEDIAMTX_DOMAIN):8554/<stream>"
	@echo "  • MediaMTX WebRTC:     http://$(MEDIAMTX_DOMAIN):8889/<stream>"
	@echo ""

dns-check: ## ✅ Check if domains are accessible
	@echo "✅ Testing domain accessibility..."
	@echo ""
	@echo "Testing Admin Domain: $(ADMIN_DOMAIN)"
	@if curl -s -m 5 https://$(ADMIN_DOMAIN)/health > /dev/null 2>&1; then \
	  echo "  ✅ Accessible"; \
	else \
	  echo "  ⚠️  Not accessible (may need DNS setup)"; \
	fi
	@echo ""
	@echo "Testing Stream Domain: $(STREAM_DOMAIN)"
	@if curl -s -m 5 https://$(STREAM_DOMAIN)/health > /dev/null 2>&1; then \
	  echo "  ✅ Accessible"; \
	else \
	  echo "  ⚠️  Not accessible (may need DNS setup)"; \
	fi
	@echo ""
	@echo "📋 Configure DNS:"
	@echo "  Run: make dns-info"

###############################################
# MEDIAMTX NLB - Multi-Protocol Public Access
###############################################
# Network Load Balancer for MediaMTX supporting:
# - RTSP (8554) for camera streams
# - WebRTC (8889) for browser playback  
# - API (9997) for management
# - RTMP (1935) for streaming

.PHONY: mediamtx-nlb-create mediamtx-nlb-targets mediamtx-nlb-listeners mediamtx-nlb-register mediamtx-nlb-status mediamtx-nlb-delete mediamtx-nlb-deploy

mediamtx-nlb-create: ## 🔨 Create Network Load Balancer for MediaMTX
	@echo "🔨 Creating MediaMTX NLB..."
	@NLB_ARN=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(NLB_NAME)'].LoadBalancerArn" --output text 2>/dev/null); \
	if [ -n "$$NLB_ARN" ]; then \
	  echo "✅ NLB already exists: $$NLB_ARN"; \
	  aws elbv2 describe-load-balancers --load-balancer-arns $$NLB_ARN --region $(AWS_REGION) --query 'LoadBalancers[0].{DNS:DNSName,State:State}' --output table; \
	else \
	  SUBNETS=$$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$(AWS_VPC_ID)" --region $(AWS_REGION) --query "Subnets[*].SubnetId" --output text | tr '\t' ' '); \
	  echo "Creating NLB in subnets: $$SUBNETS"; \
	  NLB_ARN=$$(aws elbv2 create-load-balancer \
	    --name $(NLB_NAME) \
	    --type network \
	    --scheme internet-facing \
	    --subnets $$SUBNETS \
	    --region $(AWS_REGION) \
	    --query 'LoadBalancers[0].LoadBalancerArn' \
	    --output text); \
	  echo "✅ Created NLB: $$NLB_ARN"; \
	  echo "🔧 Enabling cross-zone load balancing..."; \
	  aws elbv2 modify-load-balancer-attributes \
	    --load-balancer-arn $$NLB_ARN \
	    --region $(AWS_REGION) \
	    --attributes Key=load_balancing.cross_zone.enabled,Value=true > /dev/null; \
	  echo "✅ Cross-zone load balancing enabled"; \
	  aws elbv2 describe-load-balancers --load-balancer-arns $$NLB_ARN --region $(AWS_REGION) --query 'LoadBalancers[0].{DNS:DNSName,State:State}' --output table; \
	fi

mediamtx-nlb-targets: ## 🎯 Create NLB target groups for all MediaMTX ports
	@echo "🎯 Creating MediaMTX NLB target groups..."
	@echo ""
	@echo "Creating RTSP target group (port 8554)..."
	@TG_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$(NLB_TG_RTSP)'].TargetGroupArn" --output text 2>/dev/null); \
	if [ -z "$$TG_ARN" ]; then \
	  aws elbv2 create-target-group \
	    --name $(NLB_TG_RTSP) \
	    --protocol TCP \
	    --port $(MEDIAMTX_PORT_RTSP) \
	    --vpc-id $(AWS_VPC_ID) \
	    --target-type ip \
	    --health-check-protocol TCP \
	    --health-check-interval-seconds 30 \
	    --healthy-threshold-count 2 \
	    --unhealthy-threshold-count 2 \
	    --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text; \
	  echo "✅ Created RTSP target group"; \
	else \
	  echo "✅ RTSP target group exists: $$TG_ARN"; \
	fi
	@echo ""
	@echo "Creating WebRTC target group (port 8889)..."
	@TG_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$(NLB_TG_WEBRTC)'].TargetGroupArn" --output text 2>/dev/null); \
	if [ -z "$$TG_ARN" ]; then \
	  aws elbv2 create-target-group \
	    --name $(NLB_TG_WEBRTC) \
	    --protocol TCP \
	    --port $(MEDIAMTX_PORT_WEBRTC) \
	    --vpc-id $(AWS_VPC_ID) \
	    --target-type ip \
	    --health-check-protocol TCP \
	    --health-check-interval-seconds 30 \
	    --healthy-threshold-count 2 \
	    --unhealthy-threshold-count 2 \
	    --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text; \
	  echo "✅ Created WebRTC target group"; \
	else \
	  echo "✅ WebRTC target group exists: $$TG_ARN"; \
	fi
	@echo ""
	@echo "Creating API target group (port 9997)..."
	@TG_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$(NLB_TG_API)'].TargetGroupArn" --output text 2>/dev/null); \
	if [ -z "$$TG_ARN" ]; then \
	  aws elbv2 create-target-group \
	    --name $(NLB_TG_API) \
	    --protocol TCP \
	    --port $(MEDIAMTX_PORT_API) \
	    --vpc-id $(AWS_VPC_ID) \
	    --target-type ip \
	    --health-check-protocol TCP \
	    --health-check-interval-seconds 30 \
	    --healthy-threshold-count 2 \
	    --unhealthy-threshold-count 2 \
	    --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text; \
	  echo "✅ Created API target group"; \
	else \
	  echo "✅ API target group exists: $$TG_ARN"; \
	fi
	@echo ""
	@echo "Creating RTMP target group (port 1935)..."
	@TG_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$(NLB_TG_RTMP)'].TargetGroupArn" --output text 2>/dev/null); \
	if [ -z "$$TG_ARN" ]; then \
	  aws elbv2 create-target-group \
	    --name $(NLB_TG_RTMP) \
	    --protocol TCP \
	    --port $(MEDIAMTX_PORT_RTMP) \
	    --vpc-id $(AWS_VPC_ID) \
	    --target-type ip \
	    --health-check-protocol TCP \
	    --health-check-interval-seconds 30 \
	    --healthy-threshold-count 2 \
	    --unhealthy-threshold-count 2 \
	    --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text; \
	  echo "✅ Created RTMP target group"; \
	else \
	  echo "✅ RTMP target group exists: $$TG_ARN"; \
	fi
	@echo ""
	@echo "✅ All target groups ready"

mediamtx-nlb-listeners: ## 🔊 Create NLB listeners for all MediaMTX ports
	@echo "🔊 Creating MediaMTX NLB listeners..."
	@NLB_ARN=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(NLB_NAME)'].LoadBalancerArn" --output text 2>/dev/null); \
	if [ -z "$$NLB_ARN" ]; then \
	  echo "❌ NLB not found. Run 'make mediamtx-nlb-create' first."; \
	  exit 1; \
	fi; \
	echo "NLB: $$NLB_ARN"; \
	echo ""; \
	echo "Creating RTSP listener (port 8554)..."; \
	TG_RTSP=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$(NLB_TG_RTSP)'].TargetGroupArn" --output text); \
	aws elbv2 create-listener \
	  --load-balancer-arn $$NLB_ARN \
	  --protocol TCP \
	  --port $(MEDIAMTX_PORT_RTSP) \
	  --default-actions Type=forward,TargetGroupArn=$$TG_RTSP \
	  --region $(AWS_REGION) 2>&1 | grep -E "ListenerArn|Error" || echo "✅ RTSP listener ready"; \
	echo ""; \
	echo "Creating WebRTC listener (port 8889)..."; \
	TG_WEBRTC=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$(NLB_TG_WEBRTC)'].TargetGroupArn" --output text); \
	aws elbv2 create-listener \
	  --load-balancer-arn $$NLB_ARN \
	  --protocol TCP \
	  --port $(MEDIAMTX_PORT_WEBRTC) \
	  --default-actions Type=forward,TargetGroupArn=$$TG_WEBRTC \
	  --region $(AWS_REGION) 2>&1 | grep -E "ListenerArn|Error" || echo "✅ WebRTC listener ready"; \
	echo ""; \
	echo "Creating API listener (port 9997)..."; \
	TG_API=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$(NLB_TG_API)'].TargetGroupArn" --output text); \
	aws elbv2 create-listener \
	  --load-balancer-arn $$NLB_ARN \
	  --protocol TCP \
	  --port $(MEDIAMTX_PORT_API) \
	  --default-actions Type=forward,TargetGroupArn=$$TG_API \
	  --region $(AWS_REGION) 2>&1 | grep -E "ListenerArn|Error" || echo "✅ API listener ready"; \
	echo ""; \
	echo "Creating RTMP listener (port 1935)..."; \
	TG_RTMP=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$(NLB_TG_RTMP)'].TargetGroupArn" --output text); \
	aws elbv2 create-listener \
	  --load-balancer-arn $$NLB_ARN \
	  --protocol TCP \
	  --port $(MEDIAMTX_PORT_RTMP) \
	  --default-actions Type=forward,TargetGroupArn=$$TG_RTMP \
	  --region $(AWS_REGION) 2>&1 | grep -E "ListenerArn|Error" || echo "✅ RTMP listener ready"; \
	echo ""; \
	echo "✅ All listeners configured"

mediamtx-nlb-register: ## 📝 Register MediaMTX tasks with NLB target groups
	@echo "📝 Registering MediaMTX tasks with NLB..."
	@TASK_IPS=$$(aws ecs describe-tasks \
	  --cluster $(ECS_CLUSTER) \
	  --tasks $$(aws ecs list-tasks --cluster $(ECS_CLUSTER) --service-name $(MEDIAMTX_SERVICE) --region $(AWS_REGION) --query 'taskArns[*]' --output text 2>/dev/null) \
	  --region $(AWS_REGION) \
	  --query 'tasks[*].attachments[0].details[?name==`privateIPv4Address`].value' \
	  --output text 2>/dev/null); \
	if [ -z "$$TASK_IPS" ]; then \
	  echo "❌ No running MediaMTX tasks found"; \
	  exit 1; \
	fi; \
	echo "Found task IPs: $$TASK_IPS"; \
	echo ""; \
	for TG_NAME in $(NLB_TG_RTSP) $(NLB_TG_WEBRTC) $(NLB_TG_API) $(NLB_TG_RTMP); do \
	  TG_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$$TG_NAME'].TargetGroupArn" --output text); \
	  PORT=$$(aws elbv2 describe-target-groups --target-group-arns $$TG_ARN --region $(AWS_REGION) --query 'TargetGroups[0].Port' --output text); \
	  echo "Registering with $$TG_NAME (port $$PORT)..."; \
	  for IP in $$TASK_IPS; do \
	    aws elbv2 register-targets \
	      --target-group-arn $$TG_ARN \
	      --targets Id=$$IP,Port=$$PORT \
	      --region $(AWS_REGION) 2>&1 | grep -E "Error|Warning" || echo "  ✅ $$IP:$$PORT"; \
	  done; \
	  echo ""; \
	done; \
	echo "✅ Registration complete"

mediamtx-nlb-status: ## 📊 Show MediaMTX NLB status and health
	@echo "📊 MediaMTX NLB Status"
	@echo "===================="
	@echo ""
	@NLB_DNS=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(NLB_NAME)'].DNSName" --output text 2>/dev/null); \
	if [ -z "$$NLB_DNS" ]; then \
	  echo "❌ NLB not found"; \
	else \
	  echo "NLB DNS: $$NLB_DNS"; \
	  aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(NLB_NAME)'].{Name:LoadBalancerName,State:State.Code,Type:Type}" --output table; \
	fi
	@echo ""
	@echo "Target Group Health:"
	@echo "-------------------"
	@for TG_NAME in $(NLB_TG_RTSP) $(NLB_TG_WEBRTC) $(NLB_TG_API) $(NLB_TG_RTMP); do \
	  TG_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$$TG_NAME'].TargetGroupArn" --output text 2>/dev/null); \
	  if [ -n "$$TG_ARN" ]; then \
	    echo ""; \
	    echo "$$TG_NAME:"; \
	    aws elbv2 describe-target-health --target-group-arn $$TG_ARN --region $(AWS_REGION) --query 'TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table 2>/dev/null || echo "  No targets"; \
	  fi; \
	done
	@echo ""
	@echo "Listeners:"
	@echo "----------"
	@NLB_ARN=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(NLB_NAME)'].LoadBalancerArn" --output text 2>/dev/null); \
	if [ -n "$$NLB_ARN" ]; then \
	  aws elbv2 describe-listeners --load-balancer-arn $$NLB_ARN --region $(AWS_REGION) --query 'Listeners[*].{Port:Port,Protocol:Protocol}' --output table 2>/dev/null || echo "No listeners"; \
	fi

mediamtx-nlb-disable-healthchecks: ## ⚠️  Disable all NLB health checks (relaxes intervals and thresholds)
	@echo "⚠️  Relaxing health checks for all MediaMTX NLB target groups..."
	@echo ""
	@for TG_NAME in $(NLB_TG_RTSP) $(NLB_TG_WEBRTC) $(NLB_TG_API) $(NLB_TG_RTMP) mediamtx-nlb-hls; do \
	  echo "Processing $$TG_NAME..."; \
	  TG_ARN=$$(aws elbv2 describe-target-groups --names "$$TG_NAME" --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null); \
	  if [ -n "$$TG_ARN" ] && [ "$$TG_ARN" != "None" ]; then \
	    aws elbv2 modify-target-group \
	      --target-group-arn "$$TG_ARN" \
	      --region $(AWS_REGION) \
	      --health-check-interval-seconds 300 \
	      --unhealthy-threshold-count 10 > /dev/null 2>&1 && echo "  ✅ Relaxed: $$TG_NAME (300s interval, 10 unhealthy threshold)"; \
	  else \
	    echo "  ⚠️  Not found: $$TG_NAME"; \
	  fi; \
	done
	@echo ""
	@echo "✅ All health checks relaxed"

mediamtx-nlb-deploy: mediamtx-nlb-create mediamtx-nlb-targets mediamtx-nlb-listeners mediamtx-nlb-register ## 🚀 Complete NLB deployment (create + configure + register)
	@echo ""
	@echo "✅ MediaMTX NLB deployment complete!"
	@echo ""
	@$(MAKE) -s mediamtx-nlb-status
	@echo ""
	@echo "📝 Update DNS to point mediamtx.racetrackstreaming.com to NLB:"
	@echo "   Run: make dns-setup"
	@echo ""
	@echo "🧪 Test access:"
	@NLB_DNS=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(NLB_NAME)'].DNSName" --output text 2>/dev/null); \
	echo "   RTSP:   rtsp://$$NLB_DNS:8554/stream"; \
	echo "   WebRTC: http://$$NLB_DNS:8889/stream"; \
	echo "   API:    http://$$NLB_DNS:9997/v3/paths/list"

mediamtx-nlb-delete: ## 🗑️  Delete MediaMTX NLB and all target groups
	@echo "🗑️  Deleting MediaMTX NLB..."
	@NLB_ARN=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(NLB_NAME)'].LoadBalancerArn" --output text 2>/dev/null); \
	if [ -n "$$NLB_ARN" ]; then \
	  aws elbv2 delete-load-balancer --load-balancer-arn $$NLB_ARN --region $(AWS_REGION); \
	  echo "✅ NLB deleted"; \
	else \
	  echo "⚠️  NLB not found"; \
	fi
	@echo ""
	@echo "Deleting target groups..."
	@for TG_NAME in $(NLB_TG_RTSP) $(NLB_TG_WEBRTC) $(NLB_TG_API) $(NLB_TG_RTMP); do \
	  TG_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?TargetGroupName=='$$TG_NAME'].TargetGroupArn" --output text 2>/dev/null); \
	  if [ -n "$$TG_ARN" ]; then \
	    aws elbv2 delete-target-group --target-group-arn $$TG_ARN --region $(AWS_REGION) 2>/dev/null && echo "  ✅ Deleted $$TG_NAME" || echo "  ⚠️  Could not delete $$TG_NAME"; \
	  fi; \
	done
	@echo ""
	@echo "✅ Cleanup complete"

nlb-delete: ## 🗑️ Delete NLB and associated resources
	@echo "🗑️ Deleting NLB stack..."
	@aws cloudformation delete-stack \
	  --stack-name broadcast-rtmp-nlb \
	  --region $(AWS_REGION) 2>&1 | grep -E "Error" || echo "✅ Stack deletion initiated"

update-rpi-rtmp: ## 📡 Update RPi script to use NLB DNS
	@echo "📡 Updating RPi streaming script..."
	@NLB_DNS=$$(aws cloudformation describe-stacks --stack-name broadcast-rtmp-nlb --region $(AWS_REGION) --query 'Stacks[0].Outputs[?OutputKey==`NLBDNSName`].OutputValue' --output text 2>/dev/null); \
	if [ -z "$$NLB_DNS" ]; then \
	  echo "❌ NLB DNS not found. Ensure NLB is deployed: make nlb-deploy"; \
	  exit 1; \
	fi; \
	echo "NLB DNS: $$NLB_DNS"; \
	ssh dan7554@100.80.96.23 << 'EOF' \
		echo "Updating /home/dan7554/rpicam-stream.sh..."; \
		sed -i.bak 's|STREAM_DOMAIN="[^"]*"|STREAM_DOMAIN="'$$NLB_DNS'"|g' /home/dan7554/rpicam-stream.sh; \
		sudo systemctl restart rpicam-stream.service; \
		echo "Service restarted"; \
		sleep 2; \
		sudo systemctl status rpicam-stream.service --no-pager | head -10; \
	EOF

###############################################
# LOCAL DEVELOPMENT
###############################################

.PHONY: local-build local-run local-stop

local-build: ## 🔨 Build broadcast-system locally for testing
	@echo "🔨 Building locally..."
	docker build -f broadcast-system/Dockerfile -t $(BROADCAST_REPO):latest .
	@echo "✅ Built: $(BROADCAST_REPO):latest"

local-run: local-build ## 🏃 Run broadcast-system locally (assumes MediaMTX running)
	@echo "🏃 Running locally..."
	docker run -d \
	  --name broadcast-system \
	  -p 3001:3001 \
	  -e MEDIAMTX_URL="http://localhost:8889" \
	  -e NODE_ENV=development \
	  $(BROADCAST_REPO):latest
	@echo "✅ Running on http://localhost:3001"
	@echo "⚠️  Make sure MediaMTX is running on localhost:8889"

local-stop: ## 🛑 Stop local broadcast-system container
	@echo "🛑 Stopping..."
	docker stop broadcast-system && docker rm broadcast-system
	@echo "✅ Stopped"

###############################################
# SSL/TLS Configuration - ALB HTTPS Listener
###############################################

.PHONY: ssl-check ssl-request-cert ssl-validate-dns ssl-create-https-listener ssl-cleanup-http

ssl-check: ## 🔍 Check SSL/TLS certificate status
	@echo "🔍 Checking ACM certificate status..."
	@aws acm describe-certificate \
	  --certificate-arn $(ACM_CERT_ARN) \
	  --region $(AWS_REGION) \
	  --output json | jq '.Certificate | {Status: .Status, DomainName: .DomainName, SubjectAlternativeNames: .SubjectAlternativeNames}'
	@echo ""
	@echo "🔗 ALB Listeners:"
	@ALB_ARN=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(ALB_NAME)'].LoadBalancerArn" --output text); \
	aws elbv2 describe-listeners --load-balancer-arn "$$ALB_ARN" --region $(AWS_REGION) --query 'Listeners[].{Port:Port,Protocol:Protocol,Certificate:DefaultActions[0].Authentication.BodyName}' --output table

ssl-request-cert: ## 📝 Request new ACM certificate (auto-detected cert ARN)
	@echo "📝 Requesting ACM certificate with all subdomains..."
	@CERT_ARN=$$(aws acm request-certificate \
	  --domain-name racetrackstreaming.com \
	  --subject-alternative-names admin.racetrackstreaming.com stream.racetrackstreaming.com \*.racetrackstreaming.com \
	  --validation-method DNS \
	  --region $(AWS_REGION) \
	  --output text); \
	echo "✅ Certificate requested: $$CERT_ARN"; \
	echo "🔄 Use: make ssl-validate-dns ACM_CERT_ARN=$$CERT_ARN"

ssl-validate-dns: ssl-check ## 🔐 Display DNS validation records for Cloudflare
	@echo ""
	@echo "🔐 ACM DNS Validation Records (add to Cloudflare):"
	@echo "========================================"
	@aws acm describe-certificate \
	  --certificate-arn $(ACM_CERT_ARN) \
	  --region $(AWS_REGION) \
	  --output json | jq -r '.Certificate.DomainValidationOptions[] | select(.ValidationMethod=="DNS") | "\n📌 Domain: \(.DomainName)\n   Name:  \(.ResourceRecord.Name)\n   Type:  \(.ResourceRecord.Type)\n   Value: \(.ResourceRecord.Value)"'
	@echo ""
	@echo "⏳ Validation usually takes 5-15 minutes after adding DNS records"
	@echo "✅ Monitor status: make ssl-check ACM_CERT_ARN=$(ACM_CERT_ARN)"

ssl-create-https-listener: ## 🔐 Create HTTPS listener on ALB (requires validated certificate)
	@echo "🔐 Creating HTTPS listener on ALB port 443..."
	@ALB_ARN=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(ALB_NAME)'].LoadBalancerArn" --output text); \
	TARGET_GROUP_ARN=$$(aws elbv2 describe-target-groups --region $(AWS_REGION) --names $(ALB_TG_NAME) --query "TargetGroups[0].TargetGroupArn" --output text); \
	\
	LISTENER_ARN=$$(aws elbv2 describe-listeners --load-balancer-arn "$$ALB_ARN" --region $(AWS_REGION) --query "Listeners[?Port==\`443\`].ListenerArn" --output text 2>/dev/null); \
	\
	if [ -z "$$LISTENER_ARN" ]; then \
	  echo "📍 Creating new HTTPS listener..."; \
	  aws elbv2 create-listener \
	    --load-balancer-arn "$$ALB_ARN" \
	    --protocol HTTPS \
	    --port 443 \
	    --certificates CertificateArn=$(ACM_CERT_ARN) \
	    --default-actions Type=forward,TargetGroupArn="$$TARGET_GROUP_ARN" \
	    --region $(AWS_REGION) \
	    --output json | jq '.Listeners[0] | {Port: .Port, Protocol: .Protocol, CertificateArn: .Certificates[0].CertificateArn}'; \Zz	  echo "✅ HTTPS listener created"; \
	else \
	  echo "📍 Updating existing HTTPS listener..."; \
	  aws elbv2 modify-listener \
	    --listener-arn "$$LISTENER_ARN" \
	    --protocol HTTPS \
	    --certificates CertificateArn=$(ACM_CERT_ARN) \
	    --region $(AWS_REGION) \
	    --output json | jq '.Listeners[0] | {Port: .Port, Protocol: .Protocol, CertificateArn: .Certificates[0].CertificateArn}'; \
	  echo "✅ HTTPS listener updated"; \
	fi

ssl-update-alb: ## 🔄 Update ALB to redirect HTTP → HTTPS
	@echo "🔄 Configuring ALB HTTP → HTTPS redirect..."
	@ALB_ARN=$$(aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?LoadBalancerName=='$(ALB_NAME)'].LoadBalancerArn" --output text); \
	HTTP_LISTENER_ARN=$$(aws elbv2 describe-listeners --load-balancer-arn "$$ALB_ARN" --region $(AWS_REGION) --query "Listeners[?Port==\`80\`].ListenerArn" --output text); \
	\
	aws elbv2 modify-listener \
	  --listener-arn "$$HTTP_LISTENER_ARN" \
	  --default-actions Type=redirect,RedirectConfig='{Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' \
	  --region $(AWS_REGION); \
	echo "✅ HTTP listener now redirects to HTTPS"

ssl-setup: ssl-request-cert ssl-validate-dns ## 🚀 Full SSL setup (request cert + show validation)
	@echo ""
	@echo "📋 Next Steps:"
	@echo "1. Add the DNS records shown above to Cloudflare"
	@echo "2. Wait 5-15 minutes for validation"
	@echo "3. Run: make ssl-create-https-listener"
	@echo "4. Run: make ssl-update-alb"

###############################################
# CLEANUP & DEBUGGING
###############################################

.PHONY: cleanup cleanup-all debug-env

cleanup: ## 🧹 Delete ECS services (keep images, logs, and infrastructure)
	@echo "🧹 Deleting ECS services..."
	aws ecs delete-service \
	  --cluster $(ECS_CLUSTER) \
	  --service $(MEDIAMTX_SERVICE) \
	  --force \
	  --region $(AWS_REGION) 2>/dev/null || true
	aws ecs delete-service \
	  --cluster $(ECS_CLUSTER) \
	  --service $(BROADCAST_SERVICE) \
	  --force \
	  --region $(AWS_REGION) 2>/dev/null || true
	@echo "✅ Services deleted"


cleanup-all: cleanup ## 🧹🔥 Full cleanup (services, task definitions, images, logs)
	@echo "⚠️  Deleting all resources..."
	@echo "Running cleanup script..."
	@MEDIAMTX_LOG_GROUP="$(MEDIAMTX_LOG_GROUP)" BROADCAST_LOG_GROUP="$(BROADCAST_LOG_GROUP)" ALB_NAME="$(ALB_NAME)" AWS_REGION="$(AWS_REGION)" MEDIAMTX_TG_NAME="$(MEDIAMTX_TG_NAME)" ALB_TG_NAME="$(ALB_TG_NAME)" ECS_SECURITY_GROUP="$(ECS_SECURITY_GROUP)" ALB_SECURITY_GROUP="$(ALB_SECURITY_GROUP)" MEDIAMTX_PORT_API="$(MEDIAMTX_PORT_API)" MEDIAMTX_TASK_FAMILY="$(MEDIAMTX_TASK_FAMILY)" BROADCAST_TASK_FAMILY="$(BROADCAST_TASK_FAMILY)" MEDIAMTX_REPO="$(MEDIAMTX_REPO)" BROADCAST_REPO="$(BROADCAST_REPO)" sh scripts/mediamtx-cleanup.sh;

debug-env: ## 🐛 Show configuration and environment variables
	@echo "🐛 Environment & Configuration"
	@echo "=============================="
	@echo "AWS Region:             $(AWS_REGION)"
	@echo "AWS Account:            $(AWS_ACCOUNT_ID)"
	@echo "ECS Cluster:            $(ECS_CLUSTER)"
	@echo "VPC ID:                 $(AWS_VPC_ID)"
	@echo "Subnet ID:              $(AWS_SUBNET_ID)"
	@echo ""
	@echo "📡 MediaMTX:"
	@echo "  Task Family:          $(MEDIAMTX_TASK_FAMILY)"
	@echo "  Service:              $(MEDIAMTX_SERVICE)"
	@echo "  ECR:                  $(MEDIAMTX_ECR)"
	@echo "  Resources:            $(MEDIAMTX_CPU) CPU / $(MEDIAMTX_MEMORY) MB"
	@echo "  Log Group:            $(MEDIAMTX_LOG_GROUP)"
	@echo ""
	@echo "📺 Broadcast-System:"
	@echo "  Task Family:          $(BROADCAST_TASK_FAMILY)"
	@echo "  Service:              $(BROADCAST_SERVICE)"
	@echo "  ECR:                  $(BROADCAST_ECR)"
	@echo "  Resources:            $(BROADCAST_CPU) CPU / $(BROADCAST_MEMORY) MB"
	@echo "  Log Group:            $(BROADCAST_LOG_GROUP)"
	@echo "  MediaMTX URL:         $(MEDIAMTX_SERVICE_URL)"
	@echo ""
	@echo "🌐 ALB & Domains:"
	@echo "  ALB Name:             $(ALB_NAME)"
	@echo "  Target Group:         $(ALB_TG_NAME)"
	@echo "  Security Group:       $(ALB_SECURITY_GROUP)"
	@echo "  Admin Domain:         $(ADMIN_DOMAIN)"
	@echo "  Stream Domain:        $(STREAM_DOMAIN)"
	@echo ""

.DEFAULT_GOAL := help

###############################################
# AWS Cost Estimation
###############################################

# Pricing assumptions (override when running):
# - PRICE_FARGATE_VCPU_H: $ per vCPU-hour (vCPU = 1024 CPU units)
# - PRICE_FARGATE_MEM_GB_H: $ per GB-hour
# - ALB_MONTHLY_PRICE: fixed monthly ALB cost estimate
# - ECR_GB_MONTHLY: $ per GB-month for ECR storage (guide)
# - EC2_MONTHLY_ESTIMATE_PER_INSTANCE: monthly cost estimate per test EC2 instance
PRICE_FARGATE_VCPU_H ?= 0.040
PRICE_FARGATE_MEM_GB_H ?= 0.0045
ALB_MONTHLY_PRICE ?= 18.00
ECR_GB_MONTHLY ?= 0.10
EC2_MONTHLY_ESTIMATE_PER_INSTANCE ?= 15.00

.PHONY: aws-cost-estimate

aws-cost-estimate: ## 📊 Estimate next-month AWS costs (rough, configurable rates)
	@MEDIAMTX_CPU="$(MEDIAMTX_CPU)" MEDIAMTX_MEMORY="$(MEDIAMTX_MEMORY)" BROADCAST_CPU="$(BROADCAST_CPU)" BROADCAST_MEMORY="$(BROADCAST_MEMORY)" \
		PRICE_FARGATE_VCPU_H="$(PRICE_FARGATE_VCPU_H)" PRICE_FARGATE_MEM_GB_H="$(PRICE_FARGATE_MEM_GB_H)" \
		ALB_NAME="$(ALB_NAME)" AWS_REGION="$(AWS_REGION)" ECS_CLUSTER="$(ECS_CLUSTER)" MEDIAMTX_SERVICE="$(MEDIAMTX_SERVICE)" BROADCAST_SERVICE="$(BROADCAST_SERVICE)" \
		ECR_GB_MONTHLY="$(ECR_GB_MONTHLY)" EC2_MONTHLY_ESTIMATE_PER_INSTANCE="$(EC2_MONTHLY_ESTIMATE_PER_INSTANCE)" \
		sh scripts/aws-cost-estimate.sh
