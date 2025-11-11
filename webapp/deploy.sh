#!/bin/bash

# Automated Deployment Script for Homelab ISO Builder
# This script deploys the webapp to Google Cloud Run from scratch

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Main deployment
header "Homelab ISO Builder - Automated Deployment"

# Check prerequisites
log "Checking prerequisites..."

if ! command_exists gcloud; then
    error "gcloud CLI not found. Please install from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

if ! command_exists git; then
    error "git not found. Please install git first."
    exit 1
fi

success "✓ Prerequisites installed"

# Login check
log "Checking Google Cloud authentication..."
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
    log "Please login to Google Cloud..."
    gcloud auth login
fi

CURRENT_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
success "✓ Logged in as: $CURRENT_ACCOUNT"

# Project configuration
header "Step 1: Project Configuration"

# Check if project already set
EXISTING_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -n "$EXISTING_PROJECT" ] && [ "$EXISTING_PROJECT" != "(unset)" ]; then
    log "Current project: $EXISTING_PROJECT"
    read -p "Use this project? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        PROJECT_ID="$EXISTING_PROJECT"
    else
        read -p "Enter new project ID: " PROJECT_ID
        gcloud config set project $PROJECT_ID
    fi
else
    read -p "Enter project ID (or press Enter to create new): " PROJECT_ID

    if [ -z "$PROJECT_ID" ]; then
        PROJECT_ID="homelab-iso-builder-$(date +%s)"
        log "Creating new project: $PROJECT_ID"

        read -p "Enter billing account ID (find at console.cloud.google.com/billing): " BILLING_ACCOUNT_ID

        gcloud projects create $PROJECT_ID --name="Homelab ISO Builder"
        gcloud config set project $PROJECT_ID
        gcloud billing projects link $PROJECT_ID --billing-account=$BILLING_ACCOUNT_ID

        success "✓ Created project: $PROJECT_ID"
    else
        gcloud config set project $PROJECT_ID
    fi
fi

success "✓ Using project: $PROJECT_ID"

# Region configuration
header "Step 2: Region Configuration"

echo "Available regions (low cost):"
echo "  1. us-west1 (Oregon)"
echo "  2. us-central1 (Iowa)"
echo "  3. us-east1 (South Carolina)"
echo "  4. europe-west1 (Belgium)"
echo "  5. asia-east1 (Taiwan)"
echo ""
read -p "Select region [1]: " REGION_CHOICE
REGION_CHOICE=${REGION_CHOICE:-1}

case $REGION_CHOICE in
    1) REGION="us-west1"; ZONE="us-west1-a" ;;
    2) REGION="us-central1"; ZONE="us-central1-a" ;;
    3) REGION="us-east1"; ZONE="us-east1-b" ;;
    4) REGION="europe-west1"; ZONE="europe-west1-b" ;;
    5) REGION="asia-east1"; ZONE="asia-east1-a" ;;
    *) REGION="us-west1"; ZONE="us-west1-a" ;;
esac

gcloud config set compute/region $REGION
gcloud config set compute/zone $ZONE

success "✓ Using region: $REGION (zone: $ZONE)"

# Enable APIs
header "Step 3: Enabling Required APIs"

log "This may take 2-3 minutes..."
gcloud services enable \
    compute.googleapis.com \
    storage.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    cloudresourcemanager.googleapis.com \
    --quiet

success "✓ All APIs enabled"

# Create buckets
header "Step 4: Creating Cloud Storage Buckets"

ARTIFACTS_BUCKET="${PROJECT_ID}-artifacts"
DOWNLOADS_BUCKET="${PROJECT_ID}-downloads"

log "Creating artifacts bucket: gs://$ARTIFACTS_BUCKET"
if gsutil ls -b gs://$ARTIFACTS_BUCKET >/dev/null 2>&1; then
    warning "Artifacts bucket already exists, skipping"
else
    gsutil mb -p $PROJECT_ID -l $REGION gs://$ARTIFACTS_BUCKET
    success "✓ Created artifacts bucket"
fi

log "Creating downloads bucket: gs://$DOWNLOADS_BUCKET"
if gsutil ls -b gs://$DOWNLOADS_BUCKET >/dev/null 2>&1; then
    warning "Downloads bucket already exists, skipping"
else
    gsutil mb -p $PROJECT_ID -l $REGION gs://$DOWNLOADS_BUCKET

    # Set lifecycle policy
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
    rm /tmp/lifecycle-policy.json

    success "✓ Created downloads bucket with 7-day lifecycle"
fi

# Set up IAM permissions
header "Step 5: Configuring IAM Permissions"

PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
log "Project number: $PROJECT_NUMBER"

log "Granting Compute Admin permissions..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/compute.instanceAdmin.v1" \
    --quiet >/dev/null 2>&1

log "Granting Storage Admin permissions..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/storage.objectAdmin" \
    --quiet >/dev/null 2>&1

log "Granting Service Account User permissions..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" \
    --quiet >/dev/null 2>&1

success "✓ IAM permissions configured"

# Deploy to Cloud Run
header "Step 6: Deploying to Cloud Run"

log "This will take 5-10 minutes..."

# Generate random API secret (require openssl for cryptographic randomness)
if ! command_exists openssl; then
    error "openssl is required for generating secure API secrets"
    error "Please install openssl: apt-get install openssl (Debian/Ubuntu) or brew install openssl (macOS)"
    exit 1
fi
API_SECRET=$(openssl rand -hex 32)

# Step 6a: Build Docker image using Cloud Build
log "Building Docker image..."
IMAGE_URL="gcr.io/$PROJECT_ID/iso-builder"

# Change to parent directory to include Dockerfile at repo root
cd ..

gcloud builds submit \
    --tag $IMAGE_URL \
    --timeout=20m \
    --quiet

cd webapp

success "✓ Docker image built: $IMAGE_URL"

# Step 6b: Deploy to Cloud Run
log "Deploying to Cloud Run..."
gcloud run deploy iso-builder \
    --image $IMAGE_URL \
    --platform managed \
    --region $REGION \
    --allow-unauthenticated \
    --memory 2Gi \
    --cpu 2 \
    --timeout 3600 \
    --max-instances 10 \
    --min-instances 0 \
    --set-env-vars="NODE_ENV=production,GCP_PROJECT_ID=$PROJECT_ID,GCP_ZONE=$ZONE,GCP_REGION=$REGION,GCS_ARTIFACTS_BUCKET=$ARTIFACTS_BUCKET,GCS_DOWNLOADS_BUCKET=$DOWNLOADS_BUCKET,VM_MACHINE_TYPE=n2-standard-16,VM_BOOT_DISK_SIZE=500,VM_LOCAL_SSD_COUNT=2,MAX_CONCURRENT_BUILDS=3,BUILD_TIMEOUT_HOURS=4,VM_AUTO_CLEANUP=true,API_SECRET_KEY=$API_SECRET,LOG_LEVEL=info" \
    --service-account="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --quiet

success "✓ Deployed to Cloud Run"

# Get service URL
SERVICE_URL=$(gcloud run services describe iso-builder --platform managed --region $REGION --format="value(status.url)")

# Test deployment
header "Step 7: Testing Deployment"

log "Testing health endpoint..."
if curl -s -f "${SERVICE_URL}/health" > /dev/null; then
    success "✓ Health check passed"
else
    error "Health check failed"
    warning "Check logs: gcloud run services logs read iso-builder --region $REGION"
fi

log "Testing API endpoints..."
if curl -s -f "${SERVICE_URL}/api/services" > /dev/null; then
    success "✓ Services API working"
else
    warning "Services API returned error"
fi

# Final summary
header "Deployment Complete! 🎉"

echo ""
success "✓ Homelab ISO Builder is now live!"
echo ""
echo "📍 Service URL:    $SERVICE_URL"
echo "🗂️  Artifacts:     gs://$ARTIFACTS_BUCKET"
echo "💾 Downloads:      gs://$DOWNLOADS_BUCKET"
echo "🌎 Region:         $REGION"
echo "📊 Project:        $PROJECT_ID"
echo ""
echo "Next steps:"
echo "  1. Open the webapp: $SERVICE_URL"
echo "  2. Select services and models to include"
echo "  3. Build your custom ISO!"
echo ""
echo "View logs:"
echo "  gcloud run services logs tail iso-builder --region $REGION"
echo ""
echo "View metrics:"
echo "  https://console.cloud.google.com/run/detail/$REGION/iso-builder/metrics?project=$PROJECT_ID"
echo ""
echo "Cost monitoring:"
echo "  https://console.cloud.google.com/billing?project=$PROJECT_ID"
echo ""
warning "⚠️  Each ISO build costs approximately \$7-8"
warning "⚠️  Set up budget alerts to avoid surprises!"
echo ""
echo "Set budget alert:"
echo "  gcloud billing budgets create \\"
echo "    --billing-account=YOUR_BILLING_ACCOUNT_ID \\"
echo "    --display-name=\"ISO Builder Budget\" \\"
echo "    --budget-amount=100USD \\"
echo "    --threshold-rule=percent=50 \\"
echo "    --threshold-rule=percent=90"
echo ""

# Save configuration
cat > .deployment-info <<EOF
PROJECT_ID=$PROJECT_ID
PROJECT_NUMBER=$PROJECT_NUMBER
REGION=$REGION
ZONE=$ZONE
SERVICE_URL=$SERVICE_URL
ARTIFACTS_BUCKET=$ARTIFACTS_BUCKET
DOWNLOADS_BUCKET=$DOWNLOADS_BUCKET
DEPLOYED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

success "✓ Configuration saved to .deployment-info"

# Open browser
echo ""
read -p "Open webapp in browser? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if command_exists open; then
        open $SERVICE_URL
    elif command_exists xdg-open; then
        xdg-open $SERVICE_URL
    elif command_exists start; then
        start $SERVICE_URL
    else
        log "Please open this URL in your browser: $SERVICE_URL"
    fi
fi

echo ""
log "Deployment script completed successfully!"
log "For troubleshooting, see: webapp/QUICKSTART.md"
echo ""
