# IMMEDIATE FIX: Rate Limit Error

You're getting rate limited because the deployed service still has the old 10 requests/15min limit.

## ⚡ Quickest Fix (30 seconds)

Run this command from your local machine where gcloud is installed:

```bash
# Option 1: Auto-detect region
cd /home/user/Homelab-Install-Script/webapp
./fix-rate-limit-now.sh

# Option 2: Manual (replace us-west1 with your region)
gcloud run services update iso-builder \
  --region us-west1 \
  --set-env-vars RATE_LIMIT_MAX=100
```

This immediately increases your rate limit from 10 to 100 requests per 15 minutes.

---

## 📋 Manual Steps (if you don't have the repo locally)

### Step 1: Find your service

```bash
gcloud run services list
```

Look for a service named `iso-builder` and note its **REGION**.

### Step 2: Update the rate limit

```bash
# Replace REGION with the region from step 1 (e.g., us-west1)
gcloud run services update iso-builder \
  --region REGION \
  --set-env-vars RATE_LIMIT_MAX=100
```

### Step 3: Verify

```bash
# Get your service URL
gcloud run services describe iso-builder \
  --region REGION \
  --format="value(status.url)"

# Test it (replace URL with output from above)
curl -I https://YOUR-SERVICE-URL/api/services
```

Look for these headers in the response:
```
RateLimit-Limit: 100
RateLimit-Remaining: 99
```

---

## 🚀 Deploy Full Fix (5-10 minutes)

To deploy all the improvements (better IP tracking, error messages, etc.):

```bash
cd /home/user/Homelab-Install-Script/webapp
./deploy.sh
```

This will:
- Build the new Docker image with all fixes
- Deploy to Cloud Run
- Configure environment variables
- Test the deployment

---

## ⏰ Wait It Out (15 minutes)

The rate limit resets every 15 minutes. You can simply wait and try again.

---

## 🔍 Troubleshooting

### Can't find gcloud command?

Install Google Cloud SDK:
```bash
# macOS
brew install google-cloud-sdk

# Linux
curl https://sdk.cloud.google.com | bash
exec -l $SHELL

# Windows
# Download from https://cloud.google.com/sdk/docs/install
```

### Service not found?

List all services:
```bash
gcloud run services list --platform managed
```

If your service has a different name, replace `iso-builder` with the actual name.

### Don't know your region?

Try these common regions:
- `us-west1` (Oregon)
- `us-central1` (Iowa)
- `us-east1` (South Carolina)
- `europe-west1` (Belgium)

Or check all:
```bash
for region in us-west1 us-central1 us-east1 europe-west1; do
  echo "Checking $region..."
  gcloud run services describe iso-builder --region $region 2>/dev/null && echo "Found in $region!"
done
```

### Still getting rate limited after update?

1. **Wait 2-3 minutes** for Cloud Run to deploy the new revision
2. **Clear browser cache** or try in incognito mode
3. **Check if update was applied:**
   ```bash
   gcloud run services describe iso-builder \
     --region REGION \
     --format="value(spec.template.spec.containers[0].env)"
   ```
   Should show `RATE_LIMIT_MAX=100`

4. **Force new revision:**
   ```bash
   gcloud run services update iso-builder \
     --region REGION \
     --no-traffic

   gcloud run services update iso-builder \
     --region REGION \
     --to-latest
   ```

---

## 📊 What Was Fixed

The committed changes (already in git):
- ✅ Increased rate limit: 10 → 100 (dev) or 30 (prod)
- ✅ Better IP tracking with custom keyGenerator
- ✅ Development bypass header support
- ✅ Improved error messages with retry info
- ✅ Health check endpoint exempt from rate limiting

**These are committed but need to be deployed to take effect!**
