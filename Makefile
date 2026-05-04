.PHONY: all run server streams stop mediamtx build test clean deploy deploy-config deploy-web logs ssh infra infra-plan infra-destroy

# Download MediaMTX binary if not present
MEDIAMTX_VERSION := 1.17.1
MEDIAMTX_BIN := ./bin/mediamtx
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    MEDIAMTX_ARCH := darwin_arm64
  else
    MEDIAMTX_ARCH := darwin_amd64
  endif
else
  ifeq ($(UNAME_M),aarch64)
    MEDIAMTX_ARCH := linux_arm64
  else
    MEDIAMTX_ARCH := linux_amd64
  endif
endif

MEDIAMTX_URL := https://github.com/bluenviron/mediamtx/releases/download/v$(MEDIAMTX_VERSION)/mediamtx_v$(MEDIAMTX_VERSION)_$(MEDIAMTX_ARCH).tar.gz

## run: Start everything (mediamtx + fake streams + go server)
run: build $(MEDIAMTX_BIN)
	@echo "==> Starting MediaMTX..."
	@$(MEDIAMTX_BIN) mediamtx.yml &
	@sleep 2
	@echo "==> Starting fake streams..."
	@bash scripts/fake-streams.sh &
	@sleep 3
	@echo "==> Starting Go server..."
	@./bin/server
	@echo "==> Open http://localhost:8080"

## build: Build the Go server
build:
	@echo "==> Building Go server..."
	@go build -o bin/server ./cmd/server/

## test: Run all unit tests
test:
	@echo "==> Running tests..."
	@go test ./... -count=1

## mediamtx: Download MediaMTX binary
$(MEDIAMTX_BIN):
	@echo "==> Downloading MediaMTX $(MEDIAMTX_VERSION) for $(MEDIAMTX_ARCH)..."
	@mkdir -p bin
	@curl -sL $(MEDIAMTX_URL) | tar -xz -C bin mediamtx
	@chmod +x $(MEDIAMTX_BIN)

## streams: Start only fake streams (assumes MediaMTX is running)
streams:
	@bash scripts/fake-streams.sh

## server: Start only the Go server (assumes MediaMTX + streams running)
server: build
	@cd $(CURDIR) && ./bin/server

## stop: Stop all background processes
stop:
	@echo "Stopping all..."
	@-pkill -f "mediamtx mediamtx.yml" 2>/dev/null || true
	@-pkill -f "fake-streams" 2>/dev/null || true
	@-pkill -f "ffmpeg.*lavfi.*cam" 2>/dev/null || true
	@-pkill -f "bin/server" 2>/dev/null || true
	@echo "Done."

## clean: Remove build artifacts
clean:
	@rm -rf bin/server

## help: Show this help
help:
	@echo "Usage: make [target]"
	@echo ""
	@grep -E '^## ' Makefile | sed 's/## /  /' | sort

# ============================================================
# AWS Deployment
# ============================================================

EC2_HOST := $(shell cd deploy/terraform && terraform output -raw ec2_public_ip 2>/dev/null)
EC2_USER := ubuntu
EC2_KEY := ~/.ssh/racetrack-streaming.pem
SSH_OPTS := -i $(EC2_KEY) -o StrictHostKeyChecking=no
DEPLOY_DIR := /opt/racetrack

## deploy: Cross-compile and deploy server + web + config to EC2
deploy: deploy-build
	@echo "==> Deploying to $(EC2_USER)@$(EC2_HOST)..."
	@scp $(SSH_OPTS) bin/server-linux $(EC2_USER)@$(EC2_HOST):/tmp/server
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo mv /tmp/server $(DEPLOY_DIR)/bin/server && sudo chmod +x $(DEPLOY_DIR)/bin/server"
	@sed 's/__EIP__/$(EC2_HOST)/g' deploy/mediamtx-aws.yml > /tmp/mediamtx-aws-deploy.yml
	@scp $(SSH_OPTS) /tmp/mediamtx-aws-deploy.yml $(EC2_USER)@$(EC2_HOST):/tmp/mediamtx.yml
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo mv /tmp/mediamtx.yml $(DEPLOY_DIR)/mediamtx.yml"
	@rm -f /tmp/mediamtx-aws-deploy.yml
	@rsync -az --delete -e "ssh $(SSH_OPTS)" web/ $(EC2_USER)@$(EC2_HOST):/tmp/racetrack-web/
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo rsync -a --delete /tmp/racetrack-web/ $(DEPLOY_DIR)/web/ && rm -rf /tmp/racetrack-web"
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo systemctl restart mediamtx stream-server"
	@echo "==> Deploy complete. UI: https://stream.racetrackstreaming.com"

## deploy-build: Cross-compile Go server for Linux amd64
deploy-build:
	@echo "==> Cross-compiling for Linux amd64..."
	@GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bin/server-linux ./cmd/server/

## deploy-config: Push only mediamtx.yml config changes
deploy-config:
	@echo "==> Deploying config to $(EC2_HOST)..."
	@sed 's/__EIP__/$(EC2_HOST)/g' deploy/mediamtx-aws.yml > /tmp/mediamtx-aws-deploy.yml
	@scp $(SSH_OPTS) /tmp/mediamtx-aws-deploy.yml $(EC2_USER)@$(EC2_HOST):/tmp/mediamtx.yml
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo mv /tmp/mediamtx.yml $(DEPLOY_DIR)/mediamtx.yml"
	@rm -f /tmp/mediamtx-aws-deploy.yml
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo systemctl restart mediamtx"
	@echo "==> Config deployed."

## deploy-web: Push only web UI changes (no restart needed)
deploy-web:
	@echo "==> Deploying web UI to $(EC2_HOST)..."
	@rsync -az --delete -e "ssh $(SSH_OPTS)" web/ $(EC2_USER)@$(EC2_HOST):/tmp/racetrack-web/
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo rsync -a --delete /tmp/racetrack-web/ $(DEPLOY_DIR)/web/ && rm -rf /tmp/racetrack-web"
	@echo "==> Web UI deployed (live on next page load)."

## deploy-server: Push only server binary and restart
deploy-server: deploy-build
	@echo "==> Deploying server binary to $(EC2_HOST)..."
	@scp $(SSH_OPTS) bin/server-linux $(EC2_USER)@$(EC2_HOST):/tmp/server
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo mv /tmp/server $(DEPLOY_DIR)/bin/server && sudo chmod +x $(DEPLOY_DIR)/bin/server"
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo systemctl restart stream-server"
	@echo "==> Server deployed."

## logs: Tail EC2 service logs
logs:
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST) "sudo journalctl -f -u mediamtx -u stream-server --no-hostname"

## ssh: SSH into EC2 instance
ssh:
	@ssh $(SSH_OPTS) $(EC2_USER)@$(EC2_HOST)

## infra: Apply Terraform infrastructure
infra:
	@cd deploy/terraform && terraform apply

## infra-plan: Preview Terraform changes
infra-plan:
	@cd deploy/terraform && terraform plan

## infra-init: Initialize Terraform
infra-init:
	@cd deploy/terraform && terraform init

## infra-destroy: Tear down ALL AWS resources (stops charges)
infra-destroy:
	@echo "⚠️  This will destroy ALL AWS resources (EC2, ALB, NLB, EIP, VPC)."
	@cd deploy/terraform && terraform destroy
