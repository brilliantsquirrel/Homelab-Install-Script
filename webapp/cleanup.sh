#!/bin/bash

# Cleanup Script for Homelab ISO Builder
# Removes all deployed resources to avoid ongoing costs

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

header "Homelab ISO Builder - Cleanup Script"

# Load configuration if available
if [ -f .deployment-info ]; then
    source .deployment-info
    log "Loaded configuration from .deployment-info"
    echo "  Project ID: $PROJECT_ID"
    echo "  Region: $REGION"
    echo "  Service URL: $SERVICE_URL"
    echo ""
else
    warning "No .deployment-info found"
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
    REGION=$(gcloud config get-value compute/region 2>/dev/null)
    ZONE=$(gcloud config get-value compute/zone 2>/dev/null)

    if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
        error "No project configured. Please run: gcloud config set project PROJECT_ID"
        exit 1
    fi

    log "Using current project: $PROJECT_ID"
fi

# Confirmation
echo ""
error "⚠️  WARNING: This will DELETE all resources!"
echo ""
echo "This will remove:"
echo "  • Cloud Run service (iso-builder)"
echo "  • All ISO builder VMs"
echo "  • GCS buckets and all ISOs"
echo "  • All cached Docker images and models"
echo ""
warning "This action CANNOT be undone!"
echo ""
read -p "Type 'DELETE' to confirm: " CONFIRM

if [ "$CONFIRM" != "DELETE" ]; then
    log "Cleanup cancelled"
    exit 0
fi

# Delete Cloud Run service
header "Step 1: Deleting Cloud Run Service"

if [ -n "$REGION" ]; then
    log "Deleting iso-builder service in $REGION..."
    if gcloud run services delete iso-builder --region $REGION --quiet 2>/dev/null; then
        success "✓ Deleted Cloud Run service"
    else
        warning "Cloud Run service not found or already deleted"
    fi
else
    warning "Region not configured, skipping Cloud Run deletion"
fi

# Delete VMs
header "Step 2: Deleting ISO Builder VMs"

if [ -n "$ZONE" ]; then
    log "Searching for ISO builder VMs..."
    VMS=$(gcloud compute instances list --filter="labels.purpose=iso-builder" --format="value(name)" 2>/dev/null || echo "")

    if [ -n "$VMS" ]; then
        for vm in $VMS; do
            log "Deleting VM: $vm"
            gcloud compute instances delete $vm --zone=$ZONE --quiet
        done
        success "✓ Deleted all ISO builder VMs"
    else
        log "No ISO builder VMs found"
    fi
else
    warning "Zone not configured, skipping VM deletion"
fi

# Delete GCS buckets
header "Step 3: Deleting Cloud Storage Buckets"

if [ -n "$ARTIFACTS_BUCKET" ]; then
    log "Deleting artifacts bucket: gs://$ARTIFACTS_BUCKET"
    if gsutil ls -b gs://$ARTIFACTS_BUCKET >/dev/null 2>&1; then
        gsutil -m rm -r gs://$ARTIFACTS_BUCKET
        success "✓ Deleted artifacts bucket"
    else
        warning "Artifacts bucket not found or already deleted"
    fi
else
    # Try to find buckets by project ID
    log "Searching for buckets by project ID..."
    ARTIFACTS_BUCKET="${PROJECT_ID}-artifacts"
    if gsutil ls -b gs://$ARTIFACTS_BUCKET >/dev/null 2>&1; then
        log "Found artifacts bucket: gs://$ARTIFACTS_BUCKET"
        gsutil -m rm -r gs://$ARTIFACTS_BUCKET
        success "✓ Deleted artifacts bucket"
    else
        log "No artifacts bucket found"
    fi
fi

if [ -n "$DOWNLOADS_BUCKET" ]; then
    log "Deleting downloads bucket: gs://$DOWNLOADS_BUCKET"
    if gsutil ls -b gs://$DOWNLOADS_BUCKET >/dev/null 2>&1; then
        gsutil -m rm -r gs://$DOWNLOADS_BUCKET
        success "✓ Deleted downloads bucket"
    else
        warning "Downloads bucket not found or already deleted"
    fi
else
    # Try to find buckets by project ID
    DOWNLOADS_BUCKET="${PROJECT_ID}-downloads"
    if gsutil ls -b gs://$DOWNLOADS_BUCKET >/dev/null 2>&1; then
        log "Found downloads bucket: gs://$DOWNLOADS_BUCKET"
        gsutil -m rm -r gs://$DOWNLOADS_BUCKET
        success "✓ Deleted downloads bucket"
    else
        log "No downloads bucket found"
    fi
fi

# Delete Container Registry images
header "Step 4: Deleting Container Registry Images"

log "Deleting iso-builder images..."
if gcloud container images list --repository=gcr.io/$PROJECT_ID 2>/dev/null | grep -q iso-builder; then
    gcloud container images delete gcr.io/$PROJECT_ID/iso-builder --quiet 2>/dev/null || true
    success "✓ Deleted container images"
else
    log "No container images found"
fi

# Summary
header "Cleanup Complete! ✅"

echo ""
success "✓ All Homelab ISO Builder resources have been deleted"
echo ""
log "Resources removed:"
echo "  • Cloud Run service"
echo "  • ISO builder VMs"
echo "  • GCS buckets (artifacts and downloads)"
echo "  • Container images"
echo ""
log "Project still exists: $PROJECT_ID"
echo ""
echo "To delete the entire project:"
echo "  gcloud projects delete $PROJECT_ID"
echo ""
log "To verify all resources are deleted:"
echo "  gcloud run services list --region=$REGION"
echo "  gcloud compute instances list"
echo "  gsutil ls"
echo ""

# Remove deployment info file
if [ -f .deployment-info ]; then
    rm .deployment-info
    log "Removed .deployment-info file"
fi

echo ""
success "Cleanup completed successfully!"
echo ""
