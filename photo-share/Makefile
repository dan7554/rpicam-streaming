.PHONY: build run deploy clean test

BINARY := photoshare
REMOTE_HOST ?= $(shell cd terraform && terraform output -raw elastic_ip 2>/dev/null)
SSH_KEY ?= ~/.ssh/racetrack-streaming.pem
SSH_USER ?= ubuntu

build:
	cd .. && cd photo-share && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o $(BINARY) .

run:
	go run .

tidy:
	go mod tidy

deploy: build
	@echo "Deploying to $(REMOTE_HOST)..."
	scp -i $(SSH_KEY) -o StrictHostKeyChecking=no $(BINARY) $(SSH_USER)@$(REMOTE_HOST):/tmp/$(BINARY)
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no $(SSH_USER)@$(REMOTE_HOST) "\
		sudo systemctl stop photoshare || true && \
		sudo mv /tmp/$(BINARY) /opt/photoshare/$(BINARY) && \
		sudo chown photoshare:photoshare /opt/photoshare/$(BINARY) && \
		sudo chmod +x /opt/photoshare/$(BINARY) && \
		sudo systemctl start photoshare"
	@echo "Deploy complete!"

infra-init:
	cd terraform && terraform init

infra-plan:
	cd terraform && terraform plan

infra-apply:
	cd terraform && terraform apply

infra-destroy:
	cd terraform && terraform destroy

clean:
	rm -f $(BINARY)

docker-build:
	docker build -t $(BINARY) .

docker-run: docker-build
	docker run --rm -p 8080:8080 --env-file .env $(BINARY)
