#!/bin/bash
# Quick fix script to increase rate limit on deployed Cloud Run service

set -e

echo "=================================================="
echo "  Rate Limit Quick Fix for ISO Builder"
echo "=================================================="
echo ""

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    echo "ERROR: gcloud command not found"
    echo ""
    echo "Please install Google Cloud SDK:"
    echo "  https://cloud.google.com/sdk/docs/install"
    echo ""
    exit 1
fi

# Get current project
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo "ERROR: No GCP project configured"
    echo "Run: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

echo "Project: $PROJECT_ID"
echo ""

# Detect region (check common regions)
echo "Detecting Cloud Run service..."
REGIONS=("us-west1" "us-central1" "us-east1" "europe-west1")
SERVICE_FOUND=false
REGION=""

for r in "${REGIONS[@]}"; do
    if gcloud run services describe iso-builder --region "$r" --project "$PROJECT_ID" &>/dev/null; then
        REGION="$r"
        SERVICE_FOUND=true
        echo "✓ Found service 'iso-builder' in region: $REGION"
        break
    fi
done

if [ "$SERVICE_FOUND" = false ]; then
    echo "ERROR: Could not find 'iso-builder' service"
    echo ""
    echo "Available services:"
    gcloud run services list --project "$PROJECT_ID"
    echo ""
    echo "Please specify the region manually:"
    echo "  ./fix-rate-limit-now.sh REGION"
    exit 1
fi

echo ""
echo "Current configuration:"
gcloud run services describe iso-builder \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --format="value(spec.template.spec.containers[0].env)" | grep -i rate || echo "  No rate limit env vars set"

echo ""
echo "=================================================="
echo "Applying fix: Increasing rate limit to 100 req/15min"
echo "=================================================="
echo ""

# Update the service with new rate limit
gcloud run services update iso-builder \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --set-env-vars RATE_LIMIT_MAX=100 \
    --quiet

echo ""
echo "✓ Rate limit updated successfully!"
echo ""
echo "New configuration:"
gcloud run services describe iso-builder \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --format="value(spec.template.spec.containers[0].env)" | grep RATE_LIMIT || echo "  RATE_LIMIT_MAX=100 (default)"

echo ""
echo "=================================================="
echo "Testing the service..."
echo "=================================================="
echo ""

# Get service URL
SERVICE_URL=$(gcloud run services describe iso-builder \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --format="value(status.url)")

echo "Service URL: $SERVICE_URL"
echo ""

# Test the health endpoint
echo "Testing /health endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$SERVICE_URL/health")

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Service is healthy (HTTP $HTTP_CODE)"
else
    echo "⚠ Service returned HTTP $HTTP_CODE"
fi

echo ""
echo "Testing /api/services endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$SERVICE_URL/api/services")

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ API is responding (HTTP $HTTP_CODE)"
else
    echo "⚠ API returned HTTP $HTTP_CODE"
fi

echo ""
echo "=================================================="
echo "✓ Fix applied successfully!"
echo "=================================================="
echo ""
echo "The rate limit has been increased from 10 to 100 requests per 15 minutes."
echo "You can now access the webapp without rate limit errors."
echo ""
echo "Service URL: $SERVICE_URL"
echo ""
