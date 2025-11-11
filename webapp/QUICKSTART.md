# Homelab ISO Builder - Zero to Production Quickstart

Complete guide to deploy the ISO Builder webapp starting with no existing GCP resources.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [GCP Project Setup](#gcp-project-setup)
3. [Install Dependencies](#install-dependencies)
4. [Configure Application](#configure-application)
5. [Deploy to Cloud Run](#deploy-to-cloud-run)
6. [Test Deployment](#test-deployment)
7. [Monitoring & Maintenance](#monitoring--maintenance)
8. [Troubleshooting](#troubleshooting)
9. [Cost Estimates](#cost-estimates)

---

## Prerequisites

### Required Tools

Install these tools on your local machine:

1. **gcloud CLI** (Google Cloud SDK)
   ```bash
   # macOS
   brew install --cask google-cloud-sdk

   # Linux
   curl https://sdk.cloud.google.com | bash
   exec -l $SHELL

   # Windows
   # Download from: https://cloud.google.com/sdk/docs/install
   ```

2. **Git**
   ```bash
   # macOS
   brew install git

   # Linux
   sudo apt-get install git

   # Windows
   # Download from: https://git-scm.com/download/win
   ```

3. **Node.js 18+** (for local testing only, optional)
   ```bash
   # macOS
   brew install node@18

   # Linux
   curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
   sudo apt-get install -y nodejs

   # Windows
   # Download from: https://nodejs.org/
   ```

### Required Accounts

- **Google Cloud Account** with billing enabled
  - Create at: https://cloud.google.com/
  - Free tier includes $300 credit for 90 days

---

## GCP Project Setup

### Step 1: Create New GCP Project

```bash
# Set your desired project ID (must be globally unique)
export PROJECT_ID="homelab-iso-builder-$(date +%s)"
export PROJECT_NAME="Homelab ISO Builder"
export BILLING_ACCOUNT_ID="YOUR_BILLING_ACCOUNT_ID"  # Find at: console.cloud.google.com/billing

# Login to Google Cloud
gcloud auth login

# Create project
gcloud projects create $PROJECT_ID --name="$PROJECT_NAME"

# Set as active project
gcloud config set project $PROJECT_ID

# Link billing account
gcloud billing projects link $PROJECT_ID --billing-account=$BILLING_ACCOUNT_ID

# Verify project is active
gcloud config get-value project
```

**Find Your Billing Account ID:**
```bash
# List billing accounts
gcloud billing accounts list

# Output will show:
# ACCOUNT_ID            NAME                OPEN  MASTER_ACCOUNT_ID
# 01234-567890-ABCDEF   My Billing Account  True
```

### Step 2: Enable Required APIs

```bash
# Enable all required APIs in one command
gcloud services enable \
    compute.googleapis.com \
    storage.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    cloudresourcemanager.googleapis.com

# Verify APIs are enabled
gcloud services list --enabled
```

**Expected output should include:**
- Compute Engine API
- Cloud Storage API
- Cloud Build API
- Cloud Run API
- Cloud Logging API
- Cloud Monitoring API

### Step 3: Set Default Region and Zone

```bash
# Set default region (choose one close to your users)
export REGION="us-west1"
export ZONE="us-west1-a"

gcloud config set compute/region $REGION
gcloud config set compute/zone $ZONE

# Verify settings
gcloud config list
```

**Available regions:**
- `us-west1` - Oregon (low cost)
- `us-central1` - Iowa (low cost)
- `us-east1` - South Carolina (low cost)
- `europe-west1` - Belgium
- `asia-east1` - Taiwan

---

## Install Dependencies

### Step 1: Clone Repository

```bash
# Clone the repository
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script/webapp

# Verify files exist
ls -la
# Should see: backend/ frontend/ deployment/ README.md
```

### Step 2: Create GCS Buckets

```bash
# Create unique bucket names
export ARTIFACTS_BUCKET="${PROJECT_ID}-artifacts"
export DOWNLOADS_BUCKET="${PROJECT_ID}-downloads"

# Create artifacts bucket (for Docker images and models)
gsutil mb -p $PROJECT_ID -l $REGION gs://$ARTIFACTS_BUCKET

# Create downloads bucket (for generated ISOs)
gsutil mb -p $PROJECT_ID -l $REGION gs://$DOWNLOADS_BUCKET

# Set lifecycle policy to delete old ISOs after 7 days
cat > /tmp/lifecycle-policy.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {
          "age": 7
        }
      }
    ]
  }
}
EOF

gsutil lifecycle set /tmp/lifecycle-policy.json gs://$DOWNLOADS_BUCKET

# Verify buckets created
gsutil ls
```

**Expected output:**
```
gs://homelab-iso-builder-1234567890-artifacts/
gs://homelab-iso-builder-1234567890-downloads/
```

### Step 3: Set Up IAM Permissions

```bash
# Get project number
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Grant Cloud Run service account permissions to create VMs and access storage
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/compute.instanceAdmin.v1"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/storage.objectAdmin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser"

# Verify permissions
gcloud projects get-iam-policy $PROJECT_ID --flatten="bindings[].members" --filter="bindings.members:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
```

---

## Configure Application

### Step 1: Create Environment Configuration

```bash
cd backend

# Create .env file
cat > .env <<EOF
# GCP Configuration
NODE_ENV=production
GCP_PROJECT_ID=$PROJECT_ID
GCP_ZONE=$ZONE
GCP_REGION=$REGION

# GCS Buckets
GCS_ARTIFACTS_BUCKET=$ARTIFACTS_BUCKET
GCS_DOWNLOADS_BUCKET=$DOWNLOADS_BUCKET
GCS_SIGNED_URL_EXPIRATION=3600
ISO_RETENTION_DAYS=7

# VM Configuration
VM_MACHINE_TYPE=n2-standard-16
VM_BOOT_DISK_SIZE=500
VM_LOCAL_SSD_COUNT=2
MAX_CONCURRENT_BUILDS=3
BUILD_TIMEOUT_HOURS=4
VM_AUTO_CLEANUP=true

# Build Configuration
MAX_SERVICES_PER_BUILD=50
MAX_MODELS_PER_BUILD=10
MAX_ISO_SIZE_GB=150
POLL_INTERVAL_MS=10000

# Rate Limiting
RATE_LIMIT_MAX=10
BUILDS_PER_USER_PER_DAY=3

# Security
API_SECRET_KEY=$(openssl rand -hex 32)
CORS_ORIGINS=*

# Logging
LOG_LEVEL=info
LOG_FORMAT=json
EOF

# Display configuration (verify)
cat .env
```

### Step 2: Verify Configuration

```bash
# Check that all required environment variables are set
source .env

echo "Project ID: $GCP_PROJECT_ID"
echo "Artifacts Bucket: $GCS_ARTIFACTS_BUCKET"
echo "Downloads Bucket: $GCS_DOWNLOADS_BUCKET"
echo "Region: $GCP_REGION"

# All values should be displayed (not empty)
```

---

## Deploy to Cloud Run

### Option A: One-Command Deploy (Recommended)

```bash
# Navigate to webapp directory
cd ~/Homelab-Install-Script/webapp

# Deploy directly from source
gcloud run deploy iso-builder \
    --source . \
    --platform managed \
    --region $REGION \
    --allow-unauthenticated \
    --memory 2Gi \
    --cpu 2 \
    --timeout 3600 \
    --max-instances 10 \
    --set-env-vars="NODE_ENV=production,GCP_PROJECT_ID=$PROJECT_ID,GCP_ZONE=$ZONE,GCP_REGION=$REGION,GCS_ARTIFACTS_BUCKET=$ARTIFACTS_BUCKET,GCS_DOWNLOADS_BUCKET=$DOWNLOADS_BUCKET,VM_MACHINE_TYPE=n2-standard-16,VM_BOOT_DISK_SIZE=500,VM_LOCAL_SSD_COUNT=2,MAX_CONCURRENT_BUILDS=3,API_SECRET_KEY=$(openssl rand -hex 32)" \
    --service-account="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# This command will:
# 1. Build Docker image using Cloud Build
# 2. Push to Container Registry
# 3. Deploy to Cloud Run
# 4. Output the service URL
```

### Option B: Manual Deploy with Cloud Build

```bash
# Build Docker image
gcloud builds submit --tag gcr.io/$PROJECT_ID/iso-builder

# Deploy to Cloud Run
gcloud run deploy iso-builder \
    --image gcr.io/$PROJECT_ID/iso-builder \
    --platform managed \
    --region $REGION \
    --allow-unauthenticated \
    --memory 2Gi \
    --cpu 2 \
    --timeout 3600 \
    --max-instances 10 \
    --set-env-vars="NODE_ENV=production,GCP_PROJECT_ID=$PROJECT_ID,GCP_ZONE=$ZONE,GCP_REGION=$REGION,GCS_ARTIFACTS_BUCKET=$ARTIFACTS_BUCKET,GCS_DOWNLOADS_BUCKET=$DOWNLOADS_BUCKET" \
    --service-account="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
```

### Step 3: Get Service URL

```bash
# Get the deployed service URL
export SERVICE_URL=$(gcloud run services describe iso-builder --platform managed --region $REGION --format="value(status.url)")

echo "🚀 ISO Builder deployed at: $SERVICE_URL"

# Open in browser
echo "Open this URL in your browser: $SERVICE_URL"
```

**Expected output:**
```
🚀 ISO Builder deployed at: https://iso-builder-abcd1234-uc.a.run.app
```

---

## Test Deployment

### Step 1: Health Check

```bash
# Test health endpoint
curl $SERVICE_URL/health

# Expected output:
# {"status":"ok","timestamp":"2025-11-11T...","uptime":123.45,"environment":"production"}
```

### Step 2: Test API Endpoints

```bash
# Get available services
curl $SERVICE_URL/api/services | jq

# Get available models
curl $SERVICE_URL/api/models | jq

# Get configuration
curl $SERVICE_URL/api/config | jq
```

**Expected output (services):**
```json
{
  "services": [
    {
      "name": "ollama",
      "display": "Ollama (LLM Runtime)",
      "category": "ai",
      ...
    }
  ]
}
```

### Step 3: Test Web Interface

```bash
# Open web interface in browser
open $SERVICE_URL  # macOS
xdg-open $SERVICE_URL  # Linux
start $SERVICE_URL  # Windows

# Or manually visit the URL in your browser
```

**Expected result:**
- Beautiful web interface with service selection
- Step-by-step wizard
- All services and models displayed correctly

### Step 4: Test ISO Build (Optional - Costs $)

**⚠️ WARNING: This will create a VM and cost money (~$2-5)**

```bash
# Start a test build via API
curl -X POST $SERVICE_URL/api/build \
    -H "Content-Type: application/json" \
    -d '{
        "services": ["ollama", "openwebui"],
        "models": ["qwen3:8b"],
        "gpu_enabled": false,
        "iso_name": "test-iso"
    }' | jq

# Expected output:
# {
#   "build_id": "abc123-def456-...",
#   "status": "queued",
#   "estimated_time_minutes": 60
# }

# Save the build_id
export BUILD_ID="abc123-def456-..."

# Check build status (repeat every 30 seconds)
watch -n 30 "curl -s $SERVICE_URL/api/build/$BUILD_ID/status | jq"

# Once complete, get download URL
curl $SERVICE_URL/api/build/$BUILD_ID/download | jq
```

---

## Monitoring & Maintenance

### View Logs

```bash
# Stream Cloud Run logs
gcloud run services logs read iso-builder --region $REGION --limit 50

# Follow logs in real-time
gcloud run services logs tail iso-builder --region $REGION

# Filter by severity
gcloud run services logs read iso-builder --region $REGION --log-filter="severity>=ERROR"
```

### View Metrics

```bash
# Open Cloud Run metrics dashboard
echo "https://console.cloud.google.com/run/detail/$REGION/iso-builder/metrics?project=$PROJECT_ID"
```

**Key metrics to monitor:**
- Request count
- Request latency
- Container instance count
- CPU utilization
- Memory utilization

### View Active VMs

```bash
# List all ISO builder VMs
gcloud compute instances list --filter="labels.purpose=iso-builder"

# View specific VM details
gcloud compute instances describe VM_NAME --zone=$ZONE
```

### View Storage Usage

```bash
# Check artifacts bucket size
gsutil du -sh gs://$ARTIFACTS_BUCKET

# Check downloads bucket size
gsutil du -sh gs://$DOWNLOADS_BUCKET

# List ISOs in downloads bucket
gsutil ls -lh gs://$DOWNLOADS_BUCKET
```

### Set Up Budget Alerts

```bash
# Create budget alert (monthly)
gcloud billing budgets create \
    --billing-account=$BILLING_ACCOUNT_ID \
    --display-name="ISO Builder Monthly Budget" \
    --budget-amount=100USD \
    --threshold-rule=percent=50 \
    --threshold-rule=percent=90 \
    --threshold-rule=percent=100

# Verify budget created
gcloud billing budgets list --billing-account=$BILLING_ACCOUNT_ID
```

---

## Troubleshooting

### Problem: "Permission Denied" Errors

**Solution:**
```bash
# Re-grant IAM permissions
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/compute.instanceAdmin.v1"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/storage.objectAdmin"
```

### Problem: "Quota Exceeded" Error

**Solution:**
```bash
# Check quotas
gcloud compute project-info describe --project=$PROJECT_ID

# Request quota increase
echo "Request quota increase at: https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT_ID"

# Common quotas to increase:
# - CPUs (default: 24, recommended: 64)
# - N2 CPUs (default: 0, recommended: 32)
# - Local SSD (default: 375GB, recommended: 750GB)
```

### Problem: Build VM Creation Fails

**Solution:**
```bash
# Check VM creation errors
gcloud logging read "resource.type=gce_instance AND severity>=ERROR" --limit 10 --format json

# Try with smaller machine type
# Edit backend/config/config.js or set environment variable:
export VM_MACHINE_TYPE="n2-standard-8"  # Instead of n2-standard-16

# Redeploy
gcloud run services update iso-builder --set-env-vars="VM_MACHINE_TYPE=n2-standard-8"
```

### Problem: Cloud Run Deployment Fails

**Solution:**
```bash
# Check Cloud Build logs
gcloud builds list --limit 5

# Get specific build details
gcloud builds describe BUILD_ID

# Common issues:
# 1. Missing Dockerfile - Verify: ls ../deployment/Dockerfile
# 2. Missing package.json - Verify: ls backend/package.json
# 3. Node.js version mismatch - Check package.json engines field
```

### Problem: "Service Unavailable" (503) Error

**Solution:**
```bash
# Check service status
gcloud run services describe iso-builder --region $REGION

# Check recent logs for errors
gcloud run services logs read iso-builder --region $REGION --limit 20

# Common issues:
# 1. Missing environment variables
# 2. GCS bucket not accessible
# 3. Service account permissions

# Verify environment variables
gcloud run services describe iso-builder --region $REGION --format="value(spec.template.spec.containers[0].env)"
```

### Problem: High Costs

**Solution:**
```bash
# 1. Reduce concurrent builds
gcloud run services update iso-builder --set-env-vars="MAX_CONCURRENT_BUILDS=1"

# 2. Reduce VM resources
gcloud run services update iso-builder --set-env-vars="VM_MACHINE_TYPE=n2-standard-8,VM_BOOT_DISK_SIZE=250,VM_LOCAL_SSD_COUNT=0"

# 3. Enable aggressive cleanup
gcloud run services update iso-builder --set-env-vars="VM_AUTO_CLEANUP=true,ISO_RETENTION_DAYS=3"

# 4. Check for "zombie" VMs
gcloud compute instances list --filter="labels.purpose=iso-builder"

# Delete any stuck VMs
gcloud compute instances delete VM_NAME --zone=$ZONE --quiet
```

---

## Cost Estimates

### Per ISO Build

**Components:**
- VM (n2-standard-16): ~$0.80/hour × 1-2 hours = **$0.80-1.60**
- Boot disk (500GB SSD): ~$0.17/GB-month × 2 hours = **$0.005**
- Local SSD (2×375GB): ~$0.048/GB-month × 2 hours = **$0.24**
- Egress (ISO download): ~$0.12/GB × 50GB = **$6.00**
- Storage: Negligible (deleted after 7 days)

**Total per build: $7-8**

### Monthly Estimate (10 builds/month)

- VM costs: $8-16
- Cloud Run (minimal traffic): $0-5
- GCS storage (100GB cached): $2
- Egress (10 ISOs): $60
- **Total: ~$70-83/month**

### Cost Reduction Tips

1. **Use smaller VMs:**
   ```bash
   VM_MACHINE_TYPE=n2-standard-8  # Saves 50%
   ```

2. **Remove local SSDs:**
   ```bash
   VM_LOCAL_SSD_COUNT=0  # Saves $0.24/build
   ```

3. **Use preemptible VMs:**
   ```bash
   # Edit vm-manager.js, add:
   scheduling: { preemptible: true }  # Saves 80% on VM
   ```

4. **Shorter retention:**
   ```bash
   ISO_RETENTION_DAYS=3  # Instead of 7
   ```

5. **Aggressive caching:**
   - First build: $8
   - Subsequent builds: $2-3 (only VM costs, images cached)

---

## Next Steps

### 1. Customize Configuration

Edit `backend/config/config.js` to:
- Add custom services
- Modify machine types
- Adjust resource limits
- Change retention policies

### 2. Set Up Custom Domain

```bash
# Map custom domain to Cloud Run
gcloud run domain-mappings create \
    --service iso-builder \
    --domain iso-builder.yourdomain.com \
    --region $REGION

# Follow DNS configuration instructions
```

### 3. Enable Authentication (Optional)

```bash
# Require authentication
gcloud run services update iso-builder \
    --region $REGION \
    --no-allow-unauthenticated

# Grant specific users access
gcloud run services add-iam-policy-binding iso-builder \
    --region $REGION \
    --member="user:email@example.com" \
    --role="roles/run.invoker"
```

### 4. Set Up CI/CD

```bash
# Connect GitHub repository
gcloud builds triggers create github \
    --repo-name=Homelab-Install-Script \
    --repo-owner=brilliantsquirrel \
    --branch-pattern="^main$" \
    --build-config=webapp/deployment/cloudbuild.yaml
```

### 5. Monitor Usage

```bash
# Set up daily usage report
gcloud logging sinks create iso-builder-usage \
    bigquery.googleapis.com/projects/$PROJECT_ID/datasets/usage_logs \
    --log-filter='resource.type="cloud_run_revision"'
```

---

## Cleanup (Delete Everything)

If you want to delete all resources:

```bash
# Delete Cloud Run service
gcloud run services delete iso-builder --region $REGION --quiet

# Delete all ISO builder VMs
for vm in $(gcloud compute instances list --filter="labels.purpose=iso-builder" --format="value(name)"); do
    gcloud compute instances delete $vm --zone=$ZONE --quiet
done

# Delete GCS buckets
gsutil -m rm -r gs://$ARTIFACTS_BUCKET
gsutil -m rm -r gs://$DOWNLOADS_BUCKET

# Delete project (nuclear option - deletes EVERYTHING)
gcloud projects delete $PROJECT_ID
```

---

## Support

- **GitHub Issues:** https://github.com/brilliantsquirrel/Homelab-Install-Script/issues
- **Documentation:** See `webapp/README.md` and `webapp/deployment/DEPLOYMENT.md`
- **GCP Documentation:** https://cloud.google.com/run/docs

---

## Quick Reference

### Essential Commands

```bash
# View service URL
gcloud run services describe iso-builder --region $REGION --format="value(status.url)"

# View logs
gcloud run services logs tail iso-builder --region $REGION

# Update environment variable
gcloud run services update iso-builder --set-env-vars="KEY=VALUE"

# Scale to zero (pause service, no cost)
gcloud run services update iso-builder --min-instances=0

# Check costs
gcloud billing accounts list
# Visit: https://console.cloud.google.com/billing
```

### Environment Variables Quick Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `GCP_PROJECT_ID` | Your GCP project ID | (required) |
| `GCS_ARTIFACTS_BUCKET` | Docker images/models cache | (required) |
| `GCS_DOWNLOADS_BUCKET` | Generated ISOs storage | (required) |
| `VM_MACHINE_TYPE` | VM size | n2-standard-16 |
| `VM_BOOT_DISK_SIZE` | Boot disk GB | 500 |
| `VM_LOCAL_SSD_COUNT` | Number of SSDs | 2 |
| `MAX_CONCURRENT_BUILDS` | Concurrent builds | 3 |
| `BUILD_TIMEOUT_HOURS` | Build timeout | 4 |

---

**Deployment Time:** ~15-20 minutes
**First Build Time:** ~60-90 minutes
**Subsequent Builds:** ~30-45 minutes (with caching)

🎉 **You're ready to build custom homelab ISOs!**
