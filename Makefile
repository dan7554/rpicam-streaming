.PHONY: all run server streams stop mediamtx build test clean

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
