# Rate Limit Fix

## Problem
The rate limiter was configured too restrictively (10 requests per 15 minutes), causing "Too many requests" errors during normal usage and testing.

## Changes Made

### 1. Environment-Based Rate Limits (config/config.js)
- **Development**: 100 requests per 15 minutes (was 10)
- **Production**: 30 requests per 15 minutes (was 10)
- Configurable via `RATE_LIMIT_MAX` environment variable

### 2. Improved IP Tracking (server.js)
- Added custom `keyGenerator` to ensure proper client IP tracking
- Added debug logging for IP identification
- Better handling of proxy headers (X-Forwarded-For, X-Real-IP)

### 3. Development Bypass (server.js)
- Added `skip` function to bypass rate limiting in development
- Use header `X-Bypass-Rate-Limit: true` to bypass (development only)
- Health checks always skip rate limiting

### 4. Better Error Messages (server.js)
- Rate limit responses now include `maxRequests` and `windowMinutes`
- More detailed logging with IP, path, and timing information

## Deployment

### Option 1: Quick Redeploy
```bash
cd /home/user/Homelab-Install-Script/webapp
./deploy.sh
```

### Option 2: Manual Cloud Run Deployment
```bash
cd /home/user/Homelab-Install-Script/webapp

# Build and deploy
gcloud builds submit --tag gcr.io/$(gcloud config get-value project)/iso-builder
gcloud run deploy iso-builder \
  --image gcr.io/$(gcloud config get-value project)/iso-builder \
  --region us-west1 \
  --platform managed \
  --allow-unauthenticated \
  --set-env-vars NODE_ENV=production,RATE_LIMIT_MAX=30
```

### Option 3: Set Higher Rate Limit Without Redeploying
```bash
# Update environment variables on Cloud Run
gcloud run services update iso-builder \
  --region us-west1 \
  --set-env-vars RATE_LIMIT_MAX=100
```

## Testing the Fix

### Wait for Rate Limit to Reset
The rate limit window is 15 minutes. Wait 15 minutes and try again, or:

```bash
# Restart the Cloud Run service to clear rate limit memory
gcloud run services update iso-builder \
  --region us-west1 \
  --no-traffic
gcloud run services update iso-builder \
  --region us-west1 \
  --to-latest
```

### Check Current Rate Limit (After Deploying)
```bash
# Make a test request and check headers
curl -I https://YOUR_CLOUD_RUN_URL/api/services

# Look for these headers:
# RateLimit-Limit: 100 (or 30 in production)
# RateLimit-Remaining: 99
# RateLimit-Reset: <timestamp>
```

### View Rate Limit Logs
```bash
# Check if rate limiting is working correctly
gcloud run services logs read iso-builder \
  --region us-west1 \
  --filter="Rate limit" \
  --limit 50
```

## Immediate Workaround

If you need immediate access before deploying:

1. **Wait 15 minutes** - The rate limit window will reset
2. **Use a different IP** - Try from a different network/device
3. **Use VPN** - Change your IP address temporarily

## Recommended Production Settings

After deploying, update your Cloud Run service with these environment variables:

```bash
gcloud run services update iso-builder \
  --region us-west1 \
  --set-env-vars \
    NODE_ENV=production,\
    RATE_LIMIT_MAX=50,\
    BUILDS_PER_USER_PER_DAY=5
```

This provides a good balance:
- **50 requests per 15 minutes** - Allows normal browsing and API usage
- **5 builds per day** - Prevents abuse while allowing testing
