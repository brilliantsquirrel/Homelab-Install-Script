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
echo "Choose a fix option:"
echo "=================================================="
echo "1. Disable rate limiting entirely (recommended for testing)"
echo "2. Set very high limit (1000 req/15min)"
echo "3. Set moderate limit (500 req/15min)"
echo ""
read -p "Enter choice (1-3) [default: 1]: " choice
choice=${choice:-1}

case $choice in
    1)
        ENV_VARS="RATE_LIMIT_ENABLED=false"
        echo "Disabling rate limiting..."
        ;;
    2)
        ENV_VARS="RATE_LIMIT_MAX=1000"
        echo "Setting limit to 1000 requests per 15 minutes..."
        ;;
    3)
        ENV_VARS="RATE_LIMIT_MAX=500"
        echo "Setting limit to 500 requests per 15 minutes..."
        ;;
    *)
        echo "Invalid choice, defaulting to option 1 (disable)"
        ENV_VARS="RATE_LIMIT_ENABLED=false"
        ;;
esac

echo ""
echo "=================================================="
echo "Applying fix..."
echo "=================================================="
echo ""

# Update the service with new rate limit
gcloud run services update iso-builder \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --set-env-vars "$ENV_VARS" \
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

case $choice in
    1)
        echo "Rate limiting has been DISABLED."
        ;;
    2)
        echo "Rate limit set to 1000 requests per 15 minutes."
        ;;
    3)
        echo "Rate limit set to 500 requests per 15 minutes."
        ;;
esac

echo "You can now access the webapp without rate limit errors."
echo ""
echo "Service URL: $SERVICE_URL"
echo ""
echo "Note: Changes take effect immediately but may need 1-2 minutes to propagate."
echo ""
