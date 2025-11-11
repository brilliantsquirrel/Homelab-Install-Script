# Deployment Guide for Homelab ISO Builder

This guide covers deploying the Homelab ISO Builder webapp to Google Cloud Platform.

## Prerequisites

1. **Google Cloud Project** with billing enabled
2. **gcloud CLI** installed and authenticated
3. **Required APIs enabled:**
   ```bash
   gcloud services enable compute.googleapis.com
   gcloud services enable storage.googleapis.com
   gcloud services enable cloudbuild.googleapis.com
   gcloud services enable run.googleapis.com
   ```

## Option 1: Deploy to Cloud Run (Recommended)

Cloud Run is serverless, scales automatically, and is cost-effective for variable workloads.

### Step 1: Set up GCS Buckets

```bash
# Set your project ID
export PROJECT_ID="your-project-id"
gcloud config set project $PROJECT_ID

# Create buckets
gsutil mb -p $PROJECT_ID -l us-west1 gs://homelab-iso-artifacts
gsutil mb -p $PROJECT_ID -l us-west1 gs://homelab-iso-downloads

# Set lifecycle policy to delete old ISOs
cat > lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {
          "age": 7,
          "matchesPrefix": [""]
        }
      }
    ]
  }
}
EOF

gsutil lifecycle set lifecycle.json gs://homelab-iso-downloads
```

### Step 2: Build and Deploy

```bash
# From repository root
cd webapp

# Build Docker image
gcloud builds submit --tag gcr.io/$PROJECT_ID/homelab-iso-builder

# Deploy to Cloud Run
gcloud run deploy homelab-iso-builder \
  --image gcr.io/$PROJECT_ID/homelab-iso-builder \
  --platform managed \
  --region us-west1 \
  --allow-unauthenticated \
  --memory 2Gi \
  --cpu 2 \
  --max-instances 10 \
  --set-env-vars="NODE_ENV=production,GCP_PROJECT_ID=$PROJECT_ID,GCS_ARTIFACTS_BUCKET=homelab-iso-artifacts,GCS_DOWNLOADS_BUCKET=homelab-iso-downloads"
```

### Step 3: Configure Custom Domain (Optional)

```bash
# Map custom domain
gcloud run domain-mappings create --service homelab-iso-builder \
  --domain iso-builder.yourdomain.com \
  --region us-west1
```

## Option 2: Deploy to App Engine

App Engine provides managed infrastructure with automatic scaling.

### Step 1: Set up GCS Buckets

(Same as Cloud Run Step 1)

### Step 2: Configure app.yaml

Edit `webapp/deployment/app.yaml` and update:
- `GCP_PROJECT_ID`
- `GCS_ARTIFACTS_BUCKET`
- `GCS_DOWNLOADS_BUCKET`

### Step 3: Deploy

```bash
cd webapp/backend

# Deploy to App Engine
gcloud app deploy ../deployment/app.yaml

# View logs
gcloud app logs tail -s default
```

## Option 3: Deploy to Kubernetes (GKE)

For advanced users who need more control and customization.

### Step 1: Create GKE Cluster

```bash
gcloud container clusters create iso-builder-cluster \
  --zone us-west1-a \
  --num-nodes 3 \
  --machine-type n1-standard-2 \
  --enable-autoscaling \
  --min-nodes 1 \
  --max-nodes 10
```

### Step 2: Build and Push Image

```bash
docker build -t gcr.io/$PROJECT_ID/homelab-iso-builder -f deployment/Dockerfile .
docker push gcr.io/$PROJECT_ID/homelab-iso-builder
```

### Step 3: Create Kubernetes Manifests

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iso-builder
spec:
  replicas: 3
  selector:
    matchLabels:
      app: iso-builder
  template:
    metadata:
      labels:
        app: iso-builder
    spec:
      containers:
      - name: iso-builder
        image: gcr.io/YOUR_PROJECT_ID/homelab-iso-builder:latest
        ports:
        - containerPort: 8080
        env:
        - name: NODE_ENV
          value: "production"
        - name: GCP_PROJECT_ID
          value: "YOUR_PROJECT_ID"
        - name: GCS_ARTIFACTS_BUCKET
          value: "homelab-iso-artifacts"
        - name: GCS_DOWNLOADS_BUCKET
          value: "homelab-iso-downloads"
---
apiVersion: v1
kind: Service
metadata:
  name: iso-builder-service
spec:
  type: LoadBalancer
  selector:
    app: iso-builder
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
```

Deploy:

```bash
kubectl apply -f deployment.yaml
```

## CI/CD with Cloud Build

Set up automatic deployments on code changes.

### Step 1: Connect Repository

```bash
# Connect GitHub repository
gcloud beta builds triggers create github \
  --repo-name=Homelab-Install-Script \
  --repo-owner=brilliantsquirrel \
  --branch-pattern="^main$" \
  --build-config=webapp/deployment/cloudbuild.yaml
```

### Step 2: Test Trigger

```bash
# Manual trigger test
gcloud builds submit --config=webapp/deployment/cloudbuild.yaml .
```

## Environment Variables

Configure these environment variables in your deployment:

| Variable | Required | Description | Default |
|----------|----------|-------------|---------|
| `NODE_ENV` | Yes | Environment (production/development) | production |
| `GCP_PROJECT_ID` | Yes | Your GCP project ID | - |
| `GCS_ARTIFACTS_BUCKET` | Yes | Bucket for Docker images and models | homelab-iso-artifacts |
| `GCS_DOWNLOADS_BUCKET` | Yes | Bucket for generated ISOs | homelab-iso-downloads |
| `VM_MACHINE_TYPE` | No | VM type for ISO builds | n2-standard-16 |
| `MAX_CONCURRENT_BUILDS` | No | Maximum concurrent builds | 3 |
| `BUILD_TIMEOUT_HOURS` | No | Build timeout in hours | 4 |

## Security Considerations

### 1. IAM Permissions

The service account needs these permissions:

```bash
# Grant permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT_EMAIL" \
  --role="roles/compute.instanceAdmin.v1"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT_EMAIL" \
  --role="roles/storage.objectAdmin"
```

### 2. Rate Limiting

Configure rate limiting in your Cloud Load Balancer or use Cloud Armor.

### 3. Authentication (Optional)

Add authentication using Cloud IAP:

```bash
gcloud iap web enable --resource-type=backend-services \
  --service=homelab-iso-builder
```

## Monitoring and Logging

### View Logs

```bash
# Cloud Run logs
gcloud run services logs read homelab-iso-builder --region us-west1

# App Engine logs
gcloud app logs tail -s default

# Cloud Build logs
gcloud builds log --stream
```

### Set up Monitoring

```bash
# Create uptime check
gcloud monitoring uptime-checks create https iso-builder-check \
  --resource-type=uptime-url \
  --resource-url=https://YOUR_SERVICE_URL/health

# Create alerting policy
gcloud alpha monitoring policies create \
  --notification-channels=CHANNEL_ID \
  --display-name="ISO Builder Health" \
  --condition-threshold-value=1 \
  --condition-threshold-duration=60s
```

## Cost Optimization

### 1. Set Budget Alerts

```bash
gcloud billing budgets create --billing-account=BILLING_ACCOUNT_ID \
  --display-name="ISO Builder Budget" \
  --budget-amount=100USD \
  --threshold-rule=percent=50 \
  --threshold-rule=percent=90
```

### 2. Preemptible VMs for Builds

Update VM configuration to use preemptible instances for cost savings:

```javascript
// In vm-manager.js
scheduling: {
  preemptible: true,
  automaticRestart: false,
}
```

### 3. Lifecycle Policies

Ensure lifecycle policies are set on buckets to auto-delete old files.

## Troubleshooting

### Issue: VM Creation Fails

**Solution:** Check quota limits:
```bash
gcloud compute project-info describe --project=$PROJECT_ID
```

Increase quotas if needed in GCP Console.

### Issue: Build Timeout

**Solution:** Increase build timeout:
```bash
# Update environment variable
gcloud run services update homelab-iso-builder \
  --set-env-vars=BUILD_TIMEOUT_HOURS=6
```

### Issue: Out of Disk Space

**Solution:** Increase VM boot disk size:
```bash
# Update environment variable
gcloud run services update homelab-iso-builder \
  --set-env-vars=VM_BOOT_DISK_SIZE=1000
```

## Scaling

### Horizontal Scaling

Cloud Run automatically scales based on load. Configure:

```bash
gcloud run services update homelab-iso-builder \
  --min-instances=1 \
  --max-instances=20 \
  --concurrency=10
```

### Vertical Scaling

Increase resources:

```bash
gcloud run services update homelab-iso-builder \
  --memory=4Gi \
  --cpu=4
```

## Maintenance

### Update Deployment

```bash
# Build new image
gcloud builds submit --tag gcr.io/$PROJECT_ID/homelab-iso-builder:v2

# Deploy new version
gcloud run deploy homelab-iso-builder \
  --image gcr.io/$PROJECT_ID/homelab-iso-builder:v2 \
  --region us-west1
```

### Rollback

```bash
# List revisions
gcloud run revisions list --service=homelab-iso-builder

# Rollback to previous revision
gcloud run services update-traffic homelab-iso-builder \
  --to-revisions=REVISION_NAME=100
```

## Support

For issues and questions:
- GitHub Issues: https://github.com/brilliantsquirrel/Homelab-Install-Script/issues
- Documentation: https://docs.claude.com
