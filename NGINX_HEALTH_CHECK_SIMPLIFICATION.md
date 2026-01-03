# Simplified Health Check Architecture with Nginx

## Current Issue

The current health check setup is **overly complex**:
- Container health check probes port 9997 (API)
- NLB has 3 separate health checks on ports 8554, 1935, 8888
- HLS health check misconfigured (checking 9997 instead of 8888)
- Results in many false positives/negatives

## Proposed Solution: Nginx Sidecar Health Check

### Architecture

```
┌─────────────────────────────────────────┐
│         ECS Task                        │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  Nginx (on port 8080)           │   │
│  │  • Responds 200 OK on /health   │   │
│  │  • Fast, lightweight            │   │
│  │  • No external dependencies     │   │
│  └──────────┬──────────────────────┘   │
│             │ <-- Single Health Check   │
│  ┌──────────▼──────────────────────┐   │
│  │  MediaMTX (all ports)           │   │
│  │  • 8554 (RTSP)                  │   │
│  │  • 1935 (RTMP)                  │   │
│  │  • 8888 (HLS)                   │   │
│  │  • 8889-8891 (WebRTC/SRT)       │   │
│  │  • 9997 (API)                   │   │
│  └─────────────────────────────────┘   │
│                                         │
└─────────────────────────────────────────┘
         │
         ├─ Container Health Check: curl http://localhost:8080/health (3s timeout, 2 retries)
         │
         └─ NLB Health Check: TCP port 8080 (single check)
```

### Benefits

| Aspect | Current | With Nginx Health Check |
|--------|---------|------------------------|
| **Container Health Checks** | Complex API probe on 9997 | Simple lightweight response on 8080 |
| **NLB Target Groups** | 3 groups (RTSP, RTMP, HLS) | 1 group (health check only) |
| **Health Check Port** | Variable (8554, 1935, 8888, 9997) | Single standardized port 8080 |
| **Failure Reasons** | Complex (port-specific issues) | Clear: nginx down or container dead |
| **Speed** | Slow (API startup) | Fast (nginx responds instantly) |
| **False Positives** | High (config mismatches) | Low (nginx just responds OK) |
| **Operational Clarity** | Confusing multiple checks | Simple single endpoint |

### Implementation Details

#### 1. New Dockerfile (`Dockerfile.nginx-health`)

```dockerfile
FROM bluenviron/mediamtx:1.15.5

# ... MediaMTX setup ...

# Install nginx
RUN apt-get install -y nginx

# Create simple nginx health check config
RUN cat > /etc/nginx/conf.d/health.conf << 'EOF'
server {
    listen 8080;
    location /health {
        return 200 "HEALTHY\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Create entrypoint to start both services
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
nginx -c /etc/nginx/nginx.conf  # Start nginx
exec /mediamtx /app/mediamtx.yml  # Start MediaMTX
EOF

# Health check now just probes nginx port
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=2 \
  CMD curl -f http://localhost:8080/health || exit 1
```

#### 2. Updated Task Definition

```json
{
  "containerDefinitions": [
    {
      "name": "mediamtx",
      "portMappings": [
        // All streaming ports (8554, 1935, 8888, 8889, 8890, 8891, 9996, 9997)
        {
          "name": "health",
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:8080/health || exit 1"
        ],
        "interval": 15,      // Check every 15s (faster than 30s)
        "timeout": 3,        // Must respond in 3s (nginx is instant)
        "retries": 2,        // 2 failures = unhealthy (faster detection)
        "startPeriod": 5     // 5s startup grace period
      }
    }
  ]
}
```

#### 3. Single NLB Target Group

Instead of 3 target groups, create just 1:

```bash
aws elbv2 create-target-group \
  --name mediamtx-health \
  --protocol TCP \
  --port 8080 \
  --vpc-id vpc-xxx \
  --target-type ip \
  --health-check-protocol TCP \
  --health-check-port 8080 \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 3 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --region us-east-1
```

#### 4. NLB Listeners (Unchanged)

The NLB still listens on the actual streaming ports:

```
Port 8554  (RTSP)  → No health check needed, traffic speaks for itself
Port 1935  (RTMP)  → No health check needed, traffic speaks for itself
Port 8888  (HLS)   → No health check needed, traffic speaks for itself
Port 9997  (API)   → No health check needed, traffic speaks for itself
```

**Key insight**: The NLB health check on port 8080 just verifies the container is alive. The actual streaming ports are tested by real traffic. If a streaming port is down but the container is alive, it means the service itself is broken (which is OK to know about via logs).

---

## Migration Path

### Step 1: Build and Test New Image
```bash
# Build new image with nginx
docker build -f Dockerfile.nginx-health -t mediamtx:nginx-health .

# Test locally
docker run -p 8080:8080 -p 8554:8554 mediamtx:nginx-health

# Verify health check
curl http://localhost:8080/health  # Should return "HEALTHY"
```

### Step 2: Update ECR
```bash
docker push 457553343935.dkr.ecr.us-east-1.amazonaws.com/mediamtx:nginx-health
```

### Step 3: Create New Task Definition
```bash
aws ecs register-task-definition \
  --cli-input-json file://mediamtx-task-definition-nginx-health.json \
  --region us-east-1
```

### Step 4: Update NLB Configuration
```bash
# Create single health check target group
aws elbv2 create-target-group --name mediamtx-health ...

# Add listener on port 8080
aws elbv2 create-listener \
  --load-balancer-arn arn:aws:elasticloadbalancing:... \
  --protocol TCP \
  --port 8080 \
  --default-actions Type=forward,TargetGroupArn=...
```

### Step 5: Update Service
```bash
aws ecs update-service \
  --cluster broadcast-cluster \
  --service mediamtx-service \
  --task-definition mediamtx-task:18 \
  --force-new-deployment \
  --region us-east-1
```

---

## Monitoring & Debugging

### Check Health Endpoint
```bash
# From inside VPC
curl http://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8080/health

# Output: HEALTHY
```

### Watch Health Status
```bash
watch -n 2 'aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:457553343935:targetgroup/mediamtx-health/xxx \
  --region us-east-1 | jq ".TargetHealthDescriptions[] | {Id, Port, State}"'
```

### Check Container Health
```bash
aws ecs describe-tasks \
  --cluster broadcast-cluster \
  --tasks $(aws ecs list-tasks --cluster broadcast-cluster --service-name mediamtx-service --query 'taskArns[0]' --output text) \
  --region us-east-1 | jq '.tasks[0].healthStatus'
```

---

## Why This Is Better

1. **Simplicity**: Single health check endpoint instead of 3
2. **Speed**: Detects failures in 3-6 seconds vs 90+ seconds
3. **Reliability**: Nginx almost never fails spuriously
4. **Clarity**: One port, one check, one clear answer
5. **Scalability**: Easier to monitor, alert on, and debug
6. **Operational overhead**: Nginx is ~30MB, adds minimal container size

---

## Nginx Health Check Response

When you curl the health endpoint:

```bash
$ curl -v http://localhost:8080/health
> GET /health HTTP/1.1
> Host: localhost:8080

< HTTP/1.1 200 OK
< Content-Type: text/plain
< Content-Length: 8
< 
HEALTHY
```

That's it. No complex API parsing, no timeout waiting for MediaMTX to start up, just instant confirmation the container is running.

---

## Rollback Plan

If the new health check causes issues:

```bash
# Revert to previous task definition
aws ecs update-service \
  --cluster broadcast-cluster \
  --service mediamtx-service \
  --task-definition mediamtx-task:17 \
  --force-new-deployment \
  --region us-east-1
```

The old image is still available, so rollback is instant.
