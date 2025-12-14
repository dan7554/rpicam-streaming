# Architecture & Troubleshooting Guide

## 🏗️ Complete System Architecture

### Full Stack Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     INTERNET / CLOUDFLARE                        │
│  (SSL/TLS Termination, DDoS Protection, DNS)                    │
│  admin.racetrackstreaming.com                                   │
└────────────────────┬────────────────────────────────────────────┘
                     │ HTTPS (443)
┌────────────────────▼────────────────────────────────────────────┐
│         AWS Application Load Balancer (broadcast-alb)            │
│  broadcast-alb-1234567890.us-east-2.elb.amazonaws.com          │
│  ├─ Listener HTTP (80) → Redirect to HTTPS                     │
│  └─ Listener HTTPS (443) → forward to broadcast-tg             │
└────────────────────┬────────────────────────────────────────────┘
                     │ HTTP:3001 (Internal)
┌────────────────────▼────────────────────────────────────────────┐
│            Target Group (broadcast-tg)                           │
│  ├─ Health Check: /health (port 3001)                          │
│  ├─ Interval: 30s, Timeout: 5s                                 │
│  └─ Targets: ECS Tasks                                          │
└────────────────────┬────────────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        │                         │
┌───────▼──────┐        ┌────────▼────────┐
│  ECS Task 1  │        │  ECS Task 2     │ (Optional scaling)
│              │        │                 │
│ Container:   │        │ Container:      │
│ broadcast-   │        │ broadcast-      │
│ system       │        │ system          │
│              │        │                 │
│ Ports:       │        │ Ports:          │
│ 80 (HTTP)    │        │ 80 (HTTP)       │
│ 443 (HTTPS)  │        │ 443 (HTTPS)     │
│ 3001 (App)   │        │ 3001 (App)      │
└───────┬──────┘        └────────┬────────┘
        │                        │
        │  localhost             │  localhost
        │
        ├──────────────────────────────┐
        │                              │
   ┌────▼───┐                   ┌─────▼──┐
   │MediaMTX│                   │MediaMTX│ (Separate cluster)
   │Port    │                   │Port    │
   │8554    │                   │8554    │
   │8888    │                   │8888    │
   │8889    │                   │8889    │
   └────────┘                   └────────┘
```

### Component Details

#### 1. **Cloudflare (DNS & SSL)**
```
Role: DNS resolution + SSL/TLS termination
Features:
  • Free SSL certificate (DigiCert)
  • DDoS protection
  • DNS failover
  • Automatic HTTPS redirect

Connection:
  • admin.racetrackstreaming.com → Cloudflare nameservers
  • Cloudflare proxies traffic to ALB
  • Client ←HTTPS→ Cloudflare ←HTTP→ ALB
```

#### 2. **AWS ALB (Application Load Balancer)**
```
Role: HTTP load balancing and traffic routing
Features:
  • Health checks (every 30 seconds)
  • Automatic failover
  • SSL termination (HTTP between ALB and target)
  • Request routing by hostname/path

Connection:
  • Port 80: HTTP requests → redirect to HTTPS
  • Port 443: HTTPS requests → forward to target group
  • Target group monitors healthy tasks
  • Sends traffic to healthy ECS tasks
```

#### 3. **ECS Tasks (Broadcast System)**
```
Role: Application server
Features:
  • Node.js application
  • React frontend
  • Camera configuration API
  • Health endpoint: /health

Ports:
  • 80: HTTP (redirects to 443)
  • 443: HTTPS (serves web UI)
  • 3001: Internal app port (ALB connects here)

Environment:
  • NODE_ENV=production
  • MEDIAMTX_URL=https://rtsp.racetrackstreaming.com:8889
```

#### 4. **MediaMTX Integration**
```
Role: Streaming server (separate)
Location: localhost:8554 (within same VPC or EC2)

Broadcast System connects to:
  • RTSP: localhost:8554 (stream ingestion)
  • HLS: localhost:8888 (stream distribution)
  • WebRTC: localhost:8889 (web viewer)

Note: MediaMTX can be deployed separately with its own ALB
```

---

## 🔄 Request Flow

### User accessing admin.racetrackstreaming.com

```
1. Browser sends HTTPS request
   GET https://admin.racetrackstreaming.com/

2. Cloudflare intercepts
   • DNS resolves to Cloudflare IP
   • SSL/TLS handshake with client
   • Validates certificate (green lock in browser)

3. Cloudflare forwards to ALB
   GET http://broadcast-alb-xxx.us-east-2.elb.amazonaws.com/

4. ALB receives request
   • Checks health of target group
   • Selects healthy ECS task
   • Forwards request to task port 3001

5. ECS Task processes request
   • React app serves index.html
   • Connects to MediaMTX for stream
   • Returns response

6. Response flows back
   Task → ALB → Cloudflare → Browser
   Browser shows response with green SSL lock
```

### Streaming flow (RTSP to Web Viewer)

```
1. User clicks stream in Broadcast UI
   Browser: WebRTC viewer loads

2. Browser connects to WebRTC endpoint
   WebRTC ←→ Broadcast app ←→ MediaMTX
   
   Path:
   Browser (WebRTC) 
     → ALB (port 8889) 
     → Broadcast container 
     → MediaMTX (localhost:8889)

3. MediaMTX handles stream
   RTSP ingestion (from Pi camera)
     ↓
   WebRTC encoding
     ↓
   Client playback
```

---

## ⚡ Data Flow Sequence

```
User's Browser            Cloudflare           AWS ALB          ECS Task        MediaMTX
      │                       │                  │                │               │
      │──1. HTTPS request─────│                  │                │               │
      │ admin.racetrack       │                  │                │               │
      │                       │                  │                │               │
      │                       │──2. HTTP fwd───→│                │               │
      │                       │ (stripped SSL)   │                │               │
      │                       │                  │                │               │
      │                       │                  │──3. Forward───→│               │
      │                       │                  │ to port 3001   │               │
      │                       │                  │                │               │
      │                       │                  │                │──4. Check────→
      │                       │                  │                │ stream status
      │                       │                  │                │               │
      │                       │                  │                │←5. Stream───  │
      │                       │                  │                │ metadata      │
      │                       │                  │                │               │
      │                       │                  │←6. Response──←─│               │
      │                       │                  │ (HTML)         │               │
      │                       │                  │                │               │
      │                       │←7. HTTP response │                │               │
      │ (as HTTPS)            │                  │                │               │
      │←8. HTTPS response─────│                  │                │               │
      │ [HTML page loaded]    │                  │                │               │
      │                       │                  │                │               │
      │──9. WebRTC connect────│                  │                │               │
      │ request               │                  │                │               │
      │                       │──10. Forward───→│                │               │
      │                       │ WebRTC signal   │                │               │
      │                       │                  │──11. Forward──→│               │
      │                       │                  │ port 8889      │               │
      │                       │                  │                │──12. Init───→│
      │                       │                  │                │ WebRTC       │
      │                       │                  │                │←13. SDP───  │
      │                       │                  │                │ answer      │
      │                       │                  │←14. Forward────│               │
      │                       │←15. WebRTC sig.─│                │               │
      │←16. ICE/DTLS ─────────│────→ [P2P stream established] ←───│               │
      │ [Video streaming]     │                  │                │               │
```

---

## 🔍 Health Check Flow

### ALB Health Monitoring

```
ALB Target Group (broadcast-tg)
├─ Health check: GET http://task-ip:3001/health
├─ Interval: 30 seconds
├─ Timeout: 5 seconds
├─ Healthy threshold: 2 (must pass 2 checks to mark healthy)
└─ Unhealthy threshold: 3 (must fail 3 checks to mark unhealthy)

Healthy Task Status:
  • Initially: Registering
  • After first 2 checks: InService (healthy)
  • Receives traffic

Unhealthy Task Status:
  • After 3 failed checks: Unhealthy
  • ALB stops sending traffic
  • ECS may restart task (if auto-restart enabled)
  • Task re-registers when healthy

Response Expected:
  HTTP/1.1 200 OK
  Content-Type: application/json
  {"status": "ok"}
```

---

## 🚨 Troubleshooting Decision Tree

### Problem: "Connection Refused"

```
┌─ Is service running?
│  ├─ Check: make broadcast-aws-status
│  ├─ Running count > 0? YES → next
│  └─ Running count = 0? STOP → make broadcast-aws-update
│
├─ Is task healthy?
│  ├─ Check: aws elbv2 describe-target-health --target-group-arn <ARN>
│  ├─ State = InService? YES → next
│  ├─ State = Registering? WAIT → 2-3 minutes then retry
│  ├─ State = Unhealthy? RESTART → make broadcast-aws-update
│  └─ State = Draining? CHECK LOGS → make broadcast-aws-logs
│
├─ Is security group allowing traffic?
│  ├─ Check: AWS Console → Security Groups → broadcast-alb-sg
│  ├─ Inbound 80, 443 allowed? YES → next
│  └─ Missing rules? ADD → make broadcast-alb-create
│
├─ Is ALB responding on direct DNS?
│  ├─ Test: curl http://<ALB-DNS>/health
│  ├─ 200 OK? YES → DNS problem (see below)
│  ├─ 503 Service Unavailable? → target health issue (see above)
│  └─ Connection timeout? → security group issue
│
└─ Is domain DNS correct?
   ├─ Check: dig admin.racetrackstreaming.com
   ├─ Points to ALB DNS? YES → SSL issue (see below)
   └─ Wrong IP? → UPDATE DNS
```

### Problem: "SSL Certificate Error"

```
┌─ Browser shows untrusted certificate
│  │
│  ├─ Is Cloudflare enabled?
│  │  ├─ YES: Wait 5 minutes → browser cache clear
│  │  └─ NO: Setup Cloudflare → make cloudflare-setup-guide
│  │
│  ├─ Does certificate match domain?
│  │  ├─ cert: *.racetrackstreaming.com, domain: admin.racetrackstreaming.com
│  │  └─ Get wildcard or subject alternate names
│  │
│  └─ Is certificate expired?
│     ├─ Check: openssl s_client -connect admin.racetrackstreaming.com:443
│     └─ If expired: Update in Cloudflare or AWS ACM
│
└─ Browser shows connection not private
   ├─ Likely: Self-signed or untrusted CA
   └─ Solution: Use Cloudflare (free trusted certificate)
      make cloudflare-setup-guide
```

### Problem: "HTTP 503 Service Unavailable"

```
┌─ ALB responding but service not available
│  │
│  ├─ Check task health
│  │  ├─ Command: aws elbv2 describe-target-health --target-group-arn <ARN>
│  │  ├─ State: Unhealthy? → Check logs
│  │  │  └─ Command: make broadcast-aws-logs
│  │  ├─ State: Registering? → Wait 1-2 minutes
│  │  └─ State: Draining? → Old task shutting down
│  │
│  ├─ Check application logs
│  │  ├─ Command: make broadcast-aws-logs
│  │  ├─ Errors? → Fix and redeploy
│  │  └─ No logs? → Task might not be running
│  │
│  ├─ Check health endpoint directly
│  │  ├─ Command: curl http://<TASK-IP>:3001/health
│  │  ├─ 200 OK? → ALB configuration issue
│  │  ├─ Connection refused? → App not listening
│  │  └─ 503? → App internal error
│  │
│  └─ Restart service
│     └─ Command: make broadcast-aws-update
└─ Wait 2-3 minutes and retry
```

### Problem: "DNS Not Resolving"

```
┌─ Can't access admin.racetrackstreaming.com
│  │
│  ├─ Check DNS record exists
│  │  ├─ Command: dig admin.racetrackstreaming.com
│  │  ├─ Result: Should show IP or CNAME
│  │  ├─ NXDOMAIN? → Record doesn't exist
│  │  │  └─ Create in: Route53 or Cloudflare
│  │  └─ CNAME with wrong target? → Update
│  │
│  ├─ Wait for DNS propagation
│  │  ├─ DNS caches for 5-300 seconds (TTL)
│  │  ├─ Propagation to ISPs: 5-30 minutes
│  │  └─ Wait then retry: dig admin.racetrackstreaming.com +nocache
│  │
│  ├─ Check with different DNS servers
│  │  ├─ dig @8.8.8.8 admin.racetrackstreaming.com (Google)
│  │  ├─ dig @1.1.1.1 admin.racetrackstreaming.com (Cloudflare)
│  │  └─ If different results: propagation in progress
│  │
│  └─ Verify ALB DNS is correct
│     ├─ Command: make broadcast-alb-get-dns
│     ├─ Copy ALB DNS name
│     └─ Use in DNS record
```

### Problem: "High Latency or Slow Response"

```
┌─ Application responds but slowly (>2 seconds)
│  │
│  ├─ Check ALB
│  │  ├─ CPU utilization?
│  │  ├─ Network In/Out?
│  │  └─ AWS Console → EC2 → Load Balancers
│  │
│  ├─ Check ECS Task
│  │  ├─ CPU: 512 (1024m available)?
│  │  ├─ Memory: 1024 (enough for Node.js)?
│  │  └─ Consider upgrading if consistently >80%
│  │
│  ├─ Check MediaMTX backend
│  │  ├─ Streaming from Pi camera?
│  │  ├─ Camera streaming to MediaMTX?
│  │  └─ Check: make ecs-logs
│  │
│  ├─ Check network latency
│  │  ├─ Command: ping admin.racetrackstreaming.com
│  │  ├─ Normal: <50ms
│  │  ├─ Slow: >500ms might indicate region issues
│  │  └─ Consider: EC2 region closer to you
│  │
│  └─ Increase task resources
│     ├─ Modify task definition
│     ├─ Increase CPU: 512 → 1024
│     ├─ Increase Memory: 1024 → 2048
│     └─ Redeploy: make broadcast-aws-update
```

---

## 📊 Monitoring Checklist

### Daily
- [ ] Service status: `make broadcast-aws-status`
- [ ] Recent logs: `make broadcast-aws-logs | tail -100`
- [ ] Target health: `aws elbv2 describe-target-health --target-group-arn <ARN>`

### Weekly
- [ ] Cost estimate: `make aws-cost-estimate`
- [ ] Resource usage: `make aws-list-resources`
- [ ] DNS resolution: `make dns-check`
- [ ] SSL certificate: Check expiry in browser

### Monthly
- [ ] Cost review and optimization
- [ ] Update documentation
- [ ] Security audit: Check security groups
- [ ] Performance analysis: Review CloudWatch metrics

### Before Deployments
```bash
# Always verify current state
make broadcast-aws-status
make broadcast-alb-info

# Test health endpoint
curl https://admin.racetrackstreaming.com/health

# Check recent logs for warnings
make broadcast-aws-logs | grep -E "ERROR|WARNING" | tail -20

# Then proceed with deployment
make broadcast-aws-push
make broadcast-aws-update
```

---

## 🆘 Emergency Procedures

### Service Down (503 errors)

```bash
# 1. Check task status
make broadcast-aws-status

# 2. Check task health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names broadcast-tg \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --region us-east-2

# 3. Check logs for errors
make broadcast-aws-logs | tail -50

# 4. Restart service
make broadcast-aws-update

# 5. Wait 2-3 minutes for task to start
sleep 180

# 6. Verify health
curl https://admin.racetrackstreaming.com/health

# 7. If still down, check security groups
# AWS Console → VPC → Security Groups → broadcast-sg
# Ensure inbound from ALB security group on port 3001
```

### High Costs Alert

```bash
# 1. Check current resources
make aws-list-resources

# 2. Identify unused resources
# Look for: stopped tasks, orphaned load balancers

# 3. Delete unused resources
# Example: delete unused ALB
make broadcast-alb-cleanup

# 4. Or stop all compute (temporary)
make aws-stop-services

# 5. Review cost estimate
make aws-cost-estimate

# 6. Plan optimization
# - Right-size instances
# - Use reserved capacity
# - Delete unused resources
```

### Deployment Issues

```bash
# Roll back to previous version
# 1. ECS keeps 4 previous task definitions
# 2. View available versions
aws ecs list-task-definitions --family-prefix broadcast-task

# 3. Update service to previous version
aws ecs update-service \
  --cluster broadcast-cluster \
  --service broadcast-service \
  --task-definition broadcast-task:X \
  --force-new-deployment

# 4. Verify
make broadcast-aws-status
```

---

## 📞 Support Resources

### AWS Documentation
- [ALB Documentation](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/)
- [ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [Route53 Documentation](https://docs.aws.amazon.com/route53/)

### Cloudflare Documentation
- [Cloudflare DNS](https://developers.cloudflare.com/dns/)
- [SSL/TLS](https://developers.cloudflare.com/ssl/)
- [API Documentation](https://developers.cloudflare.com/api/)

### Local Documentation
- `README.md` - Project overview
- `BROADCAST_ALB_DEPLOYMENT.md` - ALB setup guide
- `AWS_DEPLOYMENT_COMMANDS.md` - Command reference

---

## 🎯 Quick Reference

### Key Commands

```bash
# Check everything
make broadcast-aws-status
make broadcast-alb-info
make dns-check

# View logs in real-time
make broadcast-aws-logs

# Get URLs
make broadcast-alb-get-dns

# Restart
make broadcast-aws-update

# Full redeploy
make broadcast-aws-deploy
```

### Key URLs

```
Admin Dashboard:       https://admin.racetrackstreaming.com
ALB Direct:            http://broadcast-alb-xxx.us-east-2.elb.amazonaws.com
Health Endpoint:       https://admin.racetrackstreaming.com/health
```

### Key Metrics

```
ALB Response Time:     <100ms (normal)
Target Health:        "healthy" (in service)
CPU Utilization:      <70% (healthy)
Memory Utilization:   <80% (healthy)
Error Rate:           <0.5% (acceptable)
```

---

*Last Updated: 2024 | For support, check AWS and Cloudflare documentation*
