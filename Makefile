# MediaMTX Docker Management Makefile
.PHONY: help build run stop logs clean restart shell health status pull push

###############################################
# Configuration Variables
###############################################

# Docker Configuration
IMAGE_NAME := mediamtx-server
CONTAINER_NAME := mediamtx-server
DOCKER_REGISTRY := # Add your registry here if needed
VERSION := latest
CONFIG_FILE := mediamtx-container.yml  # Use container-optimized config by default

# AWS Configuration
AWS_REGION ?= us-east-2
AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)

# AWS ECR Configuration
REPO_NAME ?= mediamtx
ECR_URI := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(REPO_NAME)

# AWS ECS Configuration
ECS_CLUSTER_NAME := mediamtx-cluster
ECS_SERVICE_NAME := mediamtx-service
ECS_TASK_FAMILY := mediamtx-task
ECS_LOG_GROUP := /ecs/mediamtx

# AWS ALB Configuration
ALB_NAME := mediamtx-alb
TARGET_GROUP_NAME := mediamtx-targets
DOMAIN_NAME ?= stream.racetrackstreaming.com  # Using subdomain for CNAME compatibility
CERTIFICATE_ARN ?= # Add your ACM certificate ARN here

###############################################
# Main Targets
###############################################

# Default target
help: ## Show this help message
	@echo "📘 MediaMTX Docker & AWS ECS Management"
	@echo "======================================="
	@echo ""
	@echo "🐳 Docker Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '^(build|run|push|docker)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "☁️  AWS ECS Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '^ecs' | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🔗 AWS ALB Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '^alb' | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "📋 Other Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -vE '^(build|run|push|docker|ecs|alb)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "🚀 Quick Start:"
	@echo "  1. Deploy MediaMTX:      make ecs-deploy"
	@echo "  2. Set up domain access: make alb-create"
	@echo "  3. Get URLs:             make alb-get-dns"
	@echo ""
	@echo "⚙️  Configuration:"
	@echo "  • Edit DOMAIN_NAME in Makefile for your domain"
	@echo "  • Set CERTIFICATE_ARN for HTTPS (optional)"

# Build targets
build: ## Build the Docker image
	@echo "Building MediaMTX Docker image..."
	docker build -t $(IMAGE_NAME):$(VERSION) .
	@echo "✅ Build complete!"

build-no-cache: ## Build the Docker image without cache
	@echo "Building MediaMTX Docker image (no cache)..."
	docker build --no-cache -t $(IMAGE_NAME):$(VERSION) .
	@echo "✅ Build complete!"

build-cloud: ## Build the Docker image for cloud deployment (AMD64)
	@echo "Building MediaMTX Docker image for cloud deployment (AMD64)..."
	docker build --platform linux/amd64 -t $(IMAGE_NAME):$(VERSION) .
	@echo "✅ Cloud build complete!"

build-rpi: ## Build the Docker image for Raspberry Pi (ARM)
	@echo "Building MediaMTX Docker image for Raspberry Pi (ARM)..."
	docker build --platform linux/arm64 -f Dockerfile.rpi -t $(IMAGE_NAME):$(VERSION)-rpi .
	@echo "✅ Raspberry Pi build complete!"

# Run targets
run: build stop ## Build and run the container (stops existing first)
	@echo "Starting MediaMTX container..."
	docker run -d \
		--name $(CONTAINER_NAME) \
		--restart unless-stopped \
		-p 8554:8554 \
		-p 1935:1935 \
		-p 8888:8888 \
		-p 8889:8889 \
		-p 9996:9996 \
		-p 8890:8890/udp \
		-p 8189:8189/udp \
		$(IMAGE_NAME):$(VERSION)
	@echo "✅ Container started!"
	@echo "📡 RTSP: rtsp://localhost:8554"
	@echo "🌐 Web UI: http://localhost:8888"
	@echo "📺 WebRTC: http://localhost:8889"

run-compose: ## Run using docker compose
	@echo "Starting MediaMTX with docker compose..."
	docker compose up -d
	@echo "✅ Service started!"

run-dev: ## Run in development mode (interactive, remove on exit)
	@echo "Starting MediaMTX in development mode..."
	docker run --rm -it \
		--name $(CONTAINER_NAME)-dev \
		-p 8554:8554 \
		-p 1935:1935 \
		-p 8888:8888 \
		-p 8889:8889 \
		-p 9996:9996 \
		-p 8890:8890/udp \
		-p 8189:8189/udp \
		$(IMAGE_NAME):$(VERSION)

# Control targets
stop: ## Stop the running container
	@echo "Stopping MediaMTX container..."
	-docker stop $(CONTAINER_NAME) 2>/dev/null || true
	-docker rm $(CONTAINER_NAME) 2>/dev/null || true
	@echo "✅ Container stopped!"

stop-compose: ## Stop docker compose services
	@echo "Stopping docker compose services..."
	docker compose down
	@echo "✅ Services stopped!"

restart: stop run ## Restart the container
	@echo "✅ Container restarted!"

restart-compose: ## Restart docker compose services
	@echo "Restarting docker compose services..."
	docker compose restart
	@echo "✅ Services restarted!"

# Force commands for troubleshooting
force-stop: ## Force stop and remove container (use if regular stop fails)
	@echo "Force stopping MediaMTX container..."
	-docker kill $(CONTAINER_NAME) 2>/dev/null || true
	-docker rm -f $(CONTAINER_NAME) 2>/dev/null || true
	@echo "✅ Container force stopped!"

force-clean: ## Force clean everything related to this project
	@echo "Force cleaning all MediaMTX resources..."
	-docker kill $(CONTAINER_NAME) 2>/dev/null || true
	-docker rm -f $(CONTAINER_NAME) 2>/dev/null || true
	-docker rmi -f $(IMAGE_NAME):$(VERSION) 2>/dev/null || true
	@echo "✅ Force cleanup complete!"

# Monitoring targets
logs: ## Show container logs
	docker logs -f $(CONTAINER_NAME)

logs-compose: ## Show docker compose logs
	docker compose logs -f

status: ## Show container status
	@echo "Container Status:"
	@docker ps -a --filter name=$(CONTAINER_NAME) --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

health: ## Check container health
	@echo "Health Check:"
	@docker inspect $(CONTAINER_NAME) --format='{{.State.Health.Status}}' 2>/dev/null || echo "No health check available"
	@echo ""
	@echo "Testing endpoints:"
	@curl -s -o /dev/null -w "HTTP API (8888): %{http_code}\n" http://localhost:8888/ || echo "HTTP API (8888): Connection failed"
	@curl -s -o /dev/null -w "WebRTC (8889): %{http_code}\n" http://localhost:8889/ || echo "WebRTC (8889): Connection failed"

# Development targets
shell: ## Open a shell in the running container
	docker exec -it $(CONTAINER_NAME) /bin/sh

shell-new: ## Run a new container with shell access
	docker run --rm -it \
		-p 8554:8554 \
		-p 1935:1935 \
		-p 8888:8888 \
		-p 8889:8889 \
		-p 9996:9996 \
		-p 8890:8890/udp \
		-p 8189:8189/udp \
		$(IMAGE_NAME):$(VERSION) /bin/sh

# Cleanup targets
clean: stop ## Stop container and remove image
	@echo "Cleaning up..."
	-docker rmi $(IMAGE_NAME):$(VERSION)
	@echo "✅ Cleanup complete!"

clean-all: ## Remove all containers, images, and volumes
	@echo "Removing all MediaMTX containers and images..."
	-docker stop $(CONTAINER_NAME)
	-docker rm $(CONTAINER_NAME)
	-docker rmi $(IMAGE_NAME):$(VERSION)
	-docker system prune -f
	@echo "✅ Full cleanup complete!"

# Update targets
pull: ## Pull the latest base image
	@echo "Pulling latest base image..."
	docker pull bluenviron/mediamtx:1-ffmpeg-rpi
	@echo "✅ Base image updated!"

update: pull build ## Update base image and rebuild
	@echo "✅ Update complete!"

# Configuration targets
config-check: ## Check configuration files
	@echo "Checking configuration files..."
	@test -f mediamtx.yml && echo "✅ mediamtx.yml found" || echo "❌ mediamtx.yml missing"
	@test -f server.crt && echo "✅ server.crt found" || echo "❌ server.crt missing"
	@test -f server.key && echo "✅ server.key found" || echo "❌ server.key missing"
	@test -f Dockerfile && echo "✅ Dockerfile found" || echo "❌ Dockerfile missing"

# Testing targets
test-stream: ## Test RTSP stream with ffmpeg
	@echo "Testing RTSP stream..."
	@echo "Starting test stream (10 seconds)..."
	ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 -f lavfi -i sine=frequency=1000:sample_rate=48000 -c:v libx264 -preset ultrafast -c:a aac -t 10 -f rtsp rtsp://localhost:8554/test || echo "❌ Test failed - make sure MediaMTX is running"

# Pi streaming targets
pi-setup: ## Show commands to set up Pi streaming
	@echo "Raspberry Pi Setup Commands:"
	@echo "============================="
	@echo "1. Copy script to Pi:"
	@echo "   scp rpi/rpicam-stream.sh dan7554@192.168.50.96:/home/dan7554/"
	@echo ""
	@echo "2. Copy service file:"
	@echo "   scp rpicam-stream.service dan7554@192.168.50.96:/home/dan7554/"
	@echo ""
	@echo "3. Install on Pi:"
	@echo "   ssh dan7554@192.168.50.96"
	@echo "   chmod +x /home/dan7554/rpicam-stream.sh"
	@echo "   sudo cp /home/dan7554/rpicam-stream.service /etc/systemd/system/"
	@echo "   sudo systemctl daemon-reload"
	@echo "   sudo systemctl enable rpicam-stream.service"
	@echo "   sudo systemctl start rpicam-stream.service"


# Quick commands
quick-start: config-check build run status ## Quick start (check config, build, run, show status)

quick-restart: stop run ## Quick restart

dev: run-dev ## Alias for run-dev

###############################################
# AWS ECR targets

.PHONY: ecr-login ecr-create ecr-push ecr-deploy ecr-info

ecr-info: ## 📋 Show ECR configuration info
	@echo "AWS ECR Configuration:"
	@echo "======================"
	@echo "🌍 Region: $(AWS_REGION)"
	@echo "📦 Repository: $(REPO_NAME)"
	@echo "🆔 Account ID: $(AWS_ACCOUNT_ID)"
	@echo "🔗 ECR URI: $(ECR_URI)"
	@echo ""
	@echo "Usage:"
	@echo "  make ecr-create    # Create ECR repository"
	@echo "  make ecr-deploy    # Build and push to ECR"

ecr-login: ## 🔐 Login to AWS ECR
	@echo "🔐 Logging into AWS ECR..."
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then \
		echo "❌ Error: AWS CLI not configured or no credentials found"; \
		echo "   Run: aws configure"; \
		exit 1; \
	fi
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
	@echo "✅ Successfully logged into ECR!"

ecr-create: ## 📦 Create ECR repository
	@echo "📦 Creating ECR repository: $(REPO_NAME)"
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then \
		echo "❌ Error: AWS CLI not configured"; \
		exit 1; \
	fi
	aws ecr create-repository \
		--repository-name $(REPO_NAME) \
		--region $(AWS_REGION) \
		--image-scanning-configuration scanOnPush=true \
		--encryption-configuration encryptionType=AES256 \
		2>/dev/null || echo "ℹ️  Repository '$(REPO_NAME)' might already exist"
	@echo "✅ ECR repository ready!"

ecr-push: build-cloud ecr-login ## ⬆️ Push image to ECR
	@echo "🏷️ Tagging image for ECR..."
	docker tag $(IMAGE_NAME):latest $(ECR_URI):latest
	docker tag $(IMAGE_NAME):latest $(ECR_URI):$(shell date +%Y%m%d-%H%M%S)
	@echo "⬆️ Pushing to ECR..."
	docker push $(ECR_URI):latest
	docker push $(ECR_URI):$(shell date +%Y%m%d-%H%M%S)
	@echo "✅ Successfully pushed to ECR!"
	@echo ""
	@echo "📋 Available tags:"
	@echo "   $(ECR_URI):latest"
	@echo "   $(ECR_URI):$(shell date +%Y%m%d-%H%M%S)"

ecr-deploy: ecr-create ecr-push ## 🚀 Full ECR deployment (create repo + push)
	@echo ""
	@echo "🚀 ECR deployment complete!"
	@echo "=========================="
	@echo "📋 Image URI: $(ECR_URI):latest"
	@echo ""
	@echo "🔧 Use this in your deployment:"
	@echo "   docker run -p 8554:8554 -p 8888:8888 -p 8889:8889 $(ECR_URI):latest"
	@echo ""
	@echo "🎯 For AWS services:"
	@echo "   ECS Task Definition: $(ECR_URI):latest"
	@echo "   EKS Deployment: $(ECR_URI):latest"

ecr-pull: ecr-login ## ⬇️ Pull image from ECR
	@echo "⬇️ Pulling latest image from ECR..."
	docker pull $(ECR_URI):latest
	docker tag $(ECR_URI):latest $(IMAGE_NAME):latest
	@echo "✅ Successfully pulled from ECR!"

ecr-list: ## 📋 List ECR images
	@echo "📋 ECR Images in $(REPO_NAME):"
	@echo "=============================="
	aws ecr list-images --repository-name $(REPO_NAME) --region $(AWS_REGION) --output table || echo "❌ Repository not found or no images"

ecr-clean: ## 🧹 Delete old ECR images (keeps latest 5)
	@echo "🧹 Cleaning old ECR images..."
	@echo "Keeping latest 5 images, deleting older ones..."
	aws ecr list-images \
		--repository-name $(REPO_NAME) \
		--region $(AWS_REGION) \
		--filter tagStatus=TAGGED \
		--query 'imageIds[?imageTag!=`latest`]' \
		--output json | \
	jq '.[5:] | map(select(.imageTag != "latest"))' | \
	aws ecr batch-delete-image \
		--repository-name $(REPO_NAME) \
		--region $(AWS_REGION) \
		--image-ids file:///dev/stdin || echo "No old images to clean"
	@echo "✅ ECR cleanup complete!"

###############################################
# AWS ECS targets

.PHONY: ecs-setup ecs-create-cluster ecs-create-task ecs-create-service ecs-deploy ecs-update ecs-logs ecs-status ecs-cleanup ecs-info ecs-get-url

ecs-info: ## 📋 Show ECS configuration info
	@echo "AWS ECS Configuration:"
	@echo "======================"
	@echo "🌍 Region: $(AWS_REGION)"
	@echo "🔗 ECR URI: $(ECR_URI):latest"
	@echo "🏗️  Cluster: $(ECS_CLUSTER_NAME)"
	@echo "⚙️  Service: $(ECS_SERVICE_NAME)"
	@echo "📋 Task Family: $(ECS_TASK_FAMILY)"
	@echo ""
	@echo "Current Status:"
	@echo "==============="
	@echo -n "🏗️  Cluster Status: "
	@aws ecs describe-clusters --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) --query 'clusters[0].status' --output text 2>/dev/null || echo "NOT_FOUND"
	@echo -n "⚙️  Service Status: "
	@aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].status' --output text 2>/dev/null || echo "NOT_FOUND"
	@echo ""
	@echo "Next steps:"
	@echo "  make ecs-setup     # Create all ECS resources"
	@echo "  make ecs-deploy    # Deploy your image to ECS"
	@echo ""
	@echo "🔍 IAM Role Status:"
	@echo "=================="
	@echo -n "🔐 ECS Execution Role: "
	@aws iam get-role --role-name ecsTaskExecutionRole --region $(AWS_REGION) --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND"

ecs-setup: ecs-create-role ecs-create-cluster ecs-create-logs ecs-create-security-group ecs-create-task ecs-create-service ## 🏗️ Set up complete ECS infrastructure
	@echo ""
	@echo "🚀 ECS setup complete!"
	@echo "Your MediaMTX service is being deployed..."
	@echo "Run 'make ecs-status' to check deployment progress"

ecs-create-role: ## 🔐 Create ECS execution role
	@echo "🔐 Creating ECS execution role..."
	@if aws iam get-role --role-name ecsTaskExecutionRole --region $(AWS_REGION) >/dev/null 2>&1; then \
		echo "✅ Role 'ecsTaskExecutionRole' already exists"; \
	else \
		echo "📝 Creating trust policy..."; \
		echo '{ \
			"Version": "2012-10-17", \
			"Statement": [ \
				{ \
					"Effect": "Allow", \
					"Principal": { \
						"Service": "ecs-tasks.amazonaws.com" \
					}, \
					"Action": "sts:AssumeRole" \
				} \
			] \
		}' > ecs-trust-policy.json; \
		echo "🏗️ Creating IAM role..."; \
		aws iam create-role \
			--role-name ecsTaskExecutionRole \
			--assume-role-policy-document file://ecs-trust-policy.json \
			--region $(AWS_REGION); \
		echo "🔗 Attaching managed policy..."; \
		aws iam attach-role-policy \
			--role-name ecsTaskExecutionRole \
			--policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
			--region $(AWS_REGION); \
		echo "⏳ Waiting for role to propagate..."; \
		sleep 10; \
		rm -f ecs-trust-policy.json; \
		echo "✅ ECS execution role created successfully!"; \
	fi

ecs-create-cluster: ## 🏗️ Create ECS cluster
	@echo "🏗️ Creating ECS cluster: $(ECS_CLUSTER_NAME)"
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then \
		echo "❌ Error: AWS CLI not configured"; \
		exit 1; \
	fi
	@echo "🔍 Checking if cluster already exists..."
	@CLUSTER_STATUS=$$(aws ecs describe-clusters --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) --query 'clusters[0].status' --output text 2>/dev/null); \
	if [ "$$CLUSTER_STATUS" = "ACTIVE" ]; then \
		echo "✅ Cluster '$(ECS_CLUSTER_NAME)' already exists and is active"; \
	elif [ "$$CLUSTER_STATUS" = "INACTIVE" ]; then \
		echo "🗑️  Found inactive cluster, deleting it first..."; \
		aws ecs delete-cluster --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) 2>/dev/null || true; \
		sleep 5; \
		echo "📦 Creating new cluster..."; \
		aws ecs create-cluster \
			--cluster-name $(ECS_CLUSTER_NAME) \
			--capacity-providers FARGATE \
			--default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
			--region $(AWS_REGION); \
		echo "⏳ Waiting for cluster to be ready..."; \
		for i in $$(seq 1 30); do \
			CLUSTER_STATUS=$$(aws ecs describe-clusters --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) --query 'clusters[0].status' --output text 2>/dev/null); \
			if [ "$$CLUSTER_STATUS" = "ACTIVE" ]; then \
				echo "✅ Cluster is now active!"; \
				break; \
			fi; \
			echo "⏳ Cluster status: $$CLUSTER_STATUS (attempt $$i/30)"; \
			sleep 2; \
		done; \
		if [ "$$CLUSTER_STATUS" != "ACTIVE" ]; then \
			echo "❌ Cluster failed to become active after 60 seconds"; \
			exit 1; \
		fi; \
	else \
		echo "📦 Creating new cluster..."; \
		aws ecs create-cluster \
			--cluster-name $(ECS_CLUSTER_NAME) \
			--capacity-providers FARGATE \
			--default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
			--region $(AWS_REGION); \
		echo "⏳ Waiting for cluster to be ready..."; \
		for i in $$(seq 1 30); do \
			CLUSTER_STATUS=$$(aws ecs describe-clusters --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) --query 'clusters[0].status' --output text 2>/dev/null); \
			if [ "$$CLUSTER_STATUS" = "ACTIVE" ]; then \
				echo "✅ Cluster is now active!"; \
				break; \
			fi; \
			echo "⏳ Cluster status: $$CLUSTER_STATUS (attempt $$i/30)"; \
			sleep 2; \
		done; \
		if [ "$$CLUSTER_STATUS" != "ACTIVE" ]; then \
			echo "❌ Cluster failed to become active after 60 seconds"; \
			exit 1; \
		fi; \
	fi
	@echo "✅ ECS cluster ready!"

ecs-create-logs: ## 📝 Create CloudWatch log group
	@echo "📝 Creating CloudWatch log group: $(ECS_LOG_GROUP)"
	aws logs create-log-group \
		--log-group-name $(ECS_LOG_GROUP) \
		--region $(AWS_REGION) 2>/dev/null || echo "Log group might already exist"
	@echo "✅ Log group ready!"

ecs-create-security-group: ## 🛡️ Create security group for MediaMTX
	@echo "🛡️ Creating security group for MediaMTX..."
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION)); \
	if [ "$$VPC_ID" = "None" ] || [ -z "$$VPC_ID" ]; then \
		echo "❌ Error: No default VPC found"; \
		exit 1; \
	fi; \
	echo "🌐 Using VPC: $$VPC_ID"; \
	SG_ID=$$(aws ec2 create-security-group \
		--group-name mediamtx-security-group \
		--description "Security group for MediaMTX ECS service" \
		--vpc-id $$VPC_ID \
		--region $(AWS_REGION) \
		--query 'GroupId' --output text 2>/dev/null || \
		aws ec2 describe-security-groups \
			--filters "Name=group-name,Values=mediamtx-security-group" "Name=vpc-id,Values=$$VPC_ID" \
			--query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION)); \
	echo "🛡️ Security Group ID: $$SG_ID"; \
	echo "🔓 Adding inbound rules..."; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--protocol tcp \
		--port 8554 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "RTSP rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--protocol tcp \
		--port 8888 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "HTTP API rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--protocol tcp \
		--port 8889 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "WebRTC rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--protocol tcp \
		--port 1935 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "RTMP rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--protocol tcp \
		--port 9996 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "SRT rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--protocol udp \
		--port 8890 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "UDP rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--protocol udp \
		--port 8189 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "WebRTC UDP rule might already exist"; \
	echo "✅ Security group configured with MediaMTX ports!"

ecs-create-task: ## 📋 Create ECS task definition
	@echo "📋 Creating ECS task definition..."
	@echo "Generating task definition JSON..."
	@echo '{' > task-definition.json
	@echo '    "family": "$(ECS_TASK_FAMILY)",' >> task-definition.json
	@echo '    "networkMode": "awsvpc",' >> task-definition.json
	@echo '    "requiresCompatibilities": ["FARGATE"],' >> task-definition.json
	@echo '    "cpu": "512",' >> task-definition.json
	@echo '    "memory": "1024",' >> task-definition.json
	@echo '    "executionRoleArn": "arn:aws:iam::$(AWS_ACCOUNT_ID):role/ecsTaskExecutionRole",' >> task-definition.json
	@echo '    "taskRoleArn": "arn:aws:iam::$(AWS_ACCOUNT_ID):role/ecsTaskExecutionRole",' >> task-definition.json
	@echo '    "containerDefinitions": [' >> task-definition.json
	@echo '        {' >> task-definition.json
	@echo '            "name": "mediamtx",' >> task-definition.json
	@echo '            "image": "$(ECR_URI):latest",' >> task-definition.json
	@echo '            "portMappings": [' >> task-definition.json
	@echo '                {"containerPort": 8554, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 8888, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 8889, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 1935, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 9996, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 8890, "protocol": "udp"},' >> task-definition.json
	@echo '                {"containerPort": 8189, "protocol": "udp"}' >> task-definition.json
	@echo '            ],' >> task-definition.json
	@echo '            "environment": [' >> task-definition.json
	@echo '                {"name": "MTX_RTSPTRANSPORTS", "value": "tcp"},' >> task-definition.json
	@echo '                {"name": "MTX_WEBRTCADDITIONALHOSTS", "value": "localhost"}' >> task-definition.json
	@echo '            ],' >> task-definition.json
	@echo '            "logConfiguration": {' >> task-definition.json
	@echo '                "logDriver": "awslogs",' >> task-definition.json
	@echo '                "options": {' >> task-definition.json
	@echo '                    "awslogs-group": "$(ECS_LOG_GROUP)",' >> task-definition.json
	@echo '                    "awslogs-region": "$(AWS_REGION)",' >> task-definition.json
	@echo '                    "awslogs-stream-prefix": "ecs"' >> task-definition.json
	@echo '                }' >> task-definition.json
	@echo '            },' >> task-definition.json
	@echo '            "essential": true,' >> task-definition.json
	@echo '            "healthCheck": {' >> task-definition.json
	@echo '                "command": ["CMD-SHELL", "nc -z localhost 8888 || exit 1"],' >> task-definition.json
	@echo '                "interval": 60,' >> task-definition.json
	@echo '                "timeout": 10,' >> task-definition.json
	@echo '                "retries": 3,' >> task-definition.json
	@echo '                "startPeriod": 120' >> task-definition.json
	@echo '            }' >> task-definition.json
	@echo '        }' >> task-definition.json
	@echo '    ]' >> task-definition.json
	@echo '}' >> task-definition.json
	aws ecs register-task-definition \
		--cli-input-json file://task-definition.json \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null
	@rm -f task-definition.json
	@echo "✅ Task definition registered!"

ecs-create-task-no-healthcheck: ## 📋 Create ECS task definition without health check
	@echo "📋 Creating ECS task definition (no health check)..."
	@echo "Generating task definition JSON..."
	@echo '{' > task-definition.json
	@echo '    "family": "$(ECS_TASK_FAMILY)",' >> task-definition.json
	@echo '    "networkMode": "awsvpc",' >> task-definition.json
	@echo '    "requiresCompatibilities": ["FARGATE"],' >> task-definition.json
	@echo '    "cpu": "512",' >> task-definition.json
	@echo '    "memory": "1024",' >> task-definition.json
	@echo '    "executionRoleArn": "arn:aws:iam::$(AWS_ACCOUNT_ID):role/ecsTaskExecutionRole",' >> task-definition.json
	@echo '    "taskRoleArn": "arn:aws:iam::$(AWS_ACCOUNT_ID):role/ecsTaskExecutionRole",' >> task-definition.json
	@echo '    "containerDefinitions": [' >> task-definition.json
	@echo '        {' >> task-definition.json
	@echo '            "name": "mediamtx",' >> task-definition.json
	@echo '            "image": "$(ECR_URI):latest",' >> task-definition.json
	@echo '            "portMappings": [' >> task-definition.json
	@echo '                {"containerPort": 8554, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 8888, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 8889, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 1935, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 9996, "protocol": "tcp"},' >> task-definition.json
	@echo '                {"containerPort": 8890, "protocol": "udp"},' >> task-definition.json
	@echo '                {"containerPort": 8189, "protocol": "udp"}' >> task-definition.json
	@echo '            ],' >> task-definition.json
	@echo '            "environment": [' >> task-definition.json
	@echo '                {"name": "MTX_RTSPTRANSPORTS", "value": "tcp"},' >> task-definition.json
	@echo '                {"name": "MTX_WEBRTCADDITIONALHOSTS", "value": "localhost"}' >> task-definition.json
	@echo '            ],' >> task-definition.json
	@echo '            "logConfiguration": {' >> task-definition.json
	@echo '                "logDriver": "awslogs",' >> task-definition.json
	@echo '                "options": {' >> task-definition.json
	@echo '                    "awslogs-group": "$(ECS_LOG_GROUP)",' >> task-definition.json
	@echo '                    "awslogs-region": "$(AWS_REGION)",' >> task-definition.json
	@echo '                    "awslogs-stream-prefix": "ecs"' >> task-definition.json
	@echo '                }' >> task-definition.json
	@echo '            },' >> task-definition.json
	@echo '            "essential": true' >> task-definition.json
	@echo '        }' >> task-definition.json
	@echo '    ]' >> task-definition.json
	@echo '}' >> task-definition.json
	aws ecs register-task-definition \
		--cli-input-json file://task-definition.json \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null
	@rm -f task-definition.json
	@echo "✅ Task definition registered (no health check)!"

ecs-create-service: ## ⚙️ Create ECS service (requires VPC setup)
	@echo "⚙️ Creating ECS service..."
	@echo "⚠️  Note: This will use your default VPC and custom security group"
	@echo "🔍 Verifying cluster exists..."
	@CLUSTER_STATUS=$$(aws ecs describe-clusters --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) --query 'clusters[0].status' --output text 2>/dev/null); \
	if [ "$$CLUSTER_STATUS" = "ACTIVE" ]; then \
		echo "✅ Cluster verified and active"; \
	elif [ "$$CLUSTER_STATUS" = "None" ] || [ -z "$$CLUSTER_STATUS" ]; then \
		echo "❌ Cluster not found. Creating cluster first..."; \
		$(MAKE) ecs-create-cluster; \
	else \
		echo "⚠️  Cluster exists but status is: $$CLUSTER_STATUS"; \
		echo "🔄 Proceeding anyway..."; \
	fi
	@echo "🔍 Getting default VPC info..."
	$(eval VPC_ID := $(shell aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION)))
	$(eval SUBNET_IDS := $(shell aws ec2 describe-subnets --filters "Name=vpc-id,Values=$(VPC_ID)" --query 'Subnets[0:2].SubnetId' --output text --region $(AWS_REGION) | tr '\t' ','))
	$(eval SG_ID := $(shell aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$(VPC_ID)" "Name=group-name,Values=mediamtx-security-group" --query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION) 2>/dev/null || aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$(VPC_ID)" "Name=group-name,Values=default" --query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION)))
	@if [ "$(VPC_ID)" = "None" ] || [ -z "$(VPC_ID)" ]; then \
		echo "❌ Error: No default VPC found. You need to create a VPC first."; \
		exit 1; \
	fi
	@echo "🌐 Using VPC: $(VPC_ID)"
	@echo "🔗 Using Subnets: $(SUBNET_IDS)"
	@echo "🛡️  Using Security Group: $(SG_ID)"
	@echo "🚀 Creating ECS service..."
	@if aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].status' --output text 2>/dev/null | grep -q "ACTIVE"; then \
		echo "ℹ️  Service '$(ECS_SERVICE_NAME)' already exists"; \
	else \
		aws ecs create-service \
			--cluster $(ECS_CLUSTER_NAME) \
			--service-name $(ECS_SERVICE_NAME) \
			--task-definition $(ECS_TASK_FAMILY) \
			--desired-count 1 \
			--launch-type FARGATE \
			--deployment-configuration "maximumPercent=100,minimumHealthyPercent=0,deploymentCircuitBreaker={enable=true,rollback=false}" \
			--network-configuration "awsvpcConfiguration={subnets=[$(SUBNET_IDS)],securityGroups=[$(SG_ID)],assignPublicIp=ENABLED}" \
			--region $(AWS_REGION) \
			--no-cli-pager > /dev/null; \
	fi
	@echo "✅ ECS service ready!"
	@echo "⏳ Service is starting up. This may take a few minutes..."
	@echo "💡 Run 'make ecs-status' to check progress"

ecs-deploy: ecr-push ecs-update ## 🚀 Deploy updated image to ECS
	@echo "🚀 Deployment complete!"

ecs-update: ## 🔄 Update ECS service with latest image
	@echo "🔄 Updating ECS service with latest image..."
	aws ecs update-service \
		--cluster $(ECS_CLUSTER_NAME) \
		--service $(ECS_SERVICE_NAME) \
		--deployment-configuration "maximumPercent=200,minimumHealthyPercent=100,deploymentCircuitBreaker={enable=false,rollback=false}" \
		--force-new-deployment \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null
	@echo "✅ Service update initiated!"

ecs-update-security-group: ## 🛡️ Update ECS service to use MediaMTX security group
	@echo "🛡️ Updating ECS service security group..."
	@echo "🔍 Getting VPC and security group info..."
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION)); \
	SUBNET_IDS=$$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$$VPC_ID" --query 'Subnets[0:2].SubnetId' --output text --region $(AWS_REGION) | tr '\t' ','); \
	SG_ID=$$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$$VPC_ID" "Name=group-name,Values=mediamtx-security-group" --query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION) 2>/dev/null); \
	if [ "$$SG_ID" = "None" ] || [ -z "$$SG_ID" ]; then \
		echo "❌ MediaMTX security group not found. Creating it first..."; \
		$(MAKE) ecs-create-security-group; \
		SG_ID=$$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$$VPC_ID" "Name=group-name,Values=mediamtx-security-group" --query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION)); \
	fi; \
	echo "🛡️ Using Security Group: $$SG_ID"; \
	echo "🔄 Updating service network configuration..."; \
	aws ecs update-service \
		--cluster $(ECS_CLUSTER_NAME) \
		--service $(ECS_SERVICE_NAME) \
		--network-configuration "awsvpcConfiguration={subnets=[$$SUBNET_IDS],securityGroups=[$$SG_ID],assignPublicIp=ENABLED}" \
		--deployment-configuration "maximumPercent=100,minimumHealthyPercent=0,deploymentCircuitBreaker={enable=true,rollback=false}" \
		--force-new-deployment \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null
	@echo "✅ Service security group updated!"

ecs-status: ## 📊 Show ECS service status
	@echo "📊 ECS Service Status:"
	@echo "======================"
	@aws ecs describe-services \
		--cluster $(ECS_CLUSTER_NAME) \
		--services $(ECS_SERVICE_NAME) \
		--region $(AWS_REGION) \
		--query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount}' \
		--output table 2>/dev/null || echo "❌ Service not found"
	@echo ""
	@echo "📋 Task Status:"
	@echo "==============="
	@TASK_ARN=$$(aws ecs list-tasks --cluster $(ECS_CLUSTER_NAME) --service-name $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'taskArns[0]' --output text 2>/dev/null); \
	if [ "$$TASK_ARN" = "None" ] || [ -z "$$TASK_ARN" ] || [ "$$TASK_ARN" = "null" ]; then \
		echo "🔍 No running tasks found"; \
		echo "💡 Service might be starting up or stopped"; \
	else \
		echo "🔍 Found task: $$TASK_ARN"; \
		aws ecs describe-tasks \
			--cluster $(ECS_CLUSTER_NAME) \
			--tasks $$TASK_ARN \
			--region $(AWS_REGION) \
			--query 'tasks[0].{TaskArn:taskArn,LastStatus:lastStatus,DesiredStatus:desiredStatus,HealthStatus:healthStatus,CreatedAt:createdAt}' \
			--output table 2>/dev/null || echo "❌ Could not describe task"; \
	fi
	@echo ""
	@echo "🔄 Recent Task Events:"
	@echo "======================"
	@aws ecs describe-services \
		--cluster $(ECS_CLUSTER_NAME) \
		--services $(ECS_SERVICE_NAME) \
		--region $(AWS_REGION) \
		--query 'services[0].events[0:3].{Time:createdAt,Message:message}' \
		--output table 2>/dev/null || echo "❌ No service events found"

ecs-logs: ## 📝 Show ECS service logs
	@echo "📝 Recent ECS logs:"
	@echo "=================="
	aws logs tail $(ECS_LOG_GROUP) --follow --region $(AWS_REGION)

ecs-get-url: ## 🌐 Get public URL of ECS service
	@echo "🌐 Getting ECS service public IP..."
	@echo "⏳ Waiting for task to be running..."
	@for i in $$(seq 1 60); do \
		TASK_ARN=$$(aws ecs list-tasks --cluster $(ECS_CLUSTER_NAME) --service-name $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'taskArns[0]' --output text 2>/dev/null); \
		if [ "$$TASK_ARN" != "None" ] && [ -n "$$TASK_ARN" ] && [ "$$TASK_ARN" != "null" ]; then \
			TASK_STATUS=$$(aws ecs describe-tasks --cluster $(ECS_CLUSTER_NAME) --tasks $$TASK_ARN --region $(AWS_REGION) --query 'tasks[0].lastStatus' --output text 2>/dev/null); \
			if [ "$$TASK_STATUS" = "RUNNING" ]; then \
				echo "✅ Task is now running!"; \
				break; \
			else \
				echo "⏳ Task status: $$TASK_STATUS (attempt $$i/60)"; \
			fi; \
		else \
			echo "⏳ No tasks found yet (attempt $$i/60)"; \
		fi; \
		sleep 5; \
	done; \
	TASK_ARN=$$(aws ecs list-tasks --cluster $(ECS_CLUSTER_NAME) --service-name $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'taskArns[0]' --output text 2>/dev/null); \
	if [ "$$TASK_ARN" = "None" ] || [ -z "$$TASK_ARN" ] || [ "$$TASK_ARN" = "null" ]; then \
		echo "❌ No running tasks found after waiting"; \
		echo "💡 Make sure your service is running with 'make ecs-status'"; \
	else \
		TASK_STATUS=$$(aws ecs describe-tasks --cluster $(ECS_CLUSTER_NAME) --tasks $$TASK_ARN --region $(AWS_REGION) --query 'tasks[0].lastStatus' --output text 2>/dev/null); \
		if [ "$$TASK_STATUS" != "RUNNING" ]; then \
			echo "⚠️  Task is not in RUNNING state (current: $$TASK_STATUS)"; \
			echo "💡 Check task status with 'make ecs-status' and try again"; \
		else \
			echo "🔍 Found running task: $$TASK_ARN"; \
			echo "🔍 Found running task: $$TASK_ARN"; \
			ENI_ID=$$(aws ecs describe-tasks --cluster $(ECS_CLUSTER_NAME) --tasks $$TASK_ARN --region $(AWS_REGION) --query 'tasks[0].attachments[0].details' | grep -A1 '"name": "networkInterfaceId"' | grep '"value"' | cut -d'"' -f4); \
			if [ -z "$$ENI_ID" ]; then \
				echo "❌ Could not get network interface ID"; \
				echo "🔍 Debugging task attachments..."; \
				aws ecs describe-tasks --cluster $(ECS_CLUSTER_NAME) --tasks $$TASK_ARN --region $(AWS_REGION) --query 'tasks[0].attachments[0].details[]' --output table; \
			else \
				echo "🔍 Network Interface: $$ENI_ID"; \
				PUBLIC_IP=$$(aws ec2 describe-network-interfaces --network-interface-ids $$ENI_ID --region $(AWS_REGION) --query 'NetworkInterfaces[0].Association.PublicIp' --output text 2>/dev/null); \
				if [ "$$PUBLIC_IP" = "None" ] || [ -z "$$PUBLIC_IP" ] || [ "$$PUBLIC_IP" = "null" ]; then \
					echo "❌ Could not get public IP. Task might not have public IP assigned."; \
					echo "🔍 Checking if public IP is enabled..."; \
					aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp' --output text; \
				else \
					echo "✅ Found public IP: $$PUBLIC_IP"; \
					echo "🎯 MediaMTX URLs:"; \
					echo "  📺 Web UI: http://$$PUBLIC_IP:8888"; \
					echo "  📡 RTSP: rtsp://$$PUBLIC_IP:8554"; \
					echo "  🌐 WebRTC: http://$$PUBLIC_IP:8889"; \
					echo "  📹 RTMP: rtmp://$$PUBLIC_IP:1935"; \
					echo ""; \
					echo "🧪 Testing Web UI connection..."; \
					HTTP_STATUS=$$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://$$PUBLIC_IP:8888/ 2>/dev/null || echo "000"); \
					if [ "$$HTTP_STATUS" = "404" ]; then \
						echo "✅ MediaMTX server is responding (HTTP $$HTTP_STATUS)"; \
						echo "💡 Try accessing the web interface in your browser"; \
					elif [ "$$HTTP_STATUS" = "200" ]; then \
						echo "✅ MediaMTX server is responding (HTTP $$HTTP_STATUS)"; \
					elif [ "$$HTTP_STATUS" = "000" ]; then \
						echo "❌ Connection failed - check security group rules or server status"; \
					else \
						echo "⚠️  Server responded with HTTP $$HTTP_STATUS"; \
					fi; \
				fi; \
			fi; \
		fi; \
	fi

ecs-cleanup: ## 🧹 Delete ECS service and cluster
	@echo "🧹 Cleaning up ECS resources..."
	@echo "🛑 Stopping all tasks..."
	-aws ecs list-tasks --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) --query 'taskArns[]' --output text | xargs -n1 -I {} aws ecs stop-task --cluster $(ECS_CLUSTER_NAME) --task {} --region $(AWS_REGION) 2>/dev/null || true
	@echo "⏳ Waiting for tasks to stop..."
	@for i in $$(seq 1 30); do \
		TASK_COUNT=$$(aws ecs list-tasks --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) --query 'length(taskArns)' --output text 2>/dev/null || echo "0"); \
		if [ "$$TASK_COUNT" = "0" ]; then \
			echo "✅ All tasks stopped"; \
			break; \
		fi; \
		echo "⏳ Still $$TASK_COUNT tasks running (attempt $$i/30)"; \
		sleep 2; \
	done
	@echo "🗑️  Scaling down service..."
	-aws ecs update-service --cluster $(ECS_CLUSTER_NAME) --service $(ECS_SERVICE_NAME) --desired-count 0 --region $(AWS_REGION)
	@echo "🗑️  Deleting service..."
	-aws ecs delete-service --cluster $(ECS_CLUSTER_NAME) --service $(ECS_SERVICE_NAME) --region $(AWS_REGION)
	@echo "🗑️  Deleting cluster..."
	-aws ecs delete-cluster --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION)
	@echo "🗑️  Deleting log group..."
	-aws logs delete-log-group --log-group-name $(ECS_LOG_GROUP) --region $(AWS_REGION)
	@echo "✅ ECS cleanup complete!"

ecs-create-role-only: ## 🔐 Create just the ECS execution role
	@echo "🔐 Creating ECS execution role..."
	@$(MAKE) ecs-create-role

ecs-check-role: ## 🔍 Check if ECS execution role exists
	@echo "🔍 Checking ECS execution role..."
	@if aws iam get-role --role-name ecsTaskExecutionRole --region $(AWS_REGION) >/dev/null 2>&1; then \
		echo "✅ Role 'ecsTaskExecutionRole' exists"; \
		echo "📋 Role details:"; \
		aws iam get-role --role-name ecsTaskExecutionRole --region $(AWS_REGION) --query 'Role.{RoleName:RoleName,Created:CreateDate,Arn:Arn}' --output table; \
		echo "🔗 Attached policies:"; \
		aws iam list-attached-role-policies --role-name ecsTaskExecutionRole --region $(AWS_REGION) --output table; \
	else \
		echo "❌ Role 'ecsTaskExecutionRole' does not exist"; \
		echo "💡 Run 'make ecs-create-role-only' to create it"; \
	fi

###############################################
# AWS ALB targets for domain access

.PHONY: alb-create alb-create-target-group alb-create-listener alb-update-service alb-get-dns alb-cleanup alb-info

alb-info: ## 📋 Show ALB configuration info
	@echo "AWS ALB Configuration:"
	@echo "======================"
	@echo "🌍 Region: $(AWS_REGION)"
	@echo "🔗 ALB Name: $(ALB_NAME)"
	@echo "🎯 Target Group: $(TARGET_GROUP_NAME)"
	@echo "🌐 Domain: $(DOMAIN_NAME)"
	@echo "🔒 Certificate ARN: $(CERTIFICATE_ARN)"
	@echo ""
	@echo "Current Status:"
	@echo "==============="
	@echo -n "🔗 ALB Status: "
	@aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "NOT_FOUND"
	@echo -n "🎯 Target Group Status: "
	@aws elbv2 describe-target-groups --names $(TARGET_GROUP_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | sed 's/.*/FOUND/' || echo "NOT_FOUND"

alb-create: alb-create-target-group alb-create-alb alb-create-listener ## 🔗 Create complete ALB setup
	@echo ""
	@echo "✅ ALB setup complete!"
	@echo "Next steps:"
	@echo "1. Update your service: make alb-update-service"
	@echo "2. Get DNS name: make alb-get-dns"
	@echo "3. Point your domain to the ALB DNS name"

alb-create-target-group: ## 🎯 Create ALB target group
	@echo "🎯 Creating ALB target group..."
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION)); \
	if [ "$$VPC_ID" = "None" ] || [ -z "$$VPC_ID" ]; then \
		echo "❌ Error: No default VPC found"; \
		exit 1; \
	fi; \
	echo "🌐 Using VPC: $$VPC_ID"; \
	TG_ARN=$$(aws elbv2 create-target-group \
		--name $(TARGET_GROUP_NAME) \
		--protocol HTTP \
		--port 8888 \
		--vpc-id $$VPC_ID \
		--target-type ip \
		--health-check-protocol HTTP \
		--health-check-path "/" \
		--health-check-interval-seconds 60 \
		--health-check-timeout-seconds 30 \
		--healthy-threshold-count 2 \
		--unhealthy-threshold-count 5 \
		--region $(AWS_REGION) \
		--query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || \
		aws elbv2 describe-target-groups --names $(TARGET_GROUP_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text); \
	echo "🎯 Target Group ARN: $$TG_ARN"; \
	echo "✅ Target group ready!"

alb-create-alb: ## 🔗 Create Application Load Balancer
	@echo "🔗 Creating Application Load Balancer..."
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION)); \
	SUBNET_IDS=$$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$$VPC_ID" --query 'Subnets[].SubnetId' --output text --region $(AWS_REGION) | tr '\t' ' '); \
	echo "🛡️ Creating ALB security group..."; \
	ALB_SG_ID=$$(aws ec2 create-security-group \
		--group-name mediamtx-alb-security-group \
		--description "Security group for MediaMTX Application Load Balancer" \
		--vpc-id $$VPC_ID \
		--region $(AWS_REGION) \
		--query 'GroupId' --output text 2>/dev/null || \
		aws ec2 describe-security-groups \
			--filters "Name=group-name,Values=mediamtx-alb-security-group" "Name=vpc-id,Values=$$VPC_ID" \
			--query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION)); \
	echo "🛡️ ALB Security Group ID: $$ALB_SG_ID"; \
	echo "🔓 Adding ALB inbound rules..."; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 80 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "HTTP rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 443 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "HTTPS rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 8554 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "RTSP rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 8888 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "HTTP API rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 8889 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "WebRTC rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 1935 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "RTMP rule might already exist"; \
	echo "🔗 Using Subnets: $$SUBNET_IDS"; \
	ALB_ARN=$$(aws elbv2 create-load-balancer \
		--name $(ALB_NAME) \
		--subnets $$SUBNET_IDS \
		--security-groups $$ALB_SG_ID \
		--scheme internet-facing \
		--type application \
		--ip-address-type ipv4 \
		--region $(AWS_REGION) \
		--query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || \
		aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].LoadBalancerArn' --output text); \
	echo "🔗 ALB ARN: $$ALB_ARN"; \
	echo "✅ Application Load Balancer ready!"

alb-create-listener: ## 👂 Create ALB listener
	@echo "👂 Creating ALB listener..."
	@ALB_ARN=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].LoadBalancerArn' --output text); \
	TG_ARN=$$(aws elbv2 describe-target-groups --names $(TARGET_GROUP_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text); \
	if [ -n "$(CERTIFICATE_ARN)" ]; then \
		echo "🔒 Creating HTTPS listener with SSL certificate..."; \
		aws elbv2 create-listener \
			--load-balancer-arn $$ALB_ARN \
			--protocol HTTPS \
			--port 443 \
			--certificates CertificateArn=$(CERTIFICATE_ARN) \
			--default-actions Type=forward,TargetGroupArn=$$TG_ARN \
			--region $(AWS_REGION) 2>/dev/null || echo "HTTPS listener might already exist"; \
		echo "🔀 Creating HTTP to HTTPS redirect..."; \
		aws elbv2 create-listener \
			--load-balancer-arn $$ALB_ARN \
			--protocol HTTP \
			--port 80 \
			--default-actions Type=redirect,RedirectConfig='{Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' \
			--region $(AWS_REGION) 2>/dev/null || echo "HTTP redirect might already exist"; \
	else \
		echo "🌐 Creating HTTP listener (no SSL certificate provided)..."; \
		aws elbv2 create-listener \
			--load-balancer-arn $$ALB_ARN \
			--protocol HTTP \
			--port 80 \
			--default-actions Type=forward,TargetGroupArn=$$TG_ARN \
			--region $(AWS_REGION) 2>/dev/null || echo "HTTP listener might already exist"; \
		echo "⚠️  Note: Using HTTP only. For HTTPS, set CERTIFICATE_ARN variable"; \
	fi; \
	echo "✅ Listener configured!"

alb-update-service: ## 🔄 Update ECS service to use ALB
	@echo "🔄 Updating ECS service to use ALB..."
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION)); \
	SUBNET_IDS=$$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$$VPC_ID" --query 'Subnets[0:2].SubnetId' --output text --region $(AWS_REGION) | tr '\t' ','); \
	SG_ID=$$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$$VPC_ID" "Name=group-name,Values=mediamtx-security-group" --query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION)); \
	TG_ARN=$$(aws elbv2 describe-target-groups --names $(TARGET_GROUP_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text); \
	echo "🎯 Target Group ARN: $$TG_ARN"; \
	aws ecs update-service \
		--cluster $(ECS_CLUSTER_NAME) \
		--service $(ECS_SERVICE_NAME) \
		--load-balancers targetGroupArn=$$TG_ARN,containerName=mediamtx,containerPort=8888 \
		--network-configuration "awsvpcConfiguration={subnets=[$$SUBNET_IDS],securityGroups=[$$SG_ID],assignPublicIp=ENABLED}" \
		--deployment-configuration "maximumPercent=100,minimumHealthyPercent=0,deploymentCircuitBreaker={enable=true,rollback=false}" \
		--force-new-deployment \
		--region $(AWS_REGION); \
	echo "✅ Service updated to use ALB!"

alb-get-dns: ## 🌐 Get ALB DNS name
	@echo "🌐 Getting ALB DNS name..."
	@ALB_DNS=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null); \
	if [ "$$ALB_DNS" = "None" ] || [ -z "$$ALB_DNS" ]; then \
		echo "❌ ALB not found. Create it first with 'make alb-create'"; \
	else \
		echo "✅ ALB DNS Name: $$ALB_DNS"; \
		echo ""; \
		echo "🎯 MediaMTX URLs through ALB:"; \
		if [ -n "$(CERTIFICATE_ARN)" ]; then \
			echo "  📺 Web UI: https://$(DOMAIN_NAME):8888"; \
			echo "  📡 RTSP: rtsp://$(DOMAIN_NAME):8554"; \
			echo "  🌐 WebRTC: https://$(DOMAIN_NAME):8889"; \
			echo "  📹 RTMP: rtmp://$(DOMAIN_NAME):1935"; \
		else \
			echo "  📺 Web UI: http://$$ALB_DNS"; \
			echo "  📡 RTSP: rtsp://$$ALB_DNS:8554"; \
			echo "  🌐 WebRTC: http://$$ALB_DNS:8889"; \
			echo "  📹 RTMP: rtmp://$$ALB_DNS:1935"; \
		fi; \
		echo ""; \
		echo "🔧 DNS Setup Instructions:"; \
		echo "1. Create a CNAME record in your DNS:"; \
		echo "   $(DOMAIN_NAME) → $$ALB_DNS"; \
		echo "2. Update your Raspberry Pi to use: $(DOMAIN_NAME)"; \
		echo ""; \
		echo "🧪 Testing ALB connection..."; \
		HTTP_STATUS=$$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://$$ALB_DNS/ 2>/dev/null || echo "000"); \
		if [ "$$HTTP_STATUS" = "404" ] || [ "$$HTTP_STATUS" = "200" ]; then \
			echo "✅ ALB is responding (HTTP $$HTTP_STATUS)"; \
		elif [ "$$HTTP_STATUS" = "000" ]; then \
			echo "❌ Connection failed - ALB might still be starting"; \
		else \
			echo "⚠️  ALB responded with HTTP $$HTTP_STATUS"; \
		fi; \
	fi

alb-cleanup: ## 🧹 Delete ALB and related resources
	@echo "🧹 Cleaning up ALB resources..."
	@echo "🗑️ Deleting listeners..."
	-ALB_ARN=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null); \
	if [ "$$ALB_ARN" != "None" ] && [ -n "$$ALB_ARN" ]; then \
		aws elbv2 describe-listeners --load-balancer-arn $$ALB_ARN --region $(AWS_REGION) --query 'Listeners[].ListenerArn' --output text | xargs -n1 -I {} aws elbv2 delete-listener --listener-arn {} --region $(AWS_REGION) 2>/dev/null || true; \
	fi
	@echo "🗑️ Deleting load balancer..."
	-aws elbv2 delete-load-balancer --load-balancer-arn $$ALB_ARN --region $(AWS_REGION) 2>/dev/null || true
	@echo "🗑️ Deleting target group..."
	-TG_ARN=$$(aws elbv2 describe-target-groups --names $(TARGET_GROUP_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null); \
	if [ "$$TG_ARN" != "None" ] && [ -n "$$TG_ARN" ]; then \
		aws elbv2 delete-target-group --target-group-arn $$TG_ARN --region $(AWS_REGION) 2>/dev/null || true; \
	fi
	@echo "✅ ALB cleanup complete!"

alb-fix-security-group: ## 🛡️ Fix ALB security group to allow traffic
	@echo "🛡️ Fixing ALB security group..."
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION)); \
	if [ "$$VPC_ID" = "None" ] || [ -z "$$VPC_ID" ]; then \
		echo "❌ Error: No default VPC found"; \
		exit 1; \
	fi; \
	echo "🌐 Using VPC: $$VPC_ID"; \
	echo "🔍 Creating/finding ALB security group..."; \
	ALB_SG_ID=$$(aws ec2 create-security-group \
		--group-name mediamtx-alb-security-group \
		--description "Security group for MediaMTX Application Load Balancer" \
		--vpc-id $$VPC_ID \
		--region $(AWS_REGION) \
		--query 'GroupId' --output text 2>/dev/null || \
		aws ec2 describe-security-groups \
			--filters "Name=group-name,Values=mediamtx-alb-security-group" "Name=vpc-id,Values=$$VPC_ID" \
			--query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION)); \
	echo "🛡️ ALB Security Group ID: $$ALB_SG_ID"; \
	echo "🔓 Adding ALB inbound rules..."; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 80 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "HTTP rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 443 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "HTTPS rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 8554 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "RTSP rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 8888 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "HTTP API rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 8889 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "WebRTC rule might already exist"; \
	aws ec2 authorize-security-group-ingress \
		--group-id $$ALB_SG_ID \
		--protocol tcp \
		--port 1935 \
		--cidr 0.0.0.0/0 \
		--region $(AWS_REGION) 2>/dev/null || echo "RTMP rule might already exist"; \
	echo "🔄 Updating ALB to use new security group..."; \
	ALB_ARN=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].LoadBalancerArn' --output text); \
	if [ "$$ALB_ARN" != "None" ] && [ -n "$$ALB_ARN" ]; then \
		aws elbv2 set-security-groups \
			--load-balancer-arn $$ALB_ARN \
			--security-groups $$ALB_SG_ID \
			--region $(AWS_REGION); \
		echo "✅ ALB security group updated!"; \
	else \
		echo "❌ ALB not found"; \
		exit 1; \
	fi; \
	echo ""; \
	echo "🧪 Testing ALB connectivity..."; \
	sleep 5; \
	ALB_DNS=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].DNSName' --output text); \
	if [ -n "$$ALB_DNS" ]; then \
		HTTP_STATUS=$$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 http://$$ALB_DNS/ 2>/dev/null || echo "000"); \
		if [ "$$HTTP_STATUS" = "404" ] || [ "$$HTTP_STATUS" = "200" ]; then \
			echo "✅ ALB is now responding (HTTP $$HTTP_STATUS)"; \
			echo "🎯 Try your domain: http://$(DOMAIN_NAME):8888/"; \
		else \
			echo "⚠️  ALB responded with HTTP $$HTTP_STATUS (may still be starting)"; \
		fi; \
	fi

alb-add-listeners: ## 🎧 Add ALB listeners for all MediaMTX ports
	@echo "🎧 Adding ALB listeners for all MediaMTX ports..."
	@ALB_ARN=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null); \
	if [ "$$ALB_ARN" = "None" ] || [ -z "$$ALB_ARN" ]; then \
		echo "❌ ALB not found - create it first with 'make alb-create'"; \
		exit 1; \
	fi; \
	TARGET_GROUP_ARN=$$(aws elbv2 describe-target-groups --names $(TARGET_GROUP_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null); \
	if [ "$$TARGET_GROUP_ARN" = "None" ] || [ -z "$$TARGET_GROUP_ARN" ]; then \
		echo "❌ Target group not found - create it first with 'make alb-create'"; \
		exit 1; \
	fi; \
	echo "🎧 Adding listener for port 8554 (RTSP)..."; \
	aws elbv2 create-listener \
		--load-balancer-arn $$ALB_ARN \
		--protocol TCP \
		--port 8554 \
		--default-actions Type=forward,TargetGroupArn=$$TARGET_GROUP_ARN \
		--region $(AWS_REGION) 2>/dev/null || echo "   Listener 8554 might already exist"; \
	echo "🎧 Adding listener for port 8888 (Web Interface)..."; \
	aws elbv2 create-listener \
		--load-balancer-arn $$ALB_ARN \
		--protocol HTTP \
		--port 8888 \
		--default-actions Type=forward,TargetGroupArn=$$TARGET_GROUP_ARN \
		--region $(AWS_REGION) 2>/dev/null || echo "   Listener 8888 might already exist"; \
	echo "🎧 Adding listener for port 8889 (WebRTC)..."; \
	aws elbv2 create-listener \
		--load-balancer-arn $$ALB_ARN \
		--protocol HTTP \
		--port 8889 \
		--default-actions Type=forward,TargetGroupArn=$$TARGET_GROUP_ARN \
		--region $(AWS_REGION) 2>/dev/null || echo "   Listener 8889 might already exist"; \
	echo "🎧 Adding listener for port 1935 (RTMP)..."; \
	aws elbv2 create-listener \
		--load-balancer-arn $$ALB_ARN \
		--protocol HTTP \
		--port 1935 \
		--default-actions Type=forward,TargetGroupArn=$$TARGET_GROUP_ARN \
		--region $(AWS_REGION) 2>/dev/null || echo "   Listener 1935 might already exist"; \
	echo "✅ ALB listeners configured!"; \
	echo "🎯 You can now access:"; \
	ALB_DNS=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].DNSName' --output text); \
	echo "   🌐 Web Interface: http://$(DOMAIN_NAME):8888/"; \
	echo "   📡 RTSP Stream: rtsp://$(DOMAIN_NAME):8554/cam"; \
	echo "   🎥 WebRTC: http://$(DOMAIN_NAME):8889/"; \
	echo "   📺 RTMP: rtmp://$(DOMAIN_NAME):1935/"

dns-create-rtsp-record: ## 🎯 Create A record for RTSP pointing to current ECS task IP
	@echo "🎯 Creating RTSP A record..."
	@echo "⏳ Waiting for ECS tasks to be running (max 120 seconds)..."; \
	TASK_ARN=""; \
	for i in {1..24}; do \
		TASK_ARN=$$(aws ecs list-tasks --cluster $(ECS_CLUSTER_NAME) --desired-status RUNNING --region $(AWS_REGION) --query 'taskArns[0]' --output text); \
		if [ "$$TASK_ARN" != "None" ] && [ -n "$$TASK_ARN" ]; then \
			echo "✅ Task found: $$TASK_ARN"; \
			break; \
		fi; \
		echo "⏳ Waiting... ($$(($$i * 5)) seconds elapsed)"; \
		sleep 5; \
	done; \
	if [ "$$TASK_ARN" = "None" ] || [ -z "$$TASK_ARN" ]; then \
		echo "❌ No running tasks found after waiting"; \
		exit 1; \
	fi; \
	echo "⏳ Waiting for task to get public IP (max 30 seconds)..."; \
	NETWORK_INTERFACE_ID=""; \
	PUBLIC_IP=""; \
	for j in {1..6}; do \
		NETWORK_INTERFACE_ID=$$(aws ecs describe-tasks --cluster $(ECS_CLUSTER_NAME) --tasks $$TASK_ARN --region $(AWS_REGION) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text); \
		if [ "$$NETWORK_INTERFACE_ID" != "None" ] && [ -n "$$NETWORK_INTERFACE_ID" ]; then \
			PUBLIC_IP=$$(aws ec2 describe-network-interfaces --network-interface-ids $$NETWORK_INTERFACE_ID --region $(AWS_REGION) --query 'NetworkInterfaces[0].Association.PublicIp' --output text 2>/dev/null); \
			if [ "$$PUBLIC_IP" != "None" ] && [ -n "$$PUBLIC_IP" ]; then \
				echo "✅ Public IP acquired: $$PUBLIC_IP"; \
				break; \
			fi; \
		fi; \
		if [ $$j -lt 6 ]; then \
			echo "⏳ Waiting for public IP... (attempt $$j/6)"; \
			sleep 5; \
		fi; \
	done; \
	if [ "$$PUBLIC_IP" = "None" ] || [ -z "$$PUBLIC_IP" ]; then \
		echo "❌ No public IP found for task after waiting"; \
		exit 1; \
	fi; \
	echo "📍 ECS Task Public IP: $$PUBLIC_IP"; \
	BASE_DOMAIN=$$(echo "$(DOMAIN_NAME)" | sed 's/^[^.]*\.//' | tr -d ' '); \
	echo "🌐 Base domain: $$BASE_DOMAIN"; \
	HOSTED_ZONE_ID=$$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$$BASE_DOMAIN.'].Id" --output text | sed 's/.*\///'); \
	if [ "$$HOSTED_ZONE_ID" = "None" ] || [ -z "$$HOSTED_ZONE_ID" ]; then \
		echo "❌ Hosted zone for $$BASE_DOMAIN not found"; \
		exit 1; \
	fi; \
	echo "🌐 Using hosted zone: $$HOSTED_ZONE_ID"; \
	echo "🔗 Creating A record: rtsp.$$BASE_DOMAIN → $$PUBLIC_IP"; \
	aws route53 change-resource-record-sets --hosted-zone-id $$HOSTED_ZONE_ID --change-batch '{ \
		"Changes": [{ \
			"Action": "UPSERT", \
			"ResourceRecordSet": { \
				"Name": "rtsp.'$$BASE_DOMAIN'", \
				"Type": "A", \
				"TTL": 60, \
				"ResourceRecords": [{"Value": "'$$PUBLIC_IP'"}] \
			} \
		}] \
	}' --region $(AWS_REGION); \
	echo "✅ RTSP A record created!"; \
	echo "🎯 RTSP endpoint: rtsp://rtsp.$$BASE_DOMAIN:8554/rpicam2"

dns-create-admin-record: ## 🎯 Create A record for admin.racetrackstreaming.com pointing to broadcast ECS task
	@echo "🎯 Creating admin broadcast A record..."
	@echo "⏳ Waiting for ECS tasks to be running (max 120 seconds)..."; \
	TASK_ARN=""; \
	for i in {1..24}; do \
		TASK_ARN=$$(aws ecs list-tasks --cluster $(BROADCAST_ECS_CLUSTER) --desired-status RUNNING --region $(AWS_REGION) --query 'taskArns[0]' --output text); \
		if [ "$$TASK_ARN" != "None" ] && [ -n "$$TASK_ARN" ]; then \
			echo "✅ Task found: $$TASK_ARN"; \
			break; \
		fi; \
		echo "⏳ Waiting... ($$(($$i * 5)) seconds elapsed)"; \
		sleep 5; \
	done; \
	if [ "$$TASK_ARN" = "None" ] || [ -z "$$TASK_ARN" ]; then \
		echo "❌ No running tasks found after waiting"; \
		exit 1; \
	fi; \
	echo "⏳ Waiting for task to get public IP (max 30 seconds)..."; \
	NETWORK_INTERFACE_ID=""; \
	PUBLIC_IP=""; \
	for j in {1..6}; do \
		NETWORK_INTERFACE_ID=$$(aws ecs describe-tasks --cluster $(BROADCAST_ECS_CLUSTER) --tasks $$TASK_ARN --region $(AWS_REGION) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text); \
		if [ "$$NETWORK_INTERFACE_ID" != "None" ] && [ -n "$$NETWORK_INTERFACE_ID" ]; then \
			PUBLIC_IP=$$(aws ec2 describe-network-interfaces --network-interface-ids $$NETWORK_INTERFACE_ID --region $(AWS_REGION) --query 'NetworkInterfaces[0].Association.PublicIp' --output text 2>/dev/null); \
			if [ "$$PUBLIC_IP" != "None" ] && [ -n "$$PUBLIC_IP" ]; then \
				echo "✅ Public IP acquired: $$PUBLIC_IP"; \
				break; \
			fi; \
		fi; \
		if [ $$j -lt 6 ]; then \
			echo "⏳ Waiting for public IP... (attempt $$j/6)"; \
			sleep 5; \
		fi; \
	done; \
	if [ "$$PUBLIC_IP" = "None" ] || [ -z "$$PUBLIC_IP" ]; then \
		echo "❌ No public IP found for task after waiting"; \
		exit 1; \
	fi; \
	echo "📍 Broadcast Task Public IP: $$PUBLIC_IP"; \
	BASE_DOMAIN=$$(echo "$(BROADCAST_DOMAIN)" | sed 's/^[^.]*\.//' | tr -d ' '); \
	echo "🌐 Base domain: $$BASE_DOMAIN"; \
	HOSTED_ZONE_ID=$$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$$BASE_DOMAIN.'].Id" --output text | sed 's/.*\///'); \
	if [ "$$HOSTED_ZONE_ID" = "None" ] || [ -z "$$HOSTED_ZONE_ID" ]; then \
		echo "❌ Hosted zone for $$BASE_DOMAIN not found"; \
		exit 1; \
	fi; \
	echo "🌐 Using hosted zone: $$HOSTED_ZONE_ID"; \
	echo "🔗 Creating A record: admin.$$BASE_DOMAIN → $$PUBLIC_IP"; \
	aws route53 change-resource-record-sets --hosted-zone-id $$HOSTED_ZONE_ID --change-batch '{ \
		"Changes": [{ \
			"Action": "UPSERT", \
			"ResourceRecordSet": { \
				"Name": "admin.'$$BASE_DOMAIN'", \
				"Type": "A", \
				"TTL": 60, \
				"ResourceRecords": [{"Value": "'$$PUBLIC_IP'"}] \
			} \
		}] \
	}' --region $(AWS_REGION); \
	echo "✅ Admin A record created!"; \
	echo "🎯 Admin endpoint: https://admin.$$BASE_DOMAIN"

###############################################
# DNS/Domain Setup targets

.PHONY: dns-info dns-setup dns-check dns-create-cname dns-test-domain dns-validate

dns-info: ## 📋 Show DNS setup information and current status
	@echo "🌐 DNS Configuration for MediaMTX"
	@echo "================================="
	@echo "🏷️  Domain Name: $(DOMAIN_NAME)"
	@echo "🔗 Target ALB DNS: "
	@ALB_DNS=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null); \
	if [ "$$ALB_DNS" = "None" ] || [ -z "$$ALB_DNS" ]; then \
		echo "   ❌ ALB not found - create it first with 'make alb-create'"; \
	else \
		echo "   ✅ $$ALB_DNS"; \
		echo ""; \
		echo "🔍 Current DNS Status:"; \
		echo "====================="; \
		echo -n "🌐 Domain Resolution: "; \
		DOMAIN_IP=$$(dig +short $(DOMAIN_NAME) 2>/dev/null | tail -n1); \
		if [ -n "$$DOMAIN_IP" ]; then \
			echo "$$DOMAIN_IP"; \
		else \
			echo "NOT_RESOLVED"; \
		fi; \
		echo -n "🔗 ALB IP Addresses: "; \
		ALB_IPS=$$(dig +short $$ALB_DNS 2>/dev/null | tr '\n' ', ' | sed 's/,$$//'); \
		if [ -n "$$ALB_IPS" ]; then \
			echo "$$ALB_IPS"; \
		else \
			echo "NOT_RESOLVED"; \
		fi; \
		echo ""; \
		echo "🔍 CNAME Check:"; \
		CNAME_TARGET=$$(dig +short CNAME $(DOMAIN_NAME) 2>/dev/null); \
		if [ -n "$$CNAME_TARGET" ]; then \
			echo "   ✅ CNAME exists: $(DOMAIN_NAME) → $$CNAME_TARGET"; \
			if [ "$$CNAME_TARGET" = "$$ALB_DNS." ] || [ "$$CNAME_TARGET" = "$$ALB_DNS" ]; then \
				echo "   ✅ CNAME correctly points to ALB"; \
			else \
				echo "   ⚠️  CNAME points to different target: $$CNAME_TARGET"; \
				echo "   💡 Expected: $$ALB_DNS"; \
			fi; \
		else \
			echo "   ❌ No CNAME record found"; \
			echo "   💡 Create CNAME: $(DOMAIN_NAME) → $$ALB_DNS"; \
		fi; \
	fi

dns-setup: ## 🔧 Show step-by-step DNS setup instructions
	@echo "🔧 DNS Setup Instructions for $(DOMAIN_NAME)"
	@echo "=============================================="
	@ALB_DNS=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null); \
	if [ "$$ALB_DNS" = "None" ] || [ -z "$$ALB_DNS" ]; then \
		echo "❌ ALB not found. Create it first:"; \
		echo "   make alb-create"; \
		exit 1; \
	else \
		echo "🎯 Target: $$ALB_DNS"; \
		echo ""; \
		echo "📋 Step-by-Step Instructions:"; \
		echo "============================="; \
		echo ""; \
		echo "1️⃣  Log into your DNS provider (GoDaddy, Namecheap, Cloudflare, etc.)"; \
		echo ""; \
		echo "2️⃣  Navigate to DNS Management for: $(DOMAIN_NAME)"; \
		echo ""; \
		echo "3️⃣  Create a new CNAME record:"; \
		echo "   📝 Record Type: CNAME"; \
		echo "   🏷️  Name/Host: @ (for root domain) or www"; \
		echo "   🎯 Target/Value: $$ALB_DNS"; \
		echo "   ⏱️  TTL: 300 (5 minutes) or Auto"; \
		echo ""; \
		echo "4️⃣  Save the DNS record"; \
		echo ""; \
		echo "5️⃣  Wait for DNS propagation (5-30 minutes)"; \
		echo ""; \
		echo "6️⃣  Test the setup:"; \
		echo "   make dns-check"; \
		echo ""; \
		echo "💡 Alternative: If you want a subdomain (e.g., stream.$(DOMAIN_NAME)):"; \
		echo "   🏷️  Name/Host: stream"; \
		echo "   🎯 Target: $$ALB_DNS"; \
		echo "   🔧 Then update DOMAIN_NAME in Makefile to: stream.$(DOMAIN_NAME)"; \
	fi

dns-create-cname: ## 🚀 Create CNAME record (Route53 only)
	@echo "🚀 Creating CNAME record in Route53..."
	@if ! command -v aws >/dev/null 2>&1; then \
		echo "❌ AWS CLI not found"; \
		exit 1; \
	fi
	@ALB_DNS=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null); \
	if [ -z "$$ALB_DNS" ] || [ "$$ALB_DNS" = "None" ]; then \
		echo "❌ ALB not found. Create it first: make alb-create"; \
		exit 1; \
	fi; \
	BASE_DOMAIN=$$(echo "$(DOMAIN_NAME)" | sed 's/^[^.]*\.//' | tr -d ' '); \
	echo "🔍 Looking for Route53 hosted zone for $$BASE_DOMAIN..."; \
	ZONE_ID=$$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$$BASE_DOMAIN.'].Id" --output text | sed 's|/hostedzone/||'); \
	if [ -z "$$ZONE_ID" ] || [ "$$ZONE_ID" = "None" ]; then \
		echo "❌ No Route53 hosted zone found for $$BASE_DOMAIN"; \
		echo "💡 Available zones:"; \
		aws route53 list-hosted-zones --query 'HostedZones[].{Name:Name,Id:Id}' --output table; \
		exit 1; \
	fi; \
	echo "✅ Found hosted zone: $$ZONE_ID"; \
	echo "🔧 Creating CNAME record: $(DOMAIN_NAME) → $$ALB_DNS"; \
	bash setup-dns-cname.sh "$(DOMAIN_NAME)" "$$ALB_DNS" "$$ZONE_ID"; \
	echo "✅ CNAME record created successfully!"

dns-check: ## 🧪 Test domain resolution and connectivity
	@echo "🧪 Testing Domain Resolution and Connectivity"
	@echo "=============================================="
	@echo "🔍 Testing: $(DOMAIN_NAME)"
	@echo ""
	@echo "1️⃣  DNS Resolution Test:"
	@echo "========================"
	@DOMAIN_IP=$$(dig +short $(DOMAIN_NAME) 2>/dev/null | tail -n1); \
	if [ -n "$$DOMAIN_IP" ]; then \
		echo "✅ Domain resolves to: $$DOMAIN_IP"; \
	else \
		echo "❌ Domain does not resolve"; \
		echo "💡 Check your DNS settings or wait for propagation"; \
		exit 1; \
	fi
	@echo ""
	@echo "2️⃣  CNAME Record Test:"
	@echo "======================"
	@CNAME_TARGET=$$(dig +short CNAME $(DOMAIN_NAME) 2>/dev/null); \
	if [ -n "$$CNAME_TARGET" ]; then \
		echo "✅ CNAME record found: $(DOMAIN_NAME) → $$CNAME_TARGET"; \
	else \
		echo "⚠️  No CNAME record found (might be using A records)"; \
	fi
	@echo ""
	@echo "3️⃣  HTTP Connectivity Test:"
	@echo "============================"
	@HTTP_STATUS=$$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 http://$(DOMAIN_NAME):8888/ 2>/dev/null || echo "000"); \
	if [ "$$HTTP_STATUS" = "404" ] || [ "$$HTTP_STATUS" = "200" ]; then \
		echo "✅ HTTP connection successful ($$HTTP_STATUS)"; \
		echo "🌐 Web UI: http://$(DOMAIN_NAME):8888/"; \
	elif [ "$$HTTP_STATUS" = "000" ]; then \
		echo "❌ HTTP connection failed"; \
		echo "💡 Check ALB status: make alb-info"; \
	else \
		echo "⚠️  HTTP returned: $$HTTP_STATUS"; \
	fi
	@echo ""
	@echo "4️⃣  RTSP Port Test:"
	@echo "=================="
	@if timeout 5 bash -c "</dev/tcp/$(DOMAIN_NAME)/8554" 2>/dev/null; then \
		echo "✅ RTSP port 8554 is reachable"; \
		echo "📡 RTSP URL: rtsp://$(DOMAIN_NAME):8554/"; \
	else \
		echo "❌ RTSP port 8554 not reachable"; \
		echo "💡 Check security group rules"; \
	fi
	@echo ""
	@echo "📋 Summary:"
	@echo "==========="
	@echo "🌐 Domain: $(DOMAIN_NAME)"
	@echo "📺 Web UI: http://$(DOMAIN_NAME):8888/"
	@echo "📡 RTSP: rtsp://$(DOMAIN_NAME):8554/"
	@echo "🎮 WebRTC: http://$(DOMAIN_NAME):8889/"
	@echo "📹 RTMP: rtmp://$(DOMAIN_NAME):1935/"

dns-test-domain: ## 🎯 Quick domain connectivity test
	@echo "🎯 Quick test: $(DOMAIN_NAME)"
	@if timeout 5 bash -c "</dev/tcp/$(DOMAIN_NAME)/8554" 2>/dev/null; then \
		echo "✅ $(DOMAIN_NAME):8554 is reachable"; \
	else \
		echo "❌ $(DOMAIN_NAME):8554 not reachable"; \
	fi

dns-validate: ## ✅ Comprehensive validation of DNS setup
	@echo "✅ Comprehensive DNS Validation"
	@echo "==============================="
	@echo ""
	@$(MAKE) dns-info
	@echo ""
	@$(MAKE) dns-check
	@echo ""
	@echo "🔧 Pi Configuration Test:"
	@echo "========================="
	@echo "Your Pi should use these settings:"
	@echo "  RTSP_SERVER=\"$(DOMAIN_NAME):8554\""
	@echo ""
	@echo "💡 To update your Pi:"
	@echo "   make pi-deploy    # Deploy with domain"
	@echo "   make pi-status    # Check Pi status"

dns-setup-subdomain: ## 🌐 Complete subdomain setup (Option 2)
	@echo "🌐 Setting up subdomain: $(DOMAIN_NAME)"
	@echo "========================================="
	@echo ""
	@echo "📋 This will:"
	@echo "   1. Create CNAME record in Route53"
	@echo "   2. Test DNS resolution"
	@echo "   3. Update Pi configuration"
	@echo "   4. Deploy to Pi"
	@echo ""
	@read -p "Proceed with subdomain setup? (y/N): " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "🚀 Starting subdomain setup..."; \
		echo ""; \
		echo "Step 1: Creating CNAME record..."; \
		$(MAKE) dns-create-cname || (echo "❌ CNAME creation failed. Try manual setup: make dns-setup"; exit 1); \
		echo ""; \
		echo "Step 2: Waiting for DNS propagation..."; \
		sleep 10; \
		echo ""; \
		echo "Step 3: Testing DNS resolution..."; \
		$(MAKE) dns-check || echo "⚠️  DNS may still be propagating"; \
		echo ""; \
		echo "Step 4: Deploying to Pi..."; \
		if [ -f "./copy-and-install.sh" ]; then \
			./copy-and-install.sh; \
		else \
			echo "💡 Copy and install script not found. Update Pi manually:"; \
			echo "   ssh dan7554@192.168.50.96"; \
			echo "   sed -i 's/RTSP_SERVER=\".*\"/RTSP_SERVER=\"$(DOMAIN_NAME):8554\"/' /home/dan7554/rpicam-stream.sh"; \
			echo "   sudo systemctl restart rpicam-stream.service"; \
		fi; \
		echo ""; \
		echo "✅ Subdomain setup complete!"; \
		echo "============================"; \
		echo "🌐 Your URLs:"; \
		echo "   📺 Web UI: http://$(DOMAIN_NAME):8888/"; \
		echo "   📡 RTSP: rtsp://$(DOMAIN_NAME):8554/"; \
		echo "   🎮 WebRTC: http://$(DOMAIN_NAME):8889/"; \
		echo "   📹 RTMP: rtmp://$(DOMAIN_NAME):1935/"; \
		echo ""; \
		echo "🧪 Test your stream:"; \
		echo "   make dns-test-domain"; \
		echo "   make pi-status"; \
	else \
		echo "Setup cancelled."; \
	fi

###############################################
# Full Deployment Pipeline

.PHONY: full-deploy quick-deploy deploy-and-monitor

full-deploy: ## 🚀 Complete deployment pipeline (build → ECR → ECS → DNS → Pi)
	@echo "🚀 Starting full deployment pipeline..."
	@echo "🏗️  Step 1: Building and pushing to ECR..."
	$(MAKE) ecr-deploy
	@echo "🏗️  Step 2: Setting up ECS infrastructure..."
	$(MAKE) ecs-setup
	@echo "🏗️  Step 3: Waiting for ECS tasks to start..."
	@for i in {1..30}; do \
		RUNNING=$$(aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].runningCount' --output text 2>/dev/null); \
		if [ "$$RUNNING" != "None" ] && [ "$$RUNNING" -gt 0 ]; then \
			echo "✅ ECS service has $$RUNNING running task(s)"; \
			break; \
		fi; \
		echo "⏳ Waiting for tasks to start... ($$i/30)"; \
		sleep 5; \
	done
	@echo "🌐 Step 4: Setting up DNS with ECS IP..."
	@$(MAKE) dns-create-rtsp-record || (echo "⚠️  DNS update may have had issues, but continuing..."; true)
	@sleep 15
	@echo "📱 Step 5: Deploying to Raspberry Pi..."
	@./copy-and-install.sh 2>/dev/null || true
	@echo "🔄 Restarting Pi streaming service..."
	@ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 dan7554@rpicam2.local "sudo systemctl restart rpicam-stream.service" 2>/dev/null || ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 dan7554@192.168.50.96 "sudo systemctl restart rpicam-stream.service" 2>/dev/null || true
	@echo ""
	@echo "✅ Full deployment complete!"
	@echo "🔍 Checking deployment status..."
	$(MAKE) ecs-status
	@echo ""
	@echo "🌐 Getting service URLs..."
	$(MAKE) ecs-get-url
	@echo ""
	@echo "💡 Next steps:"
	@echo "   make ecs-logs              # View live MediaMTX logs"
	@echo "   make ecs-status            # Check ECS status"
	@echo "   make quick-deploy          # Future updates"

quick-deploy: ## ⚡ Quick deployment (build → ECR → update ECS)
	@echo "⚡ Starting quick deployment..."
	@echo "=============================="
	@echo "🏗️  Building and pushing to ECR..."
	$(MAKE) ecr-push
	@echo ""
	@echo "🔄 Updating ECS service..."
	$(MAKE) ecs-update
	@echo ""
	@echo "⏳ Waiting up to 2 minutes for the new task to be in RUNNING state..."
	@for i in $$(seq 1 24); do \
		TASK_STATUS=$$(aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].deployments[0].runningCount' --output text 2>/dev/null); \
		if [ "$$TASK_STATUS" -ge "1" ]; then \
			echo "✅ New task is RUNNING."; \
			break; \
		fi; \
		echo "⏳ Waiting for task to start... (attempt $$i/24)"; \
		sleep 5; \
	done
	@echo "🎯 Updating RTSP DNS record to point to the new task's IP address..."
	@$(MAKE) dns-create-rtsp-record || (echo "⚠️  DNS update may have had issues, but continuing..."; true)
	@echo "⏳ Waiting for DNS to propagate (15 seconds)..."
	@sleep 15
	@echo ""
	@echo "✅ Quick deployment complete!"
	@echo "============================="
	@echo "🔍 Checking deployment status..."
	$(MAKE) ecs-status
	@echo ""
	@echo "🌐 Getting service URLs..."
	$(MAKE) ecs-get-url

deploy-and-monitor: full-deploy ## 🚀 Full deploy + live monitoring
	@echo ""
	@echo "📝 Starting live log monitoring..."
	@echo "Press Ctrl+C to stop monitoring"
	@echo "================================="
	$(MAKE) ecs-logs

###############################################
# AWS Resource Cleanup

aws-stop-services: ## 🛑 Stop ECS services to pause billing (keep infrastructure)
	@echo "🛑 Stopping ECS services to pause compute billing..."
	@echo "=================================================="
	@echo ""
	@ECS_RUNNING=$$(aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].runningCount' --output text 2>/dev/null); \
	if [ "$$ECS_RUNNING" != "None" ] && [ "$$ECS_RUNNING" -gt 0 ]; then \
		echo "🔄 Scaling ECS service to 0 tasks..."; \
		aws ecs update-service --cluster $(ECS_CLUSTER_NAME) --service $(ECS_SERVICE_NAME) --desired-count 0 --region $(AWS_REGION); \
		echo "✅ ECS service scaled down to 0 tasks"; \
		echo "💰 ECS Fargate compute charges: STOPPED"; \
		echo ""; \
		echo "ℹ️  Infrastructure remains available:"; \
		echo "   • ALB: Still running (~\$$27.76/month)"; \
		echo "   • ECR: Still storing images (~\$$0.10/month)"; \
		echo "   • DNS: Still resolving (~\$$0.90/month)"; \
		echo ""; \
		echo "🔄 To restart: make ecs-scale-up"; \
		echo "🗑️  To delete everything: make aws-cleanup"; \
	else \
		echo "ℹ️  ECS service is already stopped (0 tasks running)"; \
	fi

aws-start-services: ## ▶️  Start ECS services to resume streaming
	@echo "▶️  Starting ECS services to resume streaming..."
	@echo "==============================================="
	@echo ""
	@ECS_RUNNING=$$(aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].runningCount' --output text 2>/dev/null); \
	if [ "$$ECS_RUNNING" != "None" ] && [ "$$ECS_RUNNING" -eq 0 ]; then \
		echo "🔄 Scaling ECS service to 1 task..."; \
		aws ecs update-service --cluster $(ECS_CLUSTER_NAME) --service $(ECS_SERVICE_NAME) --desired-count 1 --region $(AWS_REGION); \
		echo "✅ ECS service scaled up to 1 task"; \
		echo "💰 ECS Fargate compute charges: RESUMED (~\$$9.01/month)"; \
		echo "🌐 Web interface will be available in ~2 minutes at:"; \
		echo "   http://stream.racetrackstreaming.com:8888/"; \
	else \
		echo "ℹ️  ECS service is already running ($$ECS_RUNNING tasks)"; \
	fi

ecs-scale-up: aws-start-services ## ▶️  Alias for aws-start-services

.PHONY: aws-cleanup aws-cleanup-all aws-cleanup-confirm aws-cost-estimate aws-list-resources aws-stop-services aws-start-services ecs-scale-up

aws-cleanup-confirm: ## ⚠️  Interactive confirmation for AWS resource cleanup
	@echo "🚨 AWS Resource Cleanup Warning"
	@echo "==============================="
	@echo "This will DELETE the following AWS resources:"
	@echo ""
	@echo "🔗 ALB Resources:"
	@echo "   • Load Balancer: $(ALB_NAME)"
	@echo "   • Target Group: $(TARGET_GROUP_NAME)"
	@echo "   • All listeners and rules (ports 80, 8554, 8888, 8889, 1935)"
	@echo ""
	@echo "☁️  ECS Resources:"
	@echo "   • Service: $(ECS_SERVICE_NAME)"
	@echo "   • Cluster: $(ECS_CLUSTER_NAME)"
	@echo "   • Task Definitions: $(ECS_TASK_FAMILY)"
	@echo "   • CloudWatch Logs: $(ECS_LOG_GROUP)"
	@echo ""
	@echo "🛡️  Security Groups:"
	@echo "   • mediamtx-security-group"
	@echo "   • mediamtx-alb-security-group"
	@echo ""
	@echo "📦 ECR Repository:"
	@echo "   • Repository: $(REPO_NAME)"
	@echo "   • All container images"
	@echo ""
	@echo "⚠️  IAM Role (optional):"
	@echo "   • ecsTaskExecutionRole (if not used elsewhere)"
	@echo ""
	@echo "🌐 DNS Records: PRESERVED"
	@echo "   ✅ CNAME: $(DOMAIN_NAME) (kept for redeployment)"
	@echo "   ✅ A Record: rtsp.racetrackstreaming.com (kept for redeployment)"
	@echo "   � DNS costs: ~\$$0.51/month (minimal ongoing cost)"
	@echo ""
	@echo "�💰 This will STOP MAJOR CHARGES for these resources:"
	@echo "   🔴 ECS Fargate compute costs (~\$$9/month)"
	@echo "   🔴 Application Load Balancer costs (~\$$28/month)"
	@echo "   🔴 ECR image storage costs"
	@echo "   🔴 CloudWatch log storage costs"
	@echo "   🔴 Route53 DNS query costs"
	@echo ""
	@echo "🔄 You can recreate everything with 'make full-deploy'"
	@echo ""
	@read -p "Are you sure you want to delete ALL AWS resources? (type 'DELETE' to confirm): " confirm; \
	if [ "$$confirm" = "DELETE" ]; then \
		echo "🗑️  Proceeding with cleanup..."; \
		$(MAKE) aws-cleanup-all; \
	else \
		echo "❌ Cleanup cancelled. No resources were deleted."; \
	fi

aws-cleanup: aws-cleanup-confirm ## 🧹 Clean up all AWS resources (with confirmation)

aws-cleanup-all: ## 🗑️  Force cleanup all AWS resources (no confirmation)
	@echo "🧹 Starting comprehensive AWS resource cleanup..."
	@echo "================================================="
	@echo ""
	@echo "🔗 Step 1: Cleaning up ALB resources..."
	@echo "======================================="
	-$(MAKE) alb-cleanup 2>/dev/null || echo "ALB cleanup completed (some resources may not exist)"
	@echo ""
	@echo "☁️  Step 2: Cleaning up ECS resources..."
	@echo "========================================"
	-$(MAKE) ecs-cleanup 2>/dev/null || echo "ECS cleanup completed (some resources may not exist)"
	@echo ""
	@echo "🛡️  Step 3: Cleaning up Security Groups..."
	@echo "==========================================="
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION) 2>/dev/null); \
	if [ "$$VPC_ID" != "None" ] && [ -n "$$VPC_ID" ]; then \
		echo "🔍 Cleaning up MediaMTX security groups..."; \
		for SG_NAME in "mediamtx-security-group" "mediamtx-alb-security-group"; do \
			SG_ID=$$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$$VPC_ID" "Name=group-name,Values=$$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION) 2>/dev/null); \
			if [ "$$SG_ID" != "None" ] && [ -n "$$SG_ID" ]; then \
				echo "🗑️  Deleting security group: $$SG_NAME ($$SG_ID)"; \
				aws ec2 delete-security-group --group-id $$SG_ID --region $(AWS_REGION) 2>/dev/null || echo "⚠️  Security group $$SG_NAME might be in use or already deleted"; \
			else \
				echo "ℹ️  Security group $$SG_NAME not found"; \
			fi; \
		done; \
	else \
		echo "ℹ️  VPC not found"; \
	fi
	@echo ""
	@echo "🌐 Step 4: DNS Records (PRESERVED)..."
	@echo "====================================="
	@echo "ℹ️  Skipping DNS record deletion to preserve domain configuration"
	@echo "💡 DNS records maintained for easy redeployment:"
	@echo "   • CNAME: $(DOMAIN_NAME)"
	@echo "   • A Record: rtsp.racetrackstreaming.com" 
	@echo "   • Ongoing cost: ~\$$0.51/month (minimal)"
	@echo ""
	@echo "📦 Step 5: Cleaning up ECR repository..."
	@echo "========================================"
	@echo "🗑️  Deleting all images in repository..."
	-aws ecr list-images --repository-name $(REPO_NAME) --region $(AWS_REGION) --query 'imageIds[]' --output json 2>/dev/null | \
		aws ecr batch-delete-image --repository-name $(REPO_NAME) --region $(AWS_REGION) --image-ids file:///dev/stdin 2>/dev/null || echo "No images to delete"
	@echo "🗑️  Deleting ECR repository..."
	-aws ecr delete-repository --repository-name $(REPO_NAME) --region $(AWS_REGION) --force 2>/dev/null || echo "Repository might not exist"
	@echo ""
	@echo "🔐 Step 6: Cleaning up IAM role (optional)..."
	@echo "============================================="
	@echo "⚠️  Checking if IAM role is used by other services..."
	@ROLE_USAGE=$$(aws iam list-entities-for-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy --region $(AWS_REGION) --query 'PolicyRoles[?RoleName==`ecsTaskExecutionRole`]' --output text 2>/dev/null); \
	if [ -n "$$ROLE_USAGE" ]; then \
		echo "ℹ️  IAM role 'ecsTaskExecutionRole' exists but might be used by other services."; \
		echo "🔍 To manually delete it later, run:"; \
		echo "   aws iam detach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"; \
		echo "   aws iam delete-role --role-name ecsTaskExecutionRole"; \
	else \
		echo "ℹ️  IAM role not found or already cleaned up"; \
	fi
	@echo ""
	@echo "✅ AWS Resource Cleanup Complete!"
	@echo "================================="
	@echo "💰 All billable AWS resources have been removed"
	@echo "🔄 To redeploy everything, run: make full-deploy"
	@echo ""
	@echo "📋 Summary of cleaned resources:"
	@echo "   • ALB: $(ALB_NAME) + all listeners"
	@echo "   • Target Group: $(TARGET_GROUP_NAME)"
	@echo "   • ECS Service: $(ECS_SERVICE_NAME)"
	@echo "   • ECS Cluster: $(ECS_CLUSTER_NAME)"
	@echo "   • CloudWatch Logs: $(ECS_LOG_GROUP)"
	@echo "   • ECR Repository: $(REPO_NAME) + all images"
	@echo "   • Security Groups: mediamtx-security-group, mediamtx-alb-security-group"
	@echo ""
	@echo "🌐 DNS Records PRESERVED:"
	@echo "   ✅ CNAME: $(DOMAIN_NAME) (ready for redeployment)"
	@echo "   ✅ A Record: rtsp.racetrackstreaming.com (ready for redeployment)"
	@echo ""
	@echo "💡 Cost Impact:"
	@echo "   ✅ ECS Fargate tasks: STOPPED (no compute charges)"
	@echo "   ✅ ALB: DELETED (no load balancer charges)"
	@echo "   ✅ ECR storage: DELETED (no image storage charges)"
	@echo "   ✅ CloudWatch logs: DELETED (no log storage charges)"
	@echo "   🟡 Route53 DNS: PRESERVED (~\$$0.51/month ongoing)"
	@echo ""
	@echo "🎯 Benefits of preserving DNS:"
	@echo "   • Instant domain access after redeployment"
	@echo "   • No need to reconfigure Pi or update DNS"
	@echo "   • Minimal ongoing cost (~\$$0.51/month)"
	@echo ""
	@echo "🎯 Your local Docker images and code are unchanged"

aws-cost-estimate: ## 💰 Show estimated monthly costs for current AWS resources
	@echo "💰 MediaMTX AWS Cost Estimation"
	@echo "==============================="
	@echo ""
	@echo "📊 Current Resource Costs (estimated monthly):"
	@echo ""
	@ALB_EXISTS=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null); \
	if [ "$$ALB_EXISTS" = "active" ]; then \
		echo "🔗 Application Load Balancer:"; \
		echo "   Base cost: ~\$$22.00/month"; \
		echo "   + \$$0.008 per LCU hour (~\$$5.76/month for light usage)"; \
		echo "   Estimated total: ~\$$27.76/month"; \
	else \
		echo "🔗 Application Load Balancer: NOT DEPLOYED (\$$0)"; \
	fi; \
	echo ""; \
	ECS_RUNNING=$$(aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].runningCount' --output text 2>/dev/null); \
	if [ "$$ECS_RUNNING" != "None" ] && [ "$$ECS_RUNNING" -gt 0 ]; then \
		echo "☁️  ECS Fargate (1 task, 0.25 vCPU, 0.5 GB):"; \
		echo "   vCPU: \$$0.04048 × 0.25 × 730 hours = ~\$$7.39/month"; \
		echo "   Memory: \$$0.004445 × 0.5 × 730 hours = ~\$$1.62/month"; \
		echo "   Estimated total: ~\$$9.01/month"; \
	else \
		echo "☁️  ECS Fargate: NOT RUNNING (\$$0)"; \
	fi; \
	echo ""; \
	ECR_EXISTS=$$(aws ecr describe-repositories --repository-names $(REPO_NAME) --region $(AWS_REGION) --query 'repositories[0].repositoryName' --output text 2>/dev/null); \
	if [ "$$ECR_EXISTS" = "$(REPO_NAME)" ]; then \
		echo "📦 ECR Repository Storage:"; \
		echo "   Estimated: ~\$$0.10/month (for ~1GB of images)"; \
	else \
		echo "📦 ECR Repository: NOT DEPLOYED (\$$0)"; \
	fi; \
	echo ""; \
	echo "🔍 CloudWatch Logs:"; \
	echo "   Estimated: ~\$$0.50-2.00/month (depends on log volume)"; \
	echo ""; \
	echo "🌐 Route53 DNS:"; \
	echo "   Hosted zone: \$$0.50/month"; \
	echo "   DNS queries: ~\$$0.40/month (1M queries)"; \
	echo "   Estimated total: ~\$$0.90/month"; \
	echo ""; \
	echo "💡 TOTAL ESTIMATED MONTHLY COST: ~\$$38-42/month"; \
	echo ""; \
	echo "🛑 To STOP all charges, run: make aws-cleanup"; \
	echo "🔄 To restart later, run: make full-deploy"

aws-list-resources: ## 📋 List all AWS resources created by this project
	@echo "📋 AWS Resources Created by MediaMTX Project"
	@echo "============================================="
	@echo ""
	@echo "🔗 ALB Resources:"
	@echo "=================="
	@echo -n "   Load Balancer: "
	@aws elbv2 describe-load-balancers --names $(ALB_NAME) --region $(AWS_REGION) --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "NOT_FOUND"
	@echo -n "   Target Group: "
	@aws elbv2 describe-target-groups --names $(TARGET_GROUP_NAME) --region $(AWS_REGION) --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | sed 's/.*/FOUND/' || echo "NOT_FOUND"
	@echo ""
	@echo "☁️  ECS Resources:"
	@echo "=================="
	@echo -n "   Cluster: "
	@aws ecs describe-clusters --cluster $(ECS_CLUSTER_NAME) --region $(AWS_REGION) --query 'clusters[0].status' --output text 2>/dev/null || echo "NOT_FOUND"
	@echo -n "   Service: "
	@aws ecs describe-services --cluster $(ECS_CLUSTER_NAME) --services $(ECS_SERVICE_NAME) --region $(AWS_REGION) --query 'services[0].status' --output text 2>/dev/null || echo "NOT_FOUND"
	@echo -n "   Log Group: "
	@aws logs describe-log-groups --log-group-name-prefix $(ECS_LOG_GROUP) --region $(AWS_REGION) --query 'logGroups[0].logGroupName' --output text 2>/dev/null || echo "NOT_FOUND"
	@echo ""
	@echo "📦 ECR Resources:"
	@echo "=================="
	@echo -n "   Repository: "
	@aws ecr describe-repositories --repository-names $(REPO_NAME) --region $(AWS_REGION) --query 'repositories[0].repositoryName' --output text 2>/dev/null || echo "NOT_FOUND"
	@echo -n "   Image Count: "
	@aws ecr list-images --repository-name $(REPO_NAME) --region $(AWS_REGION) --query 'length(imageIds)' --output text 2>/dev/null || echo "0"
	@echo ""
	@echo "🛡️  Security Group:"
	@echo "==================="
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION) 2>/dev/null); \
	if [ "$$VPC_ID" != "None" ] && [ -n "$$VPC_ID" ]; then \
		echo -n "   mediamtx-security-group: "; \
		aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$$VPC_ID" "Name=group-name,Values=mediamtx-security-group" --query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION) 2>/dev/null | sed 's/.*/FOUND/' || echo "NOT_FOUND"; \
	else \
		echo "   VPC: NOT_FOUND"; \
	fi
	@echo ""
	@echo "🔐 IAM Role:"
	@echo "============"
	@echo -n "   ecsTaskExecutionRole: "
	@aws iam get-role --role-name ecsTaskExecutionRole --region $(AWS_REGION) --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND"

###############################################
# Recording and Playback targets

.PHONY: recording-setup recording-enable recording-disable recording-status recording-clean recording-test recording-web-player

recording-setup: ## 📹 Set up MediaMTX recording capabilities with HLS
	@echo "📹 Setting up MediaMTX Recording with HLS for Browser Scrubbing"
	@echo "=============================================================="
	@echo ""
	@echo "🎯 This will configure MediaMTX to:"
	@echo "   • Record live streams to HLS segments"
	@echo "   • Enable browser-based scrubbing/seeking"
	@echo "   • Store recordings in container storage"
	@echo "   • Provide HTTP access to recorded content"
	@echo ""
	@echo "🔧 Creating recording-enabled configuration..."
	@echo "# MediaMTX Configuration with Recording Support" > recording-config.yml
	@echo "logLevel: info" >> recording-config.yml
	@echo "logDestinations: [stdout]" >> recording-config.yml
	@echo "logFile: \"\"" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# Enable API for recording control" >> recording-config.yml
	@echo "api: yes" >> recording-config.yml
	@echo "apiAddress: 0.0.0.0:9997" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# Enable metrics" >> recording-config.yml
	@echo "metrics: yes" >> recording-config.yml
	@echo "metricsAddress: 0.0.0.0:9998" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# Enable PPROF for debugging" >> recording-config.yml
	@echo "pprof: yes" >> recording-config.yml
	@echo "pprofAddress: 0.0.0.0:9999" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# Enable recording for all paths" >> recording-config.yml
	@echo "recordPath: /recordings/%path/%Y-%m-%d_%H-%M-%S" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# HLS Configuration for browser playback" >> recording-config.yml
	@echo "hls: yes" >> recording-config.yml
	@echo "hlsAddress: 0.0.0.0:8888" >> recording-config.yml
	@echo "hlsEncryption: no" >> recording-config.yml
	@echo "hlsAllowOrigin: \"*\"" >> recording-config.yml
	@echo "hlsSegmentCount: 10" >> recording-config.yml
	@echo "hlsSegmentDuration: 2s" >> recording-config.yml
	@echo "hlsPartDuration: 200ms" >> recording-config.yml
	@echo "hlsSegmentMaxSize: 50M" >> recording-config.yml
	@echo "hlsMuxerCloseAfter: 60s" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# WebRTC Configuration" >> recording-config.yml
	@echo "webrtc: yes" >> recording-config.yml
	@echo "webrtcAddress: 0.0.0.0:8889" >> recording-config.yml
	@echo "webrtcAllowOrigin: \"*\"" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# RTSP Configuration" >> recording-config.yml
	@echo "rtsp: yes" >> recording-config.yml
	@echo "rtspAddress: 0.0.0.0:8554" >> recording-config.yml
	@echo "rtspTransports: [tcp, udp]" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# RTMP Configuration" >> recording-config.yml
	@echo "rtmp: yes" >> recording-config.yml
	@echo "rtmpAddress: 0.0.0.0:1935" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# SRT Configuration" >> recording-config.yml
	@echo "srt: yes" >> recording-config.yml
	@echo "srtAddress: 0.0.0.0:9996" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "# Path configurations with recording" >> recording-config.yml
	@echo "paths:" >> recording-config.yml
	@echo "  rpicam:" >> recording-config.yml
	@echo "    # Enable recording for the Pi camera stream" >> recording-config.yml
	@echo "    record: yes" >> recording-config.yml
	@echo "    recordPath: /recordings/rpicam/%Y-%m-%d_%H-%M-%S" >> recording-config.yml
	@echo "    recordFormat: fmp4" >> recording-config.yml
	@echo "    recordPartDuration: 1s" >> recording-config.yml
	@echo "    recordSegmentDuration: 1h" >> recording-config.yml
	@echo "    recordDeleteAfter: 24h" >> recording-config.yml
	@echo "    publishUser: \"\"" >> recording-config.yml
	@echo "    publishPass: \"\"" >> recording-config.yml
	@echo "    publishIPs: []" >> recording-config.yml
	@echo "    readUser: \"\"" >> recording-config.yml
	@echo "    readPass: \"\"" >> recording-config.yml
	@echo "    readIPs: []" >> recording-config.yml
	@echo "" >> recording-config.yml
	@echo "  # Default path for other streams" >> recording-config.yml
	@echo "  \"~^.*\": # Regex pattern for all paths" >> recording-config.yml
	@echo "    record: yes" >> recording-config.yml
	@echo "    recordPath: /recordings/%path/%Y-%m-%d_%H-%M-%S" >> recording-config.yml
	@echo "    recordFormat: fmp4" >> recording-config.yml
	@echo "    recordPartDuration: 1s" >> recording-config.yml
	@echo "    recordSegmentDuration: 1h" >> recording-config.yml
	@echo "    recordDeleteAfter: 24h" >> recording-config.yml
	@echo "✅ Recording configuration created: recording-config.yml"
	@echo ""
	@echo "📦 Building Docker image with recording support..."
	@echo "FROM bluenviron/mediamtx:1.15.3-ffmpeg" > Dockerfile.recording
	@echo "COPY recording-config.yml /mediamtx.yml" >> Dockerfile.recording
	@echo "RUN mkdir -p /recordings" >> Dockerfile.recording
	@echo "EXPOSE 8554 8888 8889 1935 9996 9997 9998 9999" >> Dockerfile.recording
	@echo "CMD [\"/mediamtx\"]" >> Dockerfile.recording
	@docker build -f Dockerfile.recording -t $(IMAGE_NAME):recording .
	@rm -f Dockerfile.recording
	@echo ""
	@echo "🚀 Next steps:"
	@echo "   make recording-enable     # Enable recording in production"
	@echo "   make recording-test       # Test recording locally"

recording-test: ## 🧪 Test recording locally
	@echo "🧪 Testing Recording Locally"
	@echo "============================"
	@echo "🐳 Starting MediaMTX with recording..."
	@docker run --rm -d \
		--name $(CONTAINER_NAME)-recording-test \
		-p 8554:8554 \
		-p 8888:8888 \
		-p 8889:8889 \
		-p 9997:9997 \
		-v $$(pwd)/recordings:/recordings \
		$(IMAGE_NAME):recording
	@echo "⏳ Waiting for service to start..."
	@sleep 10
	@echo ""
	@echo "🧪 Testing endpoints..."
	@echo "RTSP: rtsp://localhost:8554"
	@echo "Web UI: http://localhost:8888"
	@echo "API: http://localhost:9997/v3/paths/list"
	@echo ""
	@echo "🛑 To stop test: docker stop $(CONTAINER_NAME)-recording-test"

recording-web-player: ## 🎮 Create HTML5 video player for recorded streams
	@echo "🎮 Creating HTML5 Player for Stream Scrubbing"
	@echo "=============================================="
	@echo "Creating stream player HTML file..."
	@echo '<!DOCTYPE html>' > stream-player.html
	@echo '<html lang="en">' >> stream-player.html
	@echo '<head>' >> stream-player.html
	@echo '    <meta charset="UTF-8">' >> stream-player.html
	@echo '    <meta name="viewport" content="width=device-width, initial-scale=1.0">' >> stream-player.html
	@echo '    <title>MediaMTX Stream Player with Scrubbing</title>' >> stream-player.html
	@echo '    <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>' >> stream-player.html
	@echo '    <style>' >> stream-player.html
	@echo '        body { font-family: Arial, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #1a1a1a; color: white; }' >> stream-player.html
	@echo '        .player-container { background: #2a2a2a; border-radius: 10px; padding: 20px; margin-bottom: 20px; }' >> stream-player.html
	@echo '        video { width: 100%; max-width: 800px; border-radius: 5px; }' >> stream-player.html
	@echo '        .controls { margin-top: 15px; }' >> stream-player.html
	@echo '        .url-input { width: 100%; max-width: 600px; padding: 10px; margin: 10px 0; border: 1px solid #555; border-radius: 5px; background: #333; color: white; }' >> stream-player.html
	@echo '        button { background: #007bff; color: white; border: none; padding: 10px 20px; margin: 5px; border-radius: 5px; cursor: pointer; }' >> stream-player.html
	@echo '        button:hover { background: #0056b3; }' >> stream-player.html
	@echo '        .info { background: #333; padding: 15px; border-radius: 5px; margin-top: 20px; }' >> stream-player.html
	@echo '        .status { margin-top: 10px; padding: 10px; border-radius: 5px; }' >> stream-player.html
	@echo '        .status.success { background: #d4edda; color: #155724; }' >> stream-player.html
	@echo '        .status.error { background: #f8d7da; color: #721c24; }' >> stream-player.html
	@echo '    </style>' >> stream-player.html
	@echo '</head>' >> stream-player.html
	@echo '<body>' >> stream-player.html
	@echo '    <h1>🎬 MediaMTX Stream Player</h1>' >> stream-player.html
	@echo '    <div class="player-container">' >> stream-player.html
	@echo '        <h2>Live Stream with Scrubbing</h2>' >> stream-player.html
	@echo '        <video id="video" controls>' >> stream-player.html
	@echo '            Your browser does not support the video tag.' >> stream-player.html
	@echo '        </video>' >> stream-player.html
	@echo '        <div class="controls">' >> stream-player.html
	@echo '            <input type="text" id="streamUrl" class="url-input" ' >> stream-player.html
	@echo '                   placeholder="Enter HLS stream URL" ' >> stream-player.html
	@echo '                   value="http://stream.racetrackstreaming.com:8888/rpicam/index.m3u8">' >> stream-player.html
	@echo '            <br>' >> stream-player.html
	@echo '            <button onclick="loadStream()">Load Stream</button>' >> stream-player.html
	@echo '            <button onclick="togglePlayPause()">Play/Pause</button>' >> stream-player.html
	@echo '            <button onclick="seekBackward()">⏪ -10s</button>' >> stream-player.html
	@echo '            <button onclick="seekForward()">⏩ +10s</button>' >> stream-player.html
	@echo '            <button onclick="toggleMute()">🔊 Mute</button>' >> stream-player.html
	@echo '        </div>' >> stream-player.html
	@echo '        <div id="status" class="status" style="display: none;"></div>' >> stream-player.html
	@echo '    </div>' >> stream-player.html
	@echo '    <script>' >> stream-player.html
	@echo '        const video = document.getElementById("video");' >> stream-player.html
	@echo '        const streamUrlInput = document.getElementById("streamUrl");' >> stream-player.html
	@echo '        const statusDiv = document.getElementById("status");' >> stream-player.html
	@echo '        let hls = null;' >> stream-player.html
	@echo '        function loadStream() {' >> stream-player.html
	@echo '            const url = streamUrlInput.value.trim();' >> stream-player.html
	@echo '            if (!url) return;' >> stream-player.html
	@echo '            if (hls) hls.destroy();' >> stream-player.html
	@echo '            if (Hls.isSupported()) {' >> stream-player.html
	@echo '                hls = new Hls();' >> stream-player.html
	@echo '                hls.loadSource(url);' >> stream-player.html
	@echo '                hls.attachMedia(video);' >> stream-player.html
	@echo '            } else if (video.canPlayType("application/vnd.apple.mpegurl")) {' >> stream-player.html
	@echo '                video.src = url;' >> stream-player.html
	@echo '            }' >> stream-player.html
	@echo '        }' >> stream-player.html
	@echo '        function togglePlayPause() { video.paused ? video.play() : video.pause(); }' >> stream-player.html
	@echo '        function seekBackward() { video.currentTime = Math.max(0, video.currentTime - 10); }' >> stream-player.html
	@echo '        function seekForward() { video.currentTime = Math.min(video.duration, video.currentTime + 10); }' >> stream-player.html
	@echo '        function toggleMute() { video.muted = !video.muted; }' >> stream-player.html
	@echo '        window.addEventListener("load", function() { if (streamUrlInput.value) setTimeout(loadStream, 1000); });' >> stream-player.html
	@echo '    </script>' >> stream-player.html
	@echo '</body>' >> stream-player.html
	@echo '</html>' >> stream-player.html
	@echo "✅ HTML5 player created: stream-player.html"
	@echo ""
	@echo "🌐 Open in browser: file://$$(pwd)/stream-player.html"
	@echo ""
	@echo "🎯 Features:"
	@echo "   • Full timeline scrubbing/seeking"
	@echo "   • Keyboard controls (Space, arrows)"
	@echo "   • Live stream with ~10 second history"
	@echo "   • Works with any HLS-compatible browser"

recording-clean: ## 🧹 Clean up recording files and test containers
	@echo "🧹 Cleaning up recording files..."
	@rm -rf recordings/
	@rm -f recording-config.yml
	@echo "🐳 Stopping test containers..."
	@-docker stop $(CONTAINER_NAME)-recording-test 2>/dev/null || true
	@-docker rm $(CONTAINER_NAME)-recording-test 2>/dev/null || true
	@echo "✅ Recording cleanup complete"

###############################################
# Broadcast System Containerization
###############################################

broadcast-build: ## Build broadcast system Docker image
	@echo "🏗️  Building broadcast system Docker image..."
	docker build -f broadcast-system/Dockerfile -t broadcast-system:latest .
	@echo "✅ Broadcast system build complete!"

broadcast-build-nc: ## Build broadcast system Docker image (no cache)
	@echo "🏗️  Building broadcast system Docker image (no cache)..."
	docker build --no-cache -f broadcast-system/Dockerfile -t broadcast-system:latest .
	@echo "✅ Broadcast system build complete!"

broadcast-run: broadcast-build ## Build and run broadcast system container
	@echo "🚀 Starting broadcast system container..."
	docker run -d \
		--name broadcast-system \
		--restart unless-stopped \
		-p 80:80 \
		-p 443:443 \
		-v $(PWD)/broadcast-system/certs:/etc/nginx/certs \
		broadcast-system:latest
	@echo "✅ Broadcast system started!"
	@echo ""
	@echo "🌐 Access points:"
	@echo "   • Web UI:  https://localhost"
	@echo "   • API:     https://localhost/api"
	@echo "   • Health:  http://localhost/health"

broadcast-stop: ## Stop broadcast system container
	@echo "🛑 Stopping broadcast system container..."
	@-docker stop broadcast-system 2>/dev/null || true
	@-docker rm broadcast-system 2>/dev/null || true
	@echo "✅ Broadcast system stopped!"

broadcast-logs: ## View broadcast system logs
	@docker logs -f broadcast-system

broadcast-shell: ## Open shell in broadcast system container
	@docker exec -it broadcast-system sh

broadcast-health: ## Check broadcast system health
	@echo "🏥 Checking broadcast system health..."
	@curl -f http://localhost/health && echo "" && echo "✅ Broadcast system is healthy!" || echo "❌ Broadcast system is not responding"

broadcast-compose-up: ## Start broadcast system and MediaMTX with docker compose
	@echo "🚀 Starting broadcast system and MediaMTX with docker compose..."
	docker compose up -d broadcast-system mediamtx
	@echo "✅ Services started!"
	@docker compose ps
	@echo ""
	@echo "🌐 Access points:"
	@echo "   • Web UI:  https://localhost"
	@echo "   • API:     https://localhost/api"
	@echo "   • RTSP:    rtsp://localhost:8554/rpicam2"
	@echo "   • HLS:     http://localhost:8888/rpicam2/index.m3u8"

broadcast-compose-down: ## Stop broadcast system and MediaMTX services
	@echo "🛑 Stopping docker compose services..."
	docker compose down
	@echo "✅ Services stopped!"

broadcast-compose-build: ## Build broadcast system and MediaMTX with docker compose
	@echo "🏗️  Building services with docker compose..."
	docker compose build broadcast-system mediamtx
	@echo "✅ Build complete!"

broadcast-compose-logs: ## View docker compose logs
	@docker compose logs -f

broadcast-compose-logs-broadcast: ## View broadcast system logs only
	@docker compose logs -f broadcast-system

broadcast-compose-logs-mediamtx: ## View MediaMTX logs only
	@docker compose logs -f mediamtx

broadcast-compose-rebuild: ## Rebuild and restart broadcast system and MediaMTX
	@echo "🔄 Rebuilding and restarting services..."
	docker compose up --build -d broadcast-system mediamtx
	@echo "✅ Services rebuilt and restarted!"
	@docker compose ps

broadcast-test: ## Test broadcast system connectivity
	@echo "🧪 Testing broadcast system..."
	@echo "  1. Testing health endpoint..."
	@curl -s http://localhost/health && echo "   ✅ Health check passed" || echo "   ❌ Health check failed"
	@echo ""
	@echo "  2. Testing API endpoint..."
	@curl -s -k https://localhost/api/cameras | head -20 && echo "   ✅ API check passed" || echo "   ❌ API check failed"
	@echo ""
	@echo "  3. Checking services..."
	@docker compose ps | grep -E "broadcast-system|mediamtx"

broadcast-dev: ## Run broadcast system in development mode (interactive)
	@echo "🔧 Running broadcast system in development mode..."
	docker run -it \
		--name broadcast-system-dev \
		--rm \
		-p 80:80 \
		-p 443:443 \
		-v $(PWD)/broadcast-system/server:/app/server \
		-v $(PWD)/broadcast-system/client/src:/app/client/src \
		-e NODE_ENV=development \
		broadcast-system:latest

broadcast-certs-generate: ## Generate self-signed SSL certificates for local.broadcast.com
	@echo "🔐 Generating self-signed SSL certificates for local.broadcast.com..."
	@mkdir -p broadcast-system/certs
	@openssl req -x509 -newkey rsa:4096 \
		-keyout broadcast-system/certs/server.key \
		-out broadcast-system/certs/server.crt \
		-days 365 -nodes \
		-subj "/C=US/ST=State/L=City/O=Organization/CN=local.broadcast.com"
	@chmod 600 broadcast-system/certs/server.key
	@chmod 644 broadcast-system/certs/server.crt
	@echo "✅ SSL certificates generated!"
	@echo "   • Certificate: broadcast-system/certs/server.crt"
	@echo "   • Private Key: broadcast-system/certs/server.key"
	@echo "   • Valid for: 365 days"

broadcast-full-deploy: broadcast-build broadcast-compose-up ## Build and deploy full broadcast system stack
	@echo ""
	@echo "✨ Broadcast system deployment complete!"
	@echo ""
	@echo "📊 Service Status:"
	@docker compose ps
	@echo ""
	@echo "🌐 Access Points:"
	@echo "   • Web UI:  https://localhost"
	@echo "   • API:     https://localhost/api"
	@echo "   • RTSP:    rtsp://localhost:8554"
	@echo "   • HLS:     http://localhost:8888"
	@echo ""
	@echo "📖 Documentation:"
	@echo "   • Quick Start:  broadcast-system/QUICKSTART.md"
	@echo "   • Full Guide:   broadcast-system/CONTAINERIZATION.md"

broadcast-push-registry: ## Push broadcast system image to Docker registry
	@echo "📤 Pushing broadcast system image to registry..."
	@echo "Set DOCKER_REGISTRY in Makefile to enable this"
	@if [ -z "$(DOCKER_REGISTRY)" ]; then \
		echo "❌ DOCKER_REGISTRY not configured"; \
		exit 1; \
	fi
	docker tag broadcast-system:latest $(DOCKER_REGISTRY)/broadcast-system:latest
	docker push $(DOCKER_REGISTRY)/broadcast-system:latest
	@echo "✅ Image pushed to $(DOCKER_REGISTRY)/broadcast-system:latest"

###############################################
# Broadcast System AWS ECS Deployment

.PHONY: broadcast-aws-login broadcast-aws-build broadcast-aws-push broadcast-aws-create-task broadcast-aws-create-service broadcast-aws-update broadcast-aws-deploy broadcast-aws-quick-deploy broadcast-aws-logs broadcast-aws-status broadcast-aws-cleanup

# Configuration for Broadcast System
BROADCAST_REPO_NAME ?= broadcast-system
BROADCAST_ECR_URI := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(BROADCAST_REPO_NAME)
BROADCAST_ECS_CLUSTER := broadcast-cluster
BROADCAST_ECS_SERVICE := broadcast-service
BROADCAST_ECS_TASK_FAMILY := broadcast-task
BROADCAST_LOG_GROUP := /ecs/broadcast
BROADCAST_DOMAIN := admin.racetrackstreaming.com
BROADCAST_PORT := 443

broadcast-aws-login: ## 🔐 Login to AWS ECR for broadcast system
	@echo "🔐 Logging into AWS ECR..."
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(BROADCAST_ECR_URI)
	@echo "✅ ECR login successful!"

broadcast-aws-build: ## 🏗️ Build broadcast system for AWS (AMD64)
	@echo "🏗️ Building broadcast system Docker image for AWS..."
	docker build --platform linux/amd64 -f broadcast-system/Dockerfile -t $(BROADCAST_REPO_NAME):latest .
	@echo "✅ Build complete!"

broadcast-aws-push: broadcast-aws-login broadcast-aws-build ## 📤 Build and push broadcast system to ECR
	@echo "📤 Pushing broadcast system image to ECR..."
	@TIMESTAMP=$$(date +%Y%m%d-%H%M%S); \
	docker tag $(BROADCAST_REPO_NAME):latest $(BROADCAST_ECR_URI):latest; \
	docker tag $(BROADCAST_REPO_NAME):latest $(BROADCAST_ECR_URI):$$TIMESTAMP; \
	docker push $(BROADCAST_ECR_URI):latest; \
	docker push $(BROADCAST_ECR_URI):$$TIMESTAMP; \
	echo "✅ Pushed: $(BROADCAST_ECR_URI):latest"; \
	echo "✅ Pushed: $(BROADCAST_ECR_URI):$$TIMESTAMP"

broadcast-aws-create-task: ## 📋 Create broadcast ECS task definition
	@echo "📋 Creating broadcast ECS task definition..."
	@aws ecs register-task-definition \
		--family $(BROADCAST_ECS_TASK_FAMILY) \
		--network-mode awsvpc \
		--requires-compatibilities FARGATE \
		--cpu 512 \
		--memory 1024 \
		--container-definitions '[ \
			{ \
				"name": "broadcast-system", \
				"image": "$(BROADCAST_ECR_URI):latest", \
				"portMappings": [ \
					{"containerPort": 80, "hostPort": 80, "protocol": "tcp"}, \
					{"containerPort": 443, "hostPort": 443, "protocol": "tcp"} \
				], \
				"environment": [ \
					{"name": "NODE_ENV", "value": "production"}, \
					{"name": "PORT", "value": "3001"}, \
					{"name": "MEDIAMTX_URL", "value": "https://rtsp.racetrackstreaming.com:8889"}, \
					{"name": "BROADCAST_HOSTNAME", "value": "$(BROADCAST_DOMAIN)"}, \
					{"name": "BROADCAST_PORT", "value": "$(BROADCAST_PORT)"} \
				], \
				"logConfiguration": { \
					"logDriver": "awslogs", \
					"options": { \
						"awslogs-group": "$(BROADCAST_LOG_GROUP)", \
						"awslogs-region": "$(AWS_REGION)", \
						"awslogs-stream-prefix": "broadcast" \
					} \
				}, \
				"healthCheck": { \
					"command": ["CMD-SHELL", "curl -f http://localhost:3001/health || exit 1"], \
					"interval": 30, \
					"timeout": 5, \
					"retries": 2, \
					"startPeriod": 60 \
				} \
			} \
		]' \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null
	@echo "✅ Task definition created!"

broadcast-aws-create-cluster: ## 🏢 Create broadcast ECS cluster
	@echo "🏢 Creating broadcast ECS cluster..."
	@aws ecs create-cluster \
		--cluster-name $(BROADCAST_ECS_CLUSTER) \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null 2>&1 || echo "ℹ️  Cluster already exists"
	@echo "✅ Cluster ready!"

broadcast-aws-create-logs: ## 📝 Create CloudWatch log group
	@echo "📝 Creating CloudWatch log group..."
	@aws logs create-log-group \
		--log-group-name $(BROADCAST_LOG_GROUP) \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null 2>&1 || echo "ℹ️  Log group already exists"
	@echo "✅ Log group ready!"

broadcast-aws-create-service: ## 🚀 Create broadcast ECS service
	@echo "🚀 Creating broadcast ECS service..."
	@VPC_ID=$$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION)); \
	SUBNET_IDS=$$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$$VPC_ID" --query 'Subnets[0:2].SubnetId' --output text --region $(AWS_REGION) | tr '\t' ','); \
	SG_ID=$$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$$VPC_ID" "Name=group-name,Values=default" --query 'SecurityGroups[0].GroupId' --output text --region $(AWS_REGION)); \
	aws ecs create-service \
		--cluster $(BROADCAST_ECS_CLUSTER) \
		--service-name $(BROADCAST_ECS_SERVICE) \
		--task-definition $(BROADCAST_ECS_TASK_FAMILY) \
		--desired-count 1 \
		--launch-type FARGATE \
		--network-configuration "awsvpcConfiguration={subnets=[$$SUBNET_IDS],securityGroups=[$$SG_ID],assignPublicIp=ENABLED}" \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null
	@echo "✅ Service created!"

broadcast-aws-update: ## 🔄 Update broadcast ECS service with latest image
	@echo "🔄 Updating broadcast ECS service..."
	aws ecs update-service \
		--cluster $(BROADCAST_ECS_CLUSTER) \
		--service $(BROADCAST_ECS_SERVICE) \
		--force-new-deployment \
		--region $(AWS_REGION) \
		--no-cli-pager > /dev/null
	@echo "✅ Service updated!"

broadcast-aws-deploy: broadcast-aws-create-cluster broadcast-aws-create-logs broadcast-aws-create-task broadcast-aws-create-service broadcast-aws-push broadcast-aws-update dns-create-admin-record ## 🚀 Full broadcast system deployment to AWS
	@echo ""
	@echo "✨ Broadcast system deployment complete!"
	@echo ""
	@echo "🌐 Access your broadcast admin panel:"
	@echo "   https://$(BROADCAST_DOMAIN)"
	@echo ""
	@echo "📡 Connected to MediaMTX:"
	@echo "   WebRTC: https://rtsp.racetrackstreaming.com:8889"
	@echo "   RTSP: rtsp://rtsp.racetrackstreaming.com:8554"
	@echo ""
	@echo "📊 Monitor deployment:"
	@echo "   make broadcast-aws-status"
	@echo "   make broadcast-aws-logs"

broadcast-aws-quick-deploy: broadcast-aws-push broadcast-aws-update dns-create-admin-record ## ⚡ Quick broadcast system update (build → push → update → DNS)
	@echo "⚡ Quick broadcast deployment initiated..."
	@echo "⏳ Waiting for new task to start (max 2 minutes)..."
	@for i in $$(seq 1 24); do \
		TASK_STATUS=$$(aws ecs describe-services --cluster $(BROADCAST_ECS_CLUSTER) --services $(BROADCAST_ECS_SERVICE) --region $(AWS_REGION) --query 'services[0].deployments[0].runningCount' --output text 2>/dev/null); \
		if [ "$$TASK_STATUS" -ge "1" ]; then \
			echo "✅ New task is RUNNING."; \
			break; \
		fi; \
		echo "⏳ Waiting for task to start... (attempt $$i/24)"; \
		sleep 5; \
	done
	@echo "✅ Quick deployment complete!"
	@echo "🌐 Access at: https://$(BROADCAST_DOMAIN)"

broadcast-aws-logs: ## 📋 View broadcast system logs
	@echo "📋 Getting broadcast system logs..."
	aws logs tail $(BROADCAST_LOG_GROUP) --follow --region $(AWS_REGION) 2>/dev/null || echo "⚠️ No logs available yet"

broadcast-aws-status: ## 📊 Show broadcast ECS service status
	@echo "📊 Broadcast ECS Service Status:"
	@echo "================================"
	@aws ecs describe-services \
		--cluster $(BROADCAST_ECS_CLUSTER) \
		--services $(BROADCAST_ECS_SERVICE) \
		--region $(AWS_REGION) \
		--query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
		--output table 2>/dev/null || echo "❌ Service not found"

broadcast-aws-cleanup: ## 🧹 Delete broadcast ECS service and task definition
	@echo "🧹 Cleaning up broadcast system..."
	aws ecs delete-service --cluster $(BROADCAST_ECS_CLUSTER) --service $(BROADCAST_ECS_SERVICE) --force --region $(AWS_REGION) 2>/dev/null || true
	aws ecs deregister-task-definition --task-definition $(BROADCAST_ECS_TASK_FAMILY) --region $(AWS_REGION) 2>/dev/null || true
	@echo "✅ Cleanup complete!"