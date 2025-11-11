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

# Change to repo root for Docker build
cd "$(dirname "$0")/.."

echo "[1/2] Building Docker image with fixes..."
gcloud builds submit \
  --tag $IMAGE_URL \
  --timeout=20m \
  --project $PROJECT_ID

echo ""
echo "[2/2] Deploying to Cloud Run..."
gcloud run deploy iso-builder \
  --image $IMAGE_URL \
  --region $REGION \
  --project $PROJECT_ID \
  --platform managed

echo ""
echo "========================================="
echo "✓ Redeploy complete!"
echo "========================================="
echo ""

# Get service URL
SERVICE_URL=$(gcloud run services describe iso-builder --platform managed --region $REGION --project $PROJECT_ID --format="value(status.url)")
echo "Service URL: $SERVICE_URL"
echo ""
echo "The webapp is now running with all fixes:"
echo "  ✓ ISO name validation (allows periods)"
echo "  ✓ VM manager (uses ZoneOperationsClient)"
echo "  ✓ Dockerfile deployment (npm install fix)"
echo ""
echo "Try starting a new ISO build now!"
echo ""
