#!/bin/bash

# Quick redeploy script for existing Cloud Run service
set -e

PROJECT_ID="cloud-ai-server"
REGION="us-west1"
IMAGE_URL="gcr.io/$PROJECT_ID/iso-builder"

echo "========================================="
echo "Quick Redeploy to Cloud Run"
echo "========================================="
echo ""
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Image: $IMAGE_URL"
echo ""

# Stay in webapp directory for build
cd "$(dirname "$0")"

echo "[1/2] Building Docker image with fixes..."
gcloud builds submit \
  --config=cloudbuild.yaml \
  --substitutions=_IMAGE_URL=$IMAGE_URL \
  --timeout=20m \
  --project $PROJECT_ID

echo ""
echo "[2/2] Deploying to Cloud Run with updated configuration..."

# Get project number for service account
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Use existing API secret or generate new one
API_SECRET=${API_SECRET:-"1098003e437f79cfc68f13f614505bea5157dd3f4eff9e6b2d9e35e29d76befa"}

gcloud run deploy iso-builder \
  --image $IMAGE_URL \
  --region $REGION \
  --project $PROJECT_ID \
  --platform managed \
  --memory 2Gi \
  --cpu 2 \
  --timeout 3600 \
  --max-instances 10 \
  --min-instances 0 \
  --set-env-vars="NODE_ENV=production,GCP_PROJECT_ID=$PROJECT_ID,GCP_ZONE=us-west1-a,GCP_REGION=$REGION,GCS_ARTIFACTS_BUCKET=cloud-ai-server-artifacts,GCS_DOWNLOADS_BUCKET=cloud-ai-server-downloads,VM_MACHINE_TYPE=c2d-highcpu-32,VM_BOOT_DISK_SIZE=500,VM_LOCAL_SSD_COUNT=4,MAX_CONCURRENT_BUILDS=3,BUILD_TIMEOUT_HOURS=6,STALLED_PROGRESS_MINUTES=30,VM_AUTO_CLEANUP=true,API_SECRET_KEY=$API_SECRET,LOG_LEVEL=info" \
  --service-account="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo ""
echo "========================================="
echo "✓ Redeploy complete!"
echo "========================================="
echo ""

# Get service URL
SERVICE_URL=$(gcloud run services describe iso-builder --platform managed --region $REGION --project $PROJECT_ID --format="value(status.url)")
echo "Service URL: $SERVICE_URL"
echo ""
echo "The webapp is now running with all improvements:"
echo "  ✓ Upgraded VM: c2d-highcpu-32 (32 vCPUs, 64GB RAM)"
echo "  ✓ Extended timeout: 6 hours (was 4 hours)"
echo "  ✓ Stalled progress detection: 30 minute threshold"
echo "  ✓ 1% logging threshold: reduced log spam"
echo "  ✓ ComfyUI & HuggingFace TGI: added AI services"
echo ""
echo "Try starting a new ISO build now!"
echo ""
