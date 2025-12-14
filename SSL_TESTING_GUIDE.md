# SSL/TLS Testing Guide

## Overview

After your ACM certificate is validated and HTTPS listener is created, use these commands to verify everything is working correctly.

---

## Phase 1: Verify Certificate Status

### Command 1: Check ACM Certificate Status

```bash
make ssl-check
```

**Expected Output:**
```
🔍 Checking ACM certificate status...
{
  "Status": "ISSUED",  ← Must be "ISSUED", not "PENDING_VALIDATION"
  "DomainName": "racetrackstreaming.com",
  "SubjectAlternativeNames": [
    "racetrackstreaming.com",
    "*.racetrackstreaming.com",
    "admin.racetrackstreaming.com",
    "stream.racetrackstreaming.com"
  ]
}

🔗 ALB Listeners:
┌─────────┬──────────────┐
│  Port   │  Protocol    │
├─────────┼──────────────┤
│   80    │  HTTP        │
│   443   │  HTTPS       │  ← Should see this after ssl-create-https-listener
└─────────┴──────────────┘
```

---

## Phase 2: Test HTTPS Endpoints

### Command 2: Test Admin Dashboard Health Check

```bash
curl -v https://admin.racetrackstreaming.com/health
```

**Expected Output:**
```
*   Trying 1.2.3.4:443...
* Connected to admin.racetrackstreaming.com (1.2.3.4) port 443 (#0)
* ALPN, offering h2
* ALPN, offering http/1.1
* Server certificate:
*  subject: CN=racetrackstreaming.com  ← Valid AWS ACM certificate
*  issuer: C=US; O=Amazon; OU=Amazon Web Services; CN=Amazon RSA 2048 M03
*  expire date: Dec 14 2026 23:59:59 GMT
*  verify ok.                            ← Certificate verified
...
> GET /health HTTP/1.1
< HTTP/1.1 200 OK
< healthy                                ← Response from Nginx

```

### Command 3: Test Stream Subdomain Health Check

```bash
curl -v https://stream.racetrackstreaming.com/health
```

**Expected Output:**
```
...
> GET /health HTTP/1.1
< HTTP/1.1 200 OK
< OK                                    ← Response from Nginx

```

---

## Phase 3: Verify SSL Certificate Chain

### Command 4: Check Certificate Details

```bash
openssl s_client -connect admin.racetrackstreaming.com:443 \
  -servername admin.racetrackstreaming.com
```

**Expected Output (look for these lines):**

```
CONNECTED(00000003)
depth=2 O=Amazon, OU=Amazon Web Services, CN=Amazon RSA 2048 M03
depth=1 C=US, O=Amazon, CN=Amazon RSA 2048 M03 TLS CA 01
depth=0 CN=racetrackstreaming.com

verify ok.  ← Certificate chain valid

subject=CN=racetrackstreaming.com

issuer=C=US, O=Amazon, CN=Amazon RSA 2048 M03 TLS CA 01

subject_alt_name=*.racetrackstreaming.com,admin.racetrackstreaming.com,racetrackstreaming.com,stream.racetrackstreaming.com

X509v3 Key Usage:
    Digital Signature

Not Before: Dec 14 2024 00:00:00 GMT
Not After : Dec 14 2025 23:59:59 GMT  ← Certificate expiration date
```

### Command 5: Extract Certificate Info

```bash
echo | openssl s_client -connect admin.racetrackstreaming.com:443 \
  -servername admin.racetrackstreaming.com 2>/dev/null | \
  openssl x509 -noout -text | grep -A 2 "Subject Alternative Name"
```

**Expected Output:**
```
X509v3 Subject Alternative Name: 
    DNS:*.racetrackstreaming.com, DNS:admin.racetrackstreaming.com, 
    DNS:racetrackstreaming.com, DNS:stream.racetrackstreaming.com
```

### Command 6: Check Certificate Expiration

```bash
echo | openssl s_client -connect admin.racetrackstreaming.com:443 \
  -servername admin.racetrackstreaming.com 2>/dev/null | \
  openssl x509 -noout -dates
```

**Expected Output:**
```
notBefore=Dec 14 00:00:00 2024 GMT
notAfter=Dec 14 23:59:59 2025 GMT
```

---

## Phase 4: Test HTTP → HTTPS Redirect

### Command 7: Verify HTTP Redirect to HTTPS

```bash
curl -v http://admin.racetrackstreaming.com/health
```

**Expected Output:**
```
...
> GET /health HTTP/1.1
< HTTP/1.1 301 Moved Permanently  ← 301 redirect
< Location: https://admin.racetrackstreaming.com/health

< 
* Closing connection 0
```

### Command 8: Follow Redirect and Get HTTPS Response

```bash
curl -L http://admin.racetrackstreaming.com/health
```

**Expected Output:**
```
healthy  ← Final response after redirect to HTTPS
```

---

## Phase 5: Test Application Endpoints

### Command 9: Test Express API Endpoint

```bash
curl -v https://admin.racetrackstreaming.com/api/health
```

**Expected Output:**
```
HTTP/1.1 200 OK
Content-Type: application/json

{"status":"healthy"}  ← Response from Express.js backend
```

### Command 10: Test HLS Endpoint

```bash
curl -v https://stream.racetrackstreaming.com/hls/
```

**Expected Output:**
```
HTTP/1.1 200 OK
Content-Type: text/html

<html>
<head><title>Index of /</title></head>
<body>
...  ← Directory listing from MediaMTX HLS server
```

### Command 11: Test Specific HLS Stream

```bash
curl -v https://stream.racetrackstreaming.com/hls/camera1/index.m3u8
```

**Expected Output (if stream exists):**
```
HTTP/1.1 200 OK
Content-Type: application/vnd.apple.mpegurl

#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
segment0.ts
...  ← HLS playlist from MediaMTX
```

---

## Phase 6: Browser Testing

### Command 12: Test in Browser

Visit these URLs in your browser:

1. **Admin Dashboard**: https://admin.racetrackstreaming.com
   - Should load Broadcast system dashboard
   - Browser should show ✅ valid certificate (green lock)

2. **Stream URL**: https://stream.racetrackstreaming.com/hls/
   - Should show HLS stream directory
   - Certificate should be valid

### Expected Browser Certificate Details:

Click the lock icon in browser address bar:

```
✓ Connection is secure
✓ Certificate is valid

Issued by: Amazon RSA 2048 M03 TLS CA 01
Valid from: 14 Dec 2024 to 14 Dec 2025

Subject: racetrackstreaming.com
SANs: *.racetrackstreaming.com, admin.racetrackstreaming.com, 
      racetrackstreaming.com, stream.racetrackstreaming.com
```

---

## Phase 7: Monitor Logs

### Command 13: Check ECS Logs

```bash
make logs
```

**Expected Output:**
- Both services showing startup messages
- No errors related to SSL/TLS
- MediaMTX service discovery DNS working
- Nginx SSL configured and running

### Command 14: Tail Live Logs

```bash
# MediaMTX logs
aws logs tail /ecs/mediamtx --follow --since 5m --region us-east-1

# Broadcast logs
aws logs tail /ecs/broadcast --follow --since 5m --region us-east-1
```

**Look for:**
- HTTP/2 upgrade notices
- SSL/TLS negotiation logs
- No certificate validation errors

---

## Troubleshooting Tests

### If Certificate Chain is Invalid

```bash
# Check if Cloudflare is proxying correctly
curl -vI https://admin.racetrackstreaming.com/ | grep -i "server\|x-served-by\|cf-ray"

# Should see Cloudflare headers:
# Server: cloudflare
# cf-ray: ...
# x-served-by: cache-...
```

### If HTTPS Returns 502 Bad Gateway

```bash
# Check target group health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names broadcast-targets --region us-east-1 \
    --query 'TargetGroups[0].TargetGroupArn' --output text) \
  --region us-east-1

# Should show: "State": "healthy"
```

### If Certificate Expired

```bash
# Check certificate status
make ssl-check

# If expired, AWS automatically renews but might take time
# Can manually request new certificate with:
make ssl-request-cert
```

### If Mixed Content Warnings

```bash
# Browser console will show errors
# Check that all resources use HTTPS or relative URLs

# Test with curl -v to see response headers
curl -v https://admin.racetrackstreaming.com | grep -i "http://"

# Should NOT return any http:// URLs (except in comments)
```

---

## Performance Tests (Optional)

### Command 15: Test HTTPS Performance

```bash
# Measure HTTPS handshake time
time curl -o /dev/null -s https://admin.racetrackstreaming.com/health

# Should complete in <500ms (typically 100-300ms)
```

### Command 16: Test from Multiple Locations

```bash
# Simulate different geographic locations by testing DNS resolution
nslookup admin.racetrackstreaming.com

# Should resolve to Cloudflare Anycast IP
# Try from different networks to ensure Cloudflare is cached properly
```

---

## Test Summary Checklist

- [ ] ACM Certificate status is **ISSUED**
- [ ] ALB has both port 80 and 443 listeners
- [ ] HTTPS request to admin domain returns 200 with valid certificate
- [ ] HTTPS request to stream domain returns 200 with valid certificate
- [ ] HTTP requests redirect to HTTPS (301)
- [ ] Certificate Subject Alternative Names include all domains
- [ ] Express API endpoints respond over HTTPS
- [ ] MediaMTX HLS streams accessible over HTTPS
- [ ] Browser shows valid certificate (green lock)
- [ ] No mixed content warnings in browser console
- [ ] ECS logs show no SSL/TLS errors
- [ ] Target group health is "healthy"

---

## Common Issues & Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| CERTIFICATE_VERIFY_FAILED | Certificate not trusted locally | Use `-k` flag with curl to skip verification (testing only) |
| 502 Bad Gateway | ECS task not healthy | Check `make status`, restart service with `make broadcast-update` |
| HTTPS returns self-signed cert | Nginx cert instead of ALB cert | Verify ALB listener has ACM certificate |
| Mixed content warning | Resources loading over HTTP | Update links to HTTPS or relative URLs |
| Certificate expired | Old certificate still in use | Request new cert: `make ssl-request-cert` |
| DNS not resolving | Cloudflare records not propagated | Wait 24-48 hours, verify DNS with `nslookup` |

---

## Next: Monitor Certificate Auto-Renewal

AWS ACM automatically renews certificates 60 days before expiration. No action needed. AWS will send email notifications if renewal is delayed.

To verify auto-renewal is enabled:

```bash
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53 \
  --region us-east-1 \
  --query 'Certificate.RenewalEligibility'
```

**Expected Output:**
```
ELIGIBLE
```

---

## Additional Resources

- [AWS ACM Documentation](https://docs.aws.amazon.com/acm/)
- [Cloudflare SSL/TLS Guide](https://developers.cloudflare.com/ssl/)
- [OpenSSL s_client Reference](https://www.openssl.org/docs/manmaster/man1/openssl-s_client.html)
- [cURL SSL Troubleshooting](https://curl.se/docs/sslcerts.html)

