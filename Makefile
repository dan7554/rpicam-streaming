# Multi-Application Docker & AWS ECS Deployment Makefile
# Manages both MediaMTX (media streaming) and Broadcast-System (admin dashboard) 
# Optimized for 5-8 camera RTSP streaming with low latency
.PHONY: help

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
MEDIAMTX_SERVICE := mediamtx-service
MEDIAMTX_LOG_GROUP := /ecs/mediamtx
MEDIAMTX_PORT_RTSP := 8554
MEDIAMTX_PORT_HLS := 8888
MEDIAMTX_PORT_WEBRTC := 8889
MEDIAMTX_PORT_RTMP := 1935
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

# Service discovery: MediaMTX service DNS name in ECS awsvpc mode
# Format: <service>.<cluster>.ecs.local (ECS native service discovery)
MEDIAMTX_SERVICE_URL := http://$(MEDIAMTX_SERVICE).$(ECS_CLUSTER).ecs.local:$(MEDIAMTX_PORT_WEBRTC)

###############################################
# ALB & Security Group Configuration
###############################################

ALB_NAME := broadcast-alb
ALB_TG_NAME := broadcast-targets
ALB_SECURITY_GROUP := sg-0693f1de9c2f66aef
ECS_SECURITY_GROUP := sg-084ba18877836077a

# Domain Configuration
ADMIN_DOMAIN := admin.racetrackstreaming.com    # Broadcast admin dashboard
STREAM_DOMAIN := stream.racetrackstreaming.com   # MediaMTX HLS/RTSP streaming
DOMAIN := $(ADMIN_DOMAIN)                        # Default domain (for backward compatibility)

# SSL/TLS Configuration
ACM_CERT_ARN ?= arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53
HTTPS_LISTENER_ARN ?=

###############################################
# Help
###############################################

help: ## Show this help message
	@echo "🎥 Multi-Camera Broadcast System - Docker & AWS ECS Manager"
	@echo "===========================================================\n"
	@echo "For 5-8 camera RTSP streaming with low-latency HLS/WebRTC\n"
	@echo "📡 MEDIAMTX (Media Streaming Server):"
	@grep -E '^mediamtx-[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "📺 BROADCAST-SYSTEM (Admin Dashboard):"
	@grep -E '^broadcast-[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🔗 ORCHESTRATION (Deploy Both):"
	@grep -E '^(deploy|setup|update|quick):' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🌐 DNS & Monitoring:"
	@grep -E '^(dns|status|logs):' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🔐 SSL/TLS & Security:"
	@grep -E '^ssl-' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🔗 SUBDOMAIN ROUTING:"
	@echo "  Admin Dashboard:  https://$(ADMIN_DOMAIN)"
	@echo "  HLS Streaming:    https://$(STREAM_DOMAIN)/hls/"
	@echo ""
	@echo "⚙️  Service Discovery Architecture:"
	@echo "  Cameras → MediaMTX (port 8554 RTSP) → HLS/WebRTC on 8888/8889"
	@echo "           ↓ (service DNS: $(MEDIAMTX_SERVICE).local)"
	@echo "       Broadcast-System (admin dashboard) → YouTube via RTMP"
	@echo ""

###############################################
# MEDIAMTX TARGETS - ECR & Docker Build
###############################################

.PHONY: mediamtx-ecr-login mediamtx-ecr-push mediamtx-aws-deploy
.PHONY: mediamtx-task-def mediamtx-service mediamtx-update mediamtx-logs

mediamtx-ecr-login: ## 🔐 Login to AWS ECR for MediaMTX
	@echo "🔐 Logging into ECR..."
	aws ecr get-login-password --region $(AWS_REGION) | \
	  docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

mediamtx-ecr-repo: ## 📦 Create ECR repository for MediaMTX
	@echo "📦 Creating ECR repository for MediaMTX..."
	aws ecr create-repository \
	  --repository-name $(MEDIAMTX_REPO) \
	  --region $(AWS_REGION) 2>/dev/null || echo "Repository already exists"

mediamtx-pull: mediamtx-ecr-login ## ⬇️ Pull latest MediaMTX image and push to ECR
	@echo "⬇️ Pulling bluenviron/mediamtx:latest..."
	docker pull $(MEDIAMTX_IMAGE)
	@echo "🏷️  Tagging for ECR..."
	docker tag $(MEDIAMTX_IMAGE) $(MEDIAMTX_ECR)
	@echo "⬆️ Pushing to ECR..."
	docker push $(MEDIAMTX_ECR)
	@echo "✅ MediaMTX image pushed to ECR: $(MEDIAMTX_ECR)"

mediamtx-ecr-push: mediamtx-ecr-repo mediamtx-pull ## ⬆️ Complete ECR push for MediaMTX

mediamtx-task-def: mediamtx-ecr-push ## 📋 Create MediaMTX ECS task definition
	@echo "📋 Creating MediaMTX task definition..."
	@aws ecs register-task-definition \
	  --family $(MEDIAMTX_TASK_FAMILY) \
	  --network-mode awsvpc \
	  --requires-compatibilities FARGATE \
	  --cpu $(MEDIAMTX_CPU) \
	  --memory $(MEDIAMTX_MEMORY) \
	  --execution-role-arn arn:aws:iam::$(AWS_ACCOUNT_ID):role/ecsTaskExecutionRole \
	  --container-definitions "[{ \
	    \"name\": \"mediamtx\", \
	    \"image\": \"$(MEDIAMTX_ECR)\", \
	    \"cpu\": $(MEDIAMTX_CPU), \
	    \"memory\": $(MEDIAMTX_MEMORY), \
	    \"portMappings\": [ \
	      {\"containerPort\": $(MEDIAMTX_PORT_RTSP), \"protocol\": \"tcp\"}, \
	      {\"containerPort\": $(MEDIAMTX_PORT_HLS), \"protocol\": \"tcp\"}, \
	      {\"containerPort\": $(MEDIAMTX_PORT_WEBRTC), \"protocol\": \"tcp\"}, \
	      {\"containerPort\": $(MEDIAMTX_PORT_RTMP), \"protocol\": \"tcp\"} \
	    ], \
	    \"logConfiguration\": { \
	      \"logDriver\": \"awslogs\", \
	      \"options\": { \
	        \"awslogs-group\": \"$(MEDIAMTX_LOG_GROUP)\", \
	        \"awslogs-region\": \"$(AWS_REGION)\", \
	        \"awslogs-stream-prefix\": \"mediamtx\" \
	      } \
	    }, \
	    \"healthCheck\": { \
	      \"command\": [\"CMD-SHELL\", \"curl -f http://localhost:9997/v1/config || exit 1\"], \
	      \"interval\": 30, \
	      \"timeout\": 5, \
	      \"retries\": 3, \
	      \"startPeriod\": 10 \
	    } \
	  }]" \
	  --region $(AWS_REGION)
	@echo "✅ Task definition registered"

mediamtx-logs: ## 📝 Create CloudWatch log group for MediaMTX
	@echo "📝 Creating log group..."
	aws logs create-log-group --log-group-name $(MEDIAMTX_LOG_GROUP) --region $(AWS_REGION) 2>/dev/null || echo "Log group exists"
	aws logs put-retention-policy --log-group-name $(MEDIAMTX_LOG_GROUP) --retention-in-days 7 --region $(AWS_REGION) 2>/dev/null || true
	@echo "✅ Log group ready"

mediamtx-service: mediamtx-logs ## ⚙️ Create MediaMTX ECS service (internal, no ALB)
	@echo "⚙️ Creating MediaMTX ECS service..."
	@aws ecs create-service \
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
	    --region $(AWS_REGION))
	@echo "✅ MediaMTX service ready"

mediamtx-update: mediamtx-ecr-push ## 🔄 Update MediaMTX service with latest image
	@echo "🔄 Updating MediaMTX service..."
	aws ecs update-service \
	  --cluster $(ECS_CLUSTER) \
	  --service $(MEDIAMTX_SERVICE) \
	  --force-new-deployment \
	  --region $(AWS_REGION)
	@echo "✅ Service update initiated"

mediamtx-deploy: mediamtx-logs mediamtx-task-def mediamtx-service ## 🚀 Complete MediaMTX deployment

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
	      {\"name\": \"PORT\", \"value\": \"3001\"}, \
	      {\"name\": \"MEDIAMTX_URL\", \"value\": \"$(MEDIAMTX_SERVICE_URL)\"} \
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
	  --region $(AWS_REGION) 2>/dev/null || echo "Service already exists"
	@echo "✅ Broadcast-system service deployment initiated"

###############################################
# FIX HEALTH CHECK - Port mapping issue
###############################################

.PHONY: fix-alb-ports fix-broadcast-service

fix-alb-ports: ## 🔧 Fix ALB target group port from 8888 to 80
	@echo "🔧 Fixing ALB target group port..."
	@TARGET_GROUP_ARN=$$(aws elbv2 describe-target-groups \
	  --region $(AWS_REGION) \
	  --names $(ALB_TG_NAME) \
	  --query 'TargetGroups[0].TargetGroupArn' \
	  --output text); \
	if [ -z "$$TARGET_GROUP_ARN" ]; then \
	  echo "❌ Target group not found"; \
	  exit 1; \
	fi; \
	aws elbv2 modify-target-group \
	  --target-group-arn $$TARGET_GROUP_ARN \
	  --port 80 \
	  --health-check-path $(BROADCAST_HEALTH_PATH) \
	  --region $(AWS_REGION)
	@echo "✅ ALB port fixed to 80, health check path: $(BROADCAST_HEALTH_PATH)"

fix-broadcast-service: fix-alb-ports ## 🔧 Recreate broadcast-service with ALB
	@echo "🔧 Updating broadcast-service to use ALB..."
	@TARGET_GROUP_ARN=$$(aws elbv2 describe-target-groups \
	  --region $(AWS_REGION) \
	  --names $(ALB_TG_NAME) \
	  --query 'TargetGroups[0].TargetGroupArn' \
	  --output text); \
	aws ecs update-service \
	  --cluster $(ECS_CLUSTER) \
	  --service $(BROADCAST_SERVICE) \
	  --load-balancers "targetGroupArn=$$TARGET_GROUP_ARN,containerName=broadcast-system,containerPort=80" \
	  --force-new-deployment \
	  --region $(AWS_REGION)
	@echo "✅ Broadcast-service updated with ALB"

###############################################
# ORCHESTRATION - Deploy Both Services
###############################################

.PHONY: setup deploy quick update status logs

setup: ## 🏗️ Initial setup (create logs, ECR repos, task definitions, services)
	@echo "🏗️ Starting full setup..."
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
	@echo "✅ Setup complete! Services starting..."
	@echo "   MediaMTX:        $(MEDIAMTX_SERVICE)"
	@echo "   Broadcast:       $(BROADCAST_SERVICE)"
	@echo ""
	@echo "🌐 Access Points:"
	@echo "   Admin:    https://$(ADMIN_DOMAIN)"
	@echo "   Streams:  https://$(STREAM_DOMAIN)/hls/"
	@echo ""
	@echo "📊 Check status: make status"

deploy: mediamtx-deploy broadcast-deploy fix-broadcast-service ## 🚀 Deploy both MediaMTX and broadcast-system with fresh builds
	@echo "✅ Deployment complete!"
	@echo ""
	@echo "📡 MediaMTX service: $(MEDIAMTX_SERVICE)"
	@echo "   RTSP input:      8554"
	@echo "   HLS output:      8888"
	@echo "   WebRTC output:   8889"
	@echo "   RTMP output:     1935"
	@echo ""
	@echo "📺 Broadcast-System service: $(BROADCAST_SERVICE)"
	@echo "   Web interface:   https://$(ADMIN_DOMAIN)"
	@echo "   Backend:         port 80 (via ALB)"
	@echo ""
	@echo "📡 MediaMTX Streaming: $(MEDIAMTX_SERVICE)"
	@echo "   HLS streams:     https://$(STREAM_DOMAIN)/hls/<stream>"
	@echo "   Direct RTSP:     rtsp://<mediamtx-ip>:8554/<stream>"
	@echo ""

quick: broadcast-ecr-push broadcast-update ## ⚡ Quick update (rebuild & push broadcast-system, update service)
	@echo "✅ Quick update complete!"

update: mediamtx-update broadcast-update ## 🔄 Update both services with latest images

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

.PHONY: dns-info dns-check

dns-info: ## 🌐 Show DNS and access information
	@echo "🌐 Subdomain Configuration"
	@echo "==========================="
	@echo ""
	@echo "Admin Dashboard Domain: $(ADMIN_DOMAIN)"
	@echo "Streaming Domain:       $(STREAM_DOMAIN)"
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
	else \
	  echo "❌ ALB not found"; \
	fi
	@echo ""
	@echo "📱 Access URLs:"
	@echo "  • Admin Dashboard:     https://$(ADMIN_DOMAIN)"
	@echo "  • HLS Streams:         https://$(STREAM_DOMAIN)/hls/<stream>/index.m3u8"
	@echo "  • MediaMTX Direct:     http://<mediamtx-ip>:9997"
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
	    --output json | jq '.Listeners[0] | {Port: .Port, Protocol: .Protocol, CertificateArn: .Certificates[0].CertificateArn}'; \
	  echo "✅ HTTPS listener created"; \
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
	aws logs delete-log-group --log-group-name $(MEDIAMTX_LOG_GROUP) --region $(AWS_REGION) 2>/dev/null || true
	aws logs delete-log-group --log-group-name $(BROADCAST_LOG_GROUP) --region $(AWS_REGION) 2>/dev/null || true
	@echo "✅ All cleaned up"

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
