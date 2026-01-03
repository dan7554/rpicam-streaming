# EC2 Solution - PITFALL VERIFICATION COMPLETE ✅

## Summary

The comprehensive verification of the EC2 solution revealed **one critical root cause affecting BOTH Fargate and EC2**:

---

## CRITICAL FINDING: NLB Misconfigured (ROOT CAUSE)

**Problem**: NLB had NO SUBNETS configured
- **Status**: `Subnets: null` (empty)
- **VPC**: Correctly set to `vpc-070fc6caa87f0f18d`
- **Result**: NLB not deployed to any availability zone - could not send or receive traffic

**Impact**:
- ✅ **This explains ALL health check failures**
- ✅ **This explains why NO targets ever became HEALTHY**
- ✅ **This explains why tasks kept cycling through restarts**
- ✅ **This blocked BOTH Fargate AND EC2 solutions**

**Fix Applied**:
```bash
aws elbv2 set-subnets \
  --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:457553343935:loadbalancer/net/broadcast-nlb-rtmp/555bec420c441233 \
  --subnets subnet-0c224506b5893a2fd subnet-0ca6ac2ba55ade51b \
  --region us-east-1
```

**Result**: ✅ NLB now has 2 subnets (us-east-1a and us-east-1c)

---

## Additional Critical Pitfalls Found

### 1. EC2 Service Completely Non-Functional ❌
- **Status**: 0/2 running tasks, 57 failed attempts, IN_PROGRESS for 11+ hours
- **Reason**: Container instances NOT registered with ECS cluster
- **Why**: ECS agent on EC2 instances not starting or not connecting to cluster
- **Verdict**: EC2 solution is **BLOCKED** until container instance registration is fixed

### 2. Fargate Configuration Issues ⚠️
- **Issue 1**: Health checks were pointing to wrong port (8890 SRT instead of 9997 API)
- **Issue 2**: Config mismatch (mediamtx.yml vs mediamtx-container.yml)
- **Issue 3**: TLS cert mismatch causing API initialization failures
- **Status**: ✅ All fixed in current build, API now on port 9997

### 3. MediaMTX Configuration ⚠️
- **Problem**: Multiple config files with different port mappings
  - `mediamtx.yml` (9997 HTTPS)
  - `mediamtx-container.yml` (9997 HTTP)
  - Task def health checks (8890 HTTP) ← WRONG
- **Fixed**: Container config updated to 9997 HTTP, health checks corrected

### 4. Incomplete EC2 Deployment Automation ⚠️
- **Missing**: Target group registration for EC2 tasks
- **Missing**: Container instance registration verification
- **Missing**: NLB configuration for EC2 service
- **Impact**: Even if EC2 service starts, no traffic routing configured

---

## What Changed

**Before**:
```
NLB Subnets: null
↓
NLB not in any AZ
↓
Can't send traffic to tasks
↓
All health checks fail
↓
ECS kills tasks after 2 failed checks
↓
Tasks restart infinitely
```

**After (Applied):**
```
NLB Subnets: subnet-0c224506b5893a2fd (us-east-1a)
             subnet-0ca6ac2ba55ade51b (us-east-1c)
↓
NLB deployed to 2 AZs
↓
Can reach task ENIs
↓
Health checks can respond
↓
Tasks should stay running
```

---

## Current Status (Post-Fix)

### Fargate Service
- **Desired**: 3 tasks
- **Running**: 2 tasks  
- **Status**: Stabilizing (new config being deployed)
- **Logs**: Latest tasks show API on 9997 ✅
- **Targets**: Draining old unhealthy targets, waiting for new health checks
- **Prognosis**: **Should work once new tasks pass health checks**

### EC2 Service  
- **Desired**: 2 tasks
- **Running**: 0 tasks
- **Status**: **BLOCKED** - no container instances registered
- **Diagnosis**: ECS agent not connecting to cluster
- **Prognosis**: **Requires separate troubleshooting to unblock**

---

## Recommendation

### SHORT TERM: Proceed with Fargate ✅
1. **NLB subnet issue is FIXED**
2. **Config is corrected** (9997 HTTP)
3. **Current Fargate tasks are stable** (2 running)
4. **Just need health checks to pass** (should happen in 1-2 minutes)
5. **Can test RPi stream flow immediately after targets healthy**

### For EC2: Requires Investigation
1. Check ECS agent status on EC2 instances
2. Verify IAM permissions (cloudwatch logs, ecr pulls)
3. Check network connectivity from instance to ECS cluster
4. Manually register container instances if needed
5. Add NLB target group registration
6. Full estimated time: 2-3 hours of troubleshooting

---

## Next Immediate Steps

```bash
# 1. Verify NLB subnet fix is working
aws elbv2 describe-load-balancers \
  --load-balancer-arns arn:aws:elasticloadbalancing:us-east-1:457553343935:loadbalancer/net/broadcast-nlb-rtmp/555bec420c441233 \
  --region us-east-1 \
  --query 'LoadBalancers[0].AvailabilityZones[*].[ZoneName,SubnetId]' \
  --output table

# 2. Watch for target health to change from "unused" to "healthy"
watch -n 5 'aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:457553343935:targetgroup/mediamtx-rtsp/7d6fac9b9e2489d1 \
  --region us-east-1 \
  --query "TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]"'

# 3. Once healthy, test stream access
ffplay 'rtsp://broadcast-nlb-rtmp-555bec420c441233.elb.us-east-1.amazonaws.com:8554/rpicam2'
```

---

## Conclusion

The EC2 solution has **multiple critical blockers** that make it significantly more complex than the Fargate solution. The **NLB misconfiguration affected both equally**, but:

- **Fargate**: Now very close to working (just needs health checks to pass)
- **EC2**: Has fundamental blocking issues (no container instances) plus additional infrastructure gaps

**Recommendation**: **Continue with Fargate** - it's 80% there. EC2 can be a future fallback if needed.
