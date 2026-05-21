#!/bin/bash
set -euo pipefail

# Install dependencies
apt-get update -y
apt-get install -y certbot

# Create app user and directory
useradd -r -m -s /bin/false photoshare || true
mkdir -p /opt/photoshare/data
chown -R photoshare:photoshare /opt/photoshare

# Write environment config
cat > /opt/photoshare/.env << 'ENVEOF'
PORT=8080
BASE_URL=https://${domain_name}
S3_BUCKET=${s3_bucket}
S3_REGION=${s3_region}
GOOGLE_CLIENT_ID=${google_client_id}
GOOGLE_CLIENT_SECRET=${google_client_secret}
SESSION_SECRET=${session_secret}
ADMIN_EMAILS=${admin_emails}
VENMO_USERNAME=${venmo_username}
DATA_DIR=/opt/photoshare/data
ENVEOF
chmod 600 /opt/photoshare/.env

# Create systemd service
cat > /etc/systemd/system/photoshare.service << 'EOF'
[Unit]
Description=Photo Share Application
After=network.target

[Service]
Type=simple
User=photoshare
Group=photoshare
WorkingDirectory=/opt/photoshare
EnvironmentFile=/opt/photoshare/.env
ExecStart=/opt/photoshare/photoshare
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Set up Caddy as reverse proxy for automatic HTTPS
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

cat > /etc/caddy/Caddyfile << CADDYEOF
${domain_name} {
    reverse_proxy localhost:8080
}
CADDYEOF

systemctl enable caddy
systemctl start caddy

# Enable the app (binary will be deployed separately)
systemctl daemon-reload
systemctl enable photoshare
