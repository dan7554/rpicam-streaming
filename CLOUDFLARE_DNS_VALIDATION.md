# Cloudflare DNS Validation for ACM Certificate

## Current ACM Certificate Status

**ARN**: `arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53`

**Status**: PENDING_VALIDATION

**Domains**: 
- racetrackstreaming.com
- *.racetrackstreaming.com
- admin.racetrackstreaming.com
- stream.racetrackstreaming.com

---

## DNS Records to Add to Cloudflare

You need to add **4 CNAME records** to your Cloudflare DNS. These are for AWS ACM certificate validation only - they validate that you own the domain.

### Record 1: Root Domain Validation

| Field | Value |
|-------|-------|
| **Type** | CNAME |
| **Name** | `_ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com` |
| **Target/Value** | `_1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.` |
| **TTL** | Auto (or 300) |
| **Proxy Status** | ⚪ DNS only (not proxied through Cloudflare) |

**Note**: The trailing dot (`.`) at the end is important!

### Record 2: Wildcard Domain Validation

| Field | Value |
|-------|-------|
| **Type** | CNAME |
| **Name** | `_ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com` |
| **Target/Value** | `_1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.` |
| **TTL** | Auto (or 300) |
| **Proxy Status** | ⚪ DNS only |

**Note**: This is the SAME as Record 1 (AWS ACM optimizes validation by reusing records)

### Record 3: admin.racetrackstreaming.com Validation

| Field | Value |
|-------|-------|
| **Type** | CNAME |
| **Name** | `_29e1c2eb3de2b5e37c8bd0cd70302e19.admin.racetrackstreaming.com` |
| **Target/Value** | `_c919a803146ad586ee9464f3e8fe71bd.jkddzztszm.acm-validations.aws.` |
| **TTL** | Auto (or 300) |
| **Proxy Status** | ⚪ DNS only |

### Record 4: stream.racetrackstreaming.com Validation

| Field | Value |
|-------|-------|
| **Type** | CNAME |
| **Name** | `_18e93352c495c4b298efaeea25142c3e.stream.racetrackstreaming.com` |
| **Target/Value** | `_0d80a5b757dd3cba67709dff4e088cae.jkddzztszm.acm-validations.aws.` |
| **TTL** | Auto (or 300) |
| **Proxy Status** | ⚪ DNS only |

---

## Step-by-Step: Adding Records to Cloudflare

### 1. Log in to Cloudflare

- Go to https://dash.cloudflare.com
- Select your domain: **racetrackstreaming.com**

### 2. Go to DNS Records

- Click **DNS** in the left sidebar
- You should see your existing records (admin.racetrackstreaming.com, stream.racetrackstreaming.com CNAMEs, etc.)

### 3. Add First Validation Record

Click **+ Add record**:

- **Type**: CNAME
- **Name**: `_ca8e511f6f3969287627790e3d988fa4` (Cloudflare will auto-append `.racetrackstreaming.com`)
- **Target**: `_1c889324b4501bca95b55ffb2c2387c0.jkddzztszm.acm-validations.aws.`
- **TTL**: Auto
- **Proxy Status**: ⚪ DNS only (gray cloud)
- Click **Save**

### 4. Add Second Validation Record (admin subdomain)

Click **+ Add record**:

- **Type**: CNAME
- **Name**: `_29e1c2eb3de2b5e37c8bd0cd70302e19.admin` (Cloudflare will auto-append `.racetrackstreaming.com`)
- **Target**: `_c919a803146ad586ee9464f3e8fe71bd.jkddzztszm.acm-validations.aws.`
- **TTL**: Auto
- **Proxy Status**: ⚪ DNS only (gray cloud)
- Click **Save**

### 5. Add Third Validation Record (stream subdomain)

Click **+ Add record**:

- **Type**: CNAME
- **Name**: `_18e93352c495c4b298efaeea25142c3e.stream` (Cloudflare will auto-append `.racetrackstreaming.com`)
- **Target**: `_0d80a5b757dd3cba67709dff4e088cae.jkddzztszm.acm-validations.aws.`
- **TTL**: Auto
- **Proxy Status**: ⚪ DNS only (gray cloud)
- Click **Save**

### 6. Verify Records Are Added

You should now have these new records in your DNS list:
- `_ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com` → AWS validation
- `_29e1c2eb3de2b5e37c8bd0cd70302e19.admin.racetrackstreaming.com` → AWS validation
- `_18e93352c495c4b298efaeea25142c3e.stream.racetrackstreaming.com` → AWS validation

---

## Wait for Validation

AWS ACM will automatically check these DNS records. Validation typically takes:

- **First 5 minutes**: DNS propagation to AWS nameservers
- **Next 5-10 minutes**: AWS ACM checks and validates
- **Total time**: 5-15 minutes usually

### Monitor Validation Status

Run this command to check the certificate status:

```bash
make ssl-check
```

Look for:
```
"Status": "ISSUED"  ← When you see this, you're done!
```

OR via AWS CLI:

```bash
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:457553343935:certificate/0c30493b-0262-455a-9773-2d077be5db53 \
  --region us-east-1 \
  --query 'Certificate.Status'
```

---

## After Validation Complete

Once AWS ACM shows `Status: ISSUED`, you can:

1. **Create HTTPS Listener on ALB**:
   ```bash
   make ssl-create-https-listener
   ```

2. **Redirect HTTP → HTTPS**:
   ```bash
   make ssl-update-alb
   ```

3. **Test HTTPS**:
   ```bash
   curl -v https://admin.racetrackstreaming.com/health
   curl -v https://stream.racetrackstreaming.com/health
   ```

---

## Important Notes

### Proxy Status: DNS Only

These validation records **MUST** be set to **DNS only** (gray cloud ⚪), NOT proxied through Cloudflare (orange cloud 🟠).

- **DNS only** (⚪): AWS can resolve the record directly from Cloudflare's nameservers
- **Proxied** (🟠): Cloudflare acts as proxy and AWS validation fails

### Existing DNS Records

You should also have these existing records for your actual services:

| Name | Type | Target | Proxy |
|------|------|--------|-------|
| `admin.racetrackstreaming.com` | CNAME | `broadcast-alb-525661146.us-east-1.elb.amazonaws.com` | 🟠 (proxied) |
| `stream.racetrackstreaming.com` | CNAME | `broadcast-alb-525661146.us-east-1.elb.amazonaws.com` | 🟠 (proxied) |

These are for your actual traffic. The validation records (starting with `_`) are separate.

### TTL Settings

For validation records, use:
- **Auto TTL** (recommended, typically 300 seconds)
- Or manually set to **300** or **3600** seconds

Don't use very long TTLs (like 24 hours) for validation records.

---

## Troubleshooting

### Certificate Still Pending After 30 Minutes

**Check 1: Are DNS records visible?**

```bash
# Check if the validation record resolves
nslookup _ca8e511f6f3969287627790e3d988fa4.racetrackstreaming.com
```

Should show AWS nameservers in response.

**Check 2: Is the proxy status correct?**

- Go to Cloudflare DNS
- Click each validation record
- Confirm the cloud icon is **gray** (⚪ DNS only), not **orange** (🟠 Proxied)

**Check 3: Check for typos**

- Verify exact spelling of names and targets
- Pay attention to hyphens, underscores, and dots
- The trailing dot (`.`) in the target is required

**Solution**: If records look wrong:
1. Delete the validation records from Cloudflare
2. Run `make ssl-request-cert` to get new validation records
3. Re-add them with correct values

### AWS ACM Validation Stuck

**Issue**: Records added but AWS still shows PENDING_VALIDATION after 20+ minutes

**Possible causes**:
1. Cloudflare not your authoritative nameserver
2. DNS propagation delay (retry after 30 minutes)
3. Typo in validation record values

**Solution**:
1. Verify Cloudflare is your domain's nameserver:
   ```bash
   whois racetrackstreaming.com | grep -i nameserver
   ```
   Should show Cloudflare nameservers (e.g., `ns1.cloudflare.com`)

2. If not, update domain registrar to use Cloudflare nameservers

3. Wait 48 hours for DNS propagation, then retry certificate request

---

## Next Steps

1. ✅ ACM certificate requested
2. 📝 **YOU ARE HERE**: Add validation records to Cloudflare DNS
3. ⏳ Wait 5-15 minutes for validation
4. 🔐 Create HTTPS listener: `make ssl-create-https-listener`
5. 🔄 Redirect HTTP → HTTPS: `make ssl-update-alb`
6. ✅ Test: `curl -v https://admin.racetrackstreaming.com`

