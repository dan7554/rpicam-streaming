# EC2 Solution - Pitfall Analysis

## Executive Summary

The EC2 solution is **configured but not operational**. While infrastructure exists, there are critical issues blocking deployment.

---

## Critical Pitfalls

### 1. **EC2 Service Has 0/2 Running Tasks (57 Failed Attempts)**
- **Status**: ❌ BLOCKING
- **Evidence**: 
  - Service: `mediamtx-service-ec2`
  - Desired: 2 tasks
  - Running: 0 tasks
  - Failed: 57 tasks
  - Deployment: IN_PROGRESS (since Dec 22, 13:52 - **11+ hours**)
  
- **Root Cause**: Container instances NOT registered with ECS cluster
  - EC2 instances exist: `i-072746f58e85c9dda`, `i-0be0097c375b4f118` (running since 17:03 UTC)
  - BUT no container instances appear in: `aws ecs list-container-instances`
  - ECS agent either not running or not connecting to cluster
  
- **Impact**: Service cannot place ANY tasks
- **Why It Happened**: 
  - User-data script deployed but ECS agent never registered instances
  - Likely causes:
    - ECS daemon not started/enabled
    - IAM permissions missing
    - Network connectivity issues between instance and ECS
    - Container instances resource constraints

### 2. **Network Connectivity Issue - ROOT CAUSE IDENTIFIED**
- **Status**: ❌ **CRITICAL ROOT CAUSE** - NLB MISCONFIGURED
- **Evidence**:
  - NLB DNS: `broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com`
  - VPC: `vpc-070fc6caa87f0f18d`
  - **NLB Subnets: NONE (null/empty)**
  - **Task Subnets: subnet-0ca6ac2ba55ade51b (us-east-1c, 172.31.16.0/20)**
  
- **Root Cause**: NLB created without subnet configuration
  - NLB has no subnets, so it cannot receive traffic
  - Even though VPC is correct, NLB is not deployed to any subnet
  - This explains why ALL health checks fail on ALL ports
  - This is not a routing issue - it's a deployment issue
  
- **Impact**: 
  - NLB cannot receive ANY traffic from external sources
  - Affects BOTH Fargate and EC2 solutions
  - **Complete blocker for both**
  
- **Why This Happened**:
  - NLB created via CloudFormation or Makefile without subnet configuration
  - Common mistake: VPC specified but subnets not allocated
  - Health checks fail because NLB isn't even in the network path

### 3. **MediaMTX Configuration Mismatch**
- **Status**: ⚠️ RESOLVED but fragile
- **Issue**: 
  - Production config: `mediamtx.yml` (API on port 9997 with HTTPS)
  - Container config: `mediamtx-container.yml` (API on port 9997 without HTTPS)
  - EC2 task def health check: `curl -f http://localhost:8890/v3/info`
  
- **Evidence**:
  - Health checks hardcoded to port 8890 (which is SRT, not API)
  - Container config was updated to 9997 but health check in Makefile still references 8890
  - Cert mismatch caused TLS errors
  
- **Impact**: If EC2 service starts, health checks will still fail
- **What Was Done**: Changed container config to port 9997 HTTP (disabled TLS)

### 4. **IAM Role Naming Mismatch**
- **Status**: ⚠️ MINOR
- **Issue**: 
  - Makefile expects: `ecsInstanceProfile`
  - Makefile tries to use: `Name=ecsInstanceProfile`
  - AWS accepted this (role exists and instance profile exists)
  
- **Evidence**: Instance profile exists and is attached to running instances
- **Impact**: Low - already works
- **Why It Matters**: Shows Makefile references weren't validated

### 5. **EC2 Task Definition Health Check Wrong**
- **Status**: ❌ WILL FAIL WHEN FIXED
- **Issue**: 
  - Health check: `curl -f http://localhost:8890/v3/info`
  - Port 8890: SRT server (not HTTP/API)
  - Actual API: Port 9997
  
- **Evidence**: Makefile line 350
  - Hardcoded to 8890 path `/v3/info`
  - `/v3/info` endpoint may not exist (not in standard MediaMTX)
  
- **Impact**: Even with ECS agent running, tasks will fail health checks
- **Why**: Copy-paste from broken Fargate configuration

### 6. **No CloudWatch Logs Analysis**
- **Status**: ⚠️ DIAGNOSTIC
- **Issue**: Cannot see EC2 instance startup logs
  - SSM agent not responding (instances not in "valid state")
  - No SSH key directly accessible
  - ECS logs not appearing in CloudWatch
  
- **Evidence**: Cannot run SSM Session Manager commands
- **Impact**: Blind debugging - can't see what's happening on EC2 instances
- **Why**: Instances may not have SSM agent or IAM permissions

### 7. **Fargate-to-EC2 Port Mismatch**
- **Status**: ⚠️ INFRASTRUCTURE ISSUE
- **Issue**: 
  - Fargate (broken): Uses all 4 target groups (RTSP, RTMP, HLS, API)
  - EC2 (planned): Only configures mediamtx-service-ec2
  - No explicit NLB target group configuration in EC2 Makefile
  
- **Evidence**: 
  - EC2 service created but no target group associations defined
  - Makefile has no targets for: `mediamtx-ec2-nlb`, `mediamtx-ec2-targets`
  
- **Impact**: If EC2 service starts, tasks won't be registered with NLB
- **Why**: Incomplete EC2 deployment automation

### 8. **Deployment Automation Incomplete**
- **Status**: ❌ INCOMPLETE
- **Missing Steps in Makefile**:
  ```
  Missing:
  - mediamtx-ec2-nlb (create/update NLB for EC2)
  - mediamtx-ec2-target-groups (register EC2 targets)
  - EC2 instance health check configuration
  - EC2 instance initialization verification
  - Container instance registration verification
  ```
  
- **Evidence**: 
  - Makefile has `mediamtx-ec2-launch` but no targets registration
  - Service creation assumes container instances exist
  - No validation that ECS agent is running
  
- **Impact**: Even if instances boot, service can't place tasks

---

## Comparison: Fargate vs EC2

| Factor | Fargate | EC2 |
|--------|---------|-----|
| **Task Placement** | 0/2 (failing) | 0/2 (failing) |
| **Root Cause** | NLB can't reach tasks | No container instances |
| **Fix Complexity** | Network routing (could be hard) | ECS agent + NLB config |
| **Startup Time** | 30-60 seconds | 1-2 minutes (boot + ECS init) |
| **Cost** | ~$45-60/month | ~$15-20/month |
| **Debugging** | CloudWatch logs (available) | SSM (not working) |

**Verdict**: 
- Fargate is CLOSER to working (tasks start, just can't reach them)
- EC2 has FUNDAMENTAL blocking issue (no container instances)
- **Both require fixing the NLB/network routing issue**

---

## What Needs to Be Done

## Immediate (Required for Either Solution)

**1. URGENT: Fix NLB Subnet Configuration (Required for BOTH)**
```bash
# The root problem: NLB has NO SUBNETS!
# All subnets in VPC:
# - subnet-0c224506b5893a2fd (us-east-1a, 172.31.0.0/20)
# - subnet-0ca6ac2ba55ade51b (us-east-1c, 172.31.16.0/20)
# - subnet-0e6cdc5f84f4085f8 (us-east-1d, 172.31.32.0/20)
# - subnet-00220f0587b6abdc5 (us-east-1e, 172.31.48.0/20)
# - subnet-0580639a2a5c2d163 (us-east-1f, 172.31.64.0/20)
# - subnet-0f1c0059915c44410 (us-east-1b, 172.31.80.0/20)

# Solution: Add subnets to NLB (should include at least 2 AZs for HA)
aws elbv2 set-subnets \
  --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:457553343935:loadbalancer/net/broadcast-nlb-rtmp/555bec420c441233 \
  --subnets subnet-0c224506b5893a2fd subnet-0ca6ac2ba55ade51b \
  --region us-east-1

# Verify fix:
aws elbv2 describe-load-balancers \
  --load-balancer-arns arn:aws:elasticloadbalancing:us-east-1:457553343935:loadbalancer/net/broadcast-nlb-rtmp/555bec420c441233 \
  --region us-east-1 \
  --query 'LoadBalancers[0].Subnets'
```

**This is the ONLY fix needed for the NLB issue!**

**2. Choose Primary Solution**
- **Option A**: Fix Fargate network routing (3-5 hours)
- **Option B**: Fix EC2 agent registration + NLB config (2-3 hours)
- **Option C**: Both (redundancy) (5-8 hours)

### For Fargate Path

**1. Network Diagnostics**
```bash
# Step 1: Get full NLB config
aws elbv2 describe-load-balancers --names broadcast-nlb-rtmp \
  --query 'LoadBalancers[0].[Subnets,AvailabilityZones,VpcId]'

# Step 2: Check task subnets
aws ec2 describe-subnets --filters \
  "Name=vpc-id,Values=vpc-070fc6caa87f0f18d" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock]'

# Step 3: Compare - if different AZs/subnets, that's the problem
```

**2. Fix Health Checks**
```bash
# Current (broken): HTTP on port 8890
# Should be: TCP on port 8554 (RTSP is the actual service)
aws elbv2 modify-target-group \
  --target-group-arn <arn> \
  --health-check-protocol TCP \
  --health-check-port 8554
```

**3. Verify Stream Access**
```bash
# Once targets healthy:
ffplay rtsp://broadcast-nlb-rtmp-*.elb.us-east-1.amazonaws.com:8554/rpicam2
```

### For EC2 Path

**1. Verify Container Instance Registration**
```bash
# SSH to instance and check:
ssh -i racetrack-key.pem ec2-user@172.31.93.134
sudo systemctl status ecs
sudo journalctl -u ecs -n 50

# Should show:
# - ecs.service running
# - Agent connecting to cluster: broadcast-cluster
# - Instance registered as container instance
```

**2. Register Container Instances Manually** (if auto-registration failed)
```bash
# Get instance info
INSTANCE_ID=i-072746f58e85c9dda
INSTANCE_ARN=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].InstanceId')

# Register with cluster
aws ecs register-container-instance \
  --cluster broadcast-cluster \
  --instance-identity-document <json>
```

**3. Fix NLB Target Registration**
```bash
# Update service to register with NLB
aws elbv2 register-targets \
  --target-group-arn <rtsp-tg-arn> \
  --targets Id=<task-ip>,Port=8554
```

### Universal Fixes

**1. Fix MediaMTX Health Check Port**
Update in Makefile line 350:
```diff
- "curl -f http://localhost:8890/v3/info || exit 1"
+ "curl -f http://localhost:9997/ || exit 1"
```

**2. Fix Container Config Port Consistency**
Ensure `mediamtx-container.yml`:
```yaml
api: yes
apiAddress: 0.0.0.0:9997
apiEncryption: no  # Disabled to avoid cert issues
```

---

## Decision Recommendation

### **STOP and Choose Path**

Current state is **worse with EC2 because**:
- EC2 agent registration is failing silently
- Cannot SSH to debug (SSM not working)
- Service has been in FAILED state for 11+ hours
- Deployment automation is incomplete

**Recommendation**: 
1. **Pause EC2 deployment** (stop service, keep instances for now)
2. **Focus on network routing fix** (benefits BOTH solutions)
3. **Keep Fargate** - it's closer to working
4. **If Fargate works after network fix**, stick with it
5. **If network fix is too complex**, then retry EC2 with proper diagnostics

### **Quick Win**
Test if the problem is just health checks vs network routing:

```bash
# From outside AWS (your local machine):
# If this fails, it's a network routing issue:
curl -v telnet://broadcast-nlb-rtmp-*.elb.us-east-1.amazonaws.com:8554

# If this works, problem is just health check config (easy fix)
```

---

## Files That Need Changes

If proceeding with EC2:

1. **Makefile** (lines 350-365)
   - Fix health check path and port
   - Add target group registration targets
   
2. **mediamtx-container.yml**
   - Verify API is on port 9997
   - Ensure health check endpoint exists

3. **Add new Makefile targets**
   ```makefile
   mediamtx-ec2-nlb:           # Register EC2 tasks with NLB
   mediamtx-ec2-verify-agent:  # Verify ECS agent is running
   mediamtx-ec2-register-ci:   # Manually register container instances
   ```

---

## Time Estimate to Full Working State

| Path | Effort | Success Rate |
|------|--------|--------------|
| Fix Fargate (network only) | 2-4 hours | 85% (if NLB is the only issue) |
| Fix EC2 (agent + NLB) | 4-6 hours | 60% (SSM not working, harder to debug) |
| Full rebuild NLB + Fargate | 6-8 hours | 95% (nuclear option) |
| Local Docker test | 30 min | 99% (validates MediaMTX config) |

---

## Conclusion

**The EC2 solution is not a shortcut** - it has additional complexity and is currently broken. **Fargate is actually closer to working** once the underlying network issue is fixed. Both solutions are blocked by the same network routing problem that needs investigation first.
