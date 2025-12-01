# Broadcast System Hostname Configuration Guide

## Overview

The broadcast system is configured to work with custom hostnames through environment variables. This allows you to:
- Use custom domain names in local development (e.g., `local.broadcast.com`)
- Deploy to production with your actual domain (e.g., `broadcast.example.com`)
- Generate SSL certificates matching your hostname

## Local Development Setup

### 1. Add Hostname to `/etc/hosts`

For macOS/Linux:
```bash
echo "127.0.0.1 local.broadcast.com" | sudo tee -a /etc/hosts
```

Verify:
```bash
grep broadcast /etc/hosts
```

### 2. Configuration

The broadcast system uses environment variables to configure the hostname:

- **BROADCAST_HOSTNAME**: The hostname to use (default: `localhost`)
- **BROADCAST_PORT**: The HTTPS port (default: `443`)
- **NODE_ENV**: Environment mode (default: `production`)

#### Local Configuration (`.env.local`)

```env
BROADCAST_HOSTNAME=local.broadcast.com
BROADCAST_PORT=443
NODE_ENV=production
PORT=3001
MEDIAMTX_URL=https://mediamtx:8889
```

#### Docker Compose Configuration

The `docker-compose.yml` sets the environment variables:

```yaml
environment:
  - NODE_ENV=production
  - PORT=3001
  - MEDIAMTX_URL=https://mediamtx:8889
  - BROADCAST_HOSTNAME=local.broadcast.com
  - BROADCAST_PORT=443
```

### 3. Generate SSL Certificates

Generate self-signed certificates for your hostname:

```bash
make broadcast-certs-generate
```

This creates:
- `/broadcast-system/certs/server.crt` - Self-signed certificate
- `/broadcast-system/certs/server.key` - Private key

The certificate CN (Common Name) will match your `BROADCAST_HOSTNAME`.

### 4. Access the System

Once configured, access via:
- **Web UI**: `https://local.broadcast.com/`
- **API Base**: `https://local.broadcast.com/api`
- **Health Check**: `https://local.broadcast.com/api/health`

**Note**: Browser may show SSL warning for self-signed certificate - this is expected and safe for development.

## Production Deployment

### Using a Real Domain

1. **Update `docker-compose.yml`**:

```yaml
environment:
  - BROADCAST_HOSTNAME=broadcast.yourdomain.com
  - BROADCAST_PORT=443
```

2. **Configure DNS**:
Ensure your domain points to your server:
```
broadcast.yourdomain.com A RECORD -> YOUR_SERVER_IP
```

3. **Generate SSL Certificates**:

Option A - Self-signed (for testing):
```bash
# Edit Makefile or docker-entrypoint.sh to use your domain
make broadcast-certs-generate
```

Option B - Let's Encrypt (recommended):
```bash
# Configure certbot for automatic renewal
# Obtain certificates from Let's Encrypt
# Mount them in docker-compose.yml
```

4. **Update docker-compose.yml volumes** for production certificates:

```yaml
volumes:
  - /etc/letsencrypt/live/broadcast.yourdomain.com/fullchain.pem:/etc/nginx/certs/server.crt
  - /etc/letsencrypt/live/broadcast.yourdomain.com/privkey.pem:/etc/nginx/certs/server.key
  - ./broadcast-system/certs:/etc/nginx/certs/backup
```

5. **Restart Services**:

```bash
docker compose down
docker compose up -d
```

## Testing

Run the included test script:

```bash
bash /tmp/test_broadcast.sh
```

This validates:
- ✅ API health check
- ✅ Cameras endpoint
- ✅ Web UI serving
- ✅ SSL certificate CN matches hostname
- ✅ Hostname in system `/etc/hosts` (if local)

## Troubleshooting

### Certificate CN Mismatch

If the certificate CN doesn't match your hostname:

1. Delete existing certificates:
```bash
rm -rf broadcast-system/certs/*
```

2. Update `BROADCAST_HOSTNAME` in `docker-compose.yml`

3. Regenerate certificates:
```bash
make broadcast-certs-generate
```

4. Restart containers:
```bash
docker compose restart broadcast-system
```

### Hostname Not Resolving

Ensure the hostname is in `/etc/hosts` (local development):
```bash
grep your.hostname /etc/hosts
```

For production, use DNS records instead.

### SSL/TLS Warnings

For self-signed certificates, browsers will show security warnings - this is normal. Accept the certificate to proceed.

For production, use Let's Encrypt or another trusted CA.

## Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `BROADCAST_HOSTNAME` | `localhost` | Hostname for the broadcast system |
| `BROADCAST_PORT` | `443` | HTTPS port |
| `NODE_ENV` | `production` | Node environment |
| `PORT` | `3001` | Express server port (internal) |
| `MEDIAMTX_URL` | `https://mediamtx:8889` | MediaMTX server URL |

## Files Modified for Hostname Support

1. **docker-compose.yml** - Added environment variables
2. **broadcast-system/docker-entrypoint.sh** - Uses hostname for startup messages and certificate generation
3. **broadcast-system/nginx-ssl.conf** - Accepts all hostnames (`server_name _`)
4. **Makefile** - `broadcast-certs-generate` target uses `local.broadcast.com`
