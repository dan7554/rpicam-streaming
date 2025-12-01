# Quick Start Guide - Broadcast System Container

## Prerequisites

- Docker (20.10+)
- Docker Compose (1.29+)
- 2GB RAM minimum
- 1GB disk space

## Quick Start (5 minutes)

### 1. Generate SSL Certificates

```bash
mkdir -p broadcast-system/certs

# Generate self-signed certificate
openssl req -x509 -newkey rsa:4096 \
  -keyout broadcast-system/certs/server.key \
  -out broadcast-system/certs/server.crt \
  -days 365 -nodes \
  -subj "/C=US/ST=State/L=City/O=Org/CN=localhost"

chmod 600 broadcast-system/certs/server.key
chmod 644 broadcast-system/certs/server.crt
```

### 2. Build the Docker Image

```bash
cd broadcast-system

# Build with docker
docker build -t broadcast-system:latest .

# Or with docker-compose from root
cd ..
docker-compose build broadcast-system
```

### 3. Run with Docker Compose

```bash
# Start all services (MediaMTX + Broadcast System)
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f broadcast-system
```

### 4. Access the Application

- **Web UI**: https://localhost
- **API**: https://localhost/api
- **Health Check**: http://localhost/health

Note: Browser will warn about self-signed certificate. Click "Advanced" and "Proceed".

## Verification

### Check if services are running

```bash
docker-compose ps
```

Expected output:
```
NAME              STATUS              PORTS
mediamtx-server   Up 2 minutes        0.0.0.0:8554->8554/tcp, ...
broadcast-system  Up 1 minute         0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
```

### Test health endpoint

```bash
# Should return "healthy"
curl http://localhost/health

# Or with verbose output
curl -v http://localhost/health
```

### Test API endpoint

```bash
# Should return API response
curl -k https://localhost/api/cameras
```

### View application logs

```bash
# Broadcast system logs
docker-compose logs broadcast-system

# MediaMTX logs
docker-compose logs mediamtx-server

# Follow logs in real-time
docker-compose logs -f
```

## Common Tasks

### Stop services

```bash
docker-compose down
```

### Restart services

```bash
docker-compose restart broadcast-system
```

### Rebuild and restart

```bash
docker-compose up --build -d broadcast-system
```

### Access shell in running container

```bash
docker-compose exec broadcast-system sh
```

### View nginx configuration

```bash
docker-compose exec broadcast-system cat /etc/nginx/conf.d/default.conf
```

### Test nginx configuration

```bash
docker-compose exec broadcast-system nginx -t
```

### View SSL certificate info

```bash
docker-compose exec broadcast-system openssl x509 \
  -in /etc/nginx/certs/server.crt \
  -text -noout
```

## Troubleshooting

### "Connection refused" error

```bash
# Check if container is running
docker-compose ps broadcast-system

# View logs for errors
docker-compose logs broadcast-system

# Restart container
docker-compose restart broadcast-system
```

### SSL certificate errors

```bash
# Check if certificates exist
docker-compose exec broadcast-system ls -la /etc/nginx/certs/

# Regenerate certificates
docker-compose exec broadcast-system rm -f /etc/nginx/certs/server.*
docker-compose restart broadcast-system
```

### Port already in use

```bash
# Find process using port 80 or 443
lsof -i :80
lsof -i :443

# Kill the process (macOS/Linux)
kill -9 <PID>

# Or use different port in docker-compose.yml
# Change: ports:
#   - "8080:80"
#   - "8443:443"
```

### WebSocket connection issues

```bash
# Check socket.io connectivity
docker-compose exec broadcast-system curl \
  http://localhost:3001/socket.io/?EIO=4&transport=polling
```

## Configuration

### Change MediaMTX URL

Edit `docker-compose.yml`:

```yaml
broadcast-system:
  environment:
    - MEDIAMTX_URL=https://mediamtx.example.com:8889
```

### Use custom SSL certificates

Place your certificates in `broadcast-system/certs/`:
- `server.crt` - Certificate file
- `server.key` - Private key

Then restart:

```bash
docker-compose restart broadcast-system
```

### Enable debug logging

Edit `docker-compose.yml`:

```yaml
broadcast-system:
  environment:
    - NODE_ENV=development
    - LOG_LEVEL=debug
```

## Production Deployment

For production, use:

1. **Let's Encrypt certificates** instead of self-signed:

```bash
# Install certbot
sudo apt-get install certbot

# Generate certificate
sudo certbot certonly --standalone -d yourdomain.com

# Copy to broadcast-system/certs/
sudo cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem broadcast-system/certs/server.crt
sudo cp /etc/letsencrypt/live/yourdomain.com/privkey.pem broadcast-system/certs/server.key
sudo chmod 644 broadcast-system/certs/server.crt
sudo chmod 600 broadcast-system/certs/server.key
```

2. **Use environment variables** for sensitive data:

```bash
# Create .env file
cp broadcast-system/.env.production broadcast-system/.env

# Edit with your settings
nano broadcast-system/.env

# Load in docker-compose.yml
env_file:
  - broadcast-system/.env
```

3. **Configure firewall**:

```bash
# Allow only necessary ports
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

4. **Set up reverse proxy** (nginx/Apache) if running behind another proxy

5. **Enable monitoring and logging**

## Next Steps

See `CONTAINERIZATION.md` for:
- Advanced configuration
- Performance tuning
- Security hardening
- Kubernetes deployment
- Scaling strategies

## Support

For issues, check:
1. `docker-compose logs` output
2. `CONTAINERIZATION.md` troubleshooting section
3. `broadcast-system/README.md` for application docs
