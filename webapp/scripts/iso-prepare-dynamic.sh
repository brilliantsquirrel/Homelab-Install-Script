#!/bin/bash

# Dynamic ISO Preparation Script
# This is a modified version of iso-prepare.sh that accepts dynamic service and model selection
# Used by the webapp to prepare ISOs with custom configurations
#
# Environment variables:
#   SELECTED_SERVICES - Comma-separated list of services to include
#   SELECTED_MODELS - Comma-separated list of Ollama models to include
#   GPU_ENABLED - "true" or "false" for GPU support
#   GCS_BUCKET - GCS bucket for artifacts (optional, will be detected from metadata)
#   BUILD_ID - Build ID for progress tracking (optional)
#   DOWNLOADS_BUCKET - GCS downloads bucket for status updates (optional)

set -e

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

# Progress tracking for webapp builds
# Get BUILD_ID from metadata if not set
if [ -z "${BUILD_ID:-}" ] && command -v curl &> /dev/null; then
    BUILD_ID=$(curl -s -f -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/build-id" 2>/dev/null || echo "")
fi

# Get DOWNLOADS_BUCKET from metadata if not set
if [ -z "${DOWNLOADS_BUCKET:-}" ] && command -v curl &> /dev/null; then
    DOWNLOADS_BUCKET=$(curl -s -f -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/downloads-bucket" 2>/dev/null || echo "")
fi

# Function to write build status to GCS for real-time progress tracking
write_status() {
    local stage="$1"
    local progress="$2"
    local message="$3"

    # Only write status if BUILD_ID and DOWNLOADS_BUCKET are set
    if [ -z "${BUILD_ID:-}" ] || [ -z "${DOWNLOADS_BUCKET:-}" ]; then
        return 0
    fi

    local BUILD_ID_SHORT="${BUILD_ID:0:8}"
    local STATUS_FILE="gs://$DOWNLOADS_BUCKET/build-status-${BUILD_ID_SHORT}.json"

    cat > /tmp/build-status.json <<EOF
{
  "stage": "$stage",
  "progress": $progress,
  "message": "$message",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Upload status file (retry up to 3 times, silently)
    for i in {1..3}; do
        if gsutil cp /tmp/build-status.json "$STATUS_FILE" 2>/dev/null; then
            break
        fi
        sleep 1
    done
}

# Get the repository root directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

header "Dynamic ISO Preparation - Custom Homelab Configuration"

# Parse environment variables
IFS=',' read -ra SERVICES <<< "$SELECTED_SERVICES"
IFS=',' read -ra MODELS <<< "$SELECTED_MODELS"

log "Selected services: ${SERVICES[*]}"
log "Selected models: ${MODELS[*]}"
log "GPU enabled: ${GPU_ENABLED:-false}"

# Create output directory structure
ISO_DIR="$REPO_DIR/iso-artifacts"
HOMELAB_DIR="$ISO_DIR/homelab"
DOCKER_DIR="$ISO_DIR/docker-images"
MODELS_DIR="$ISO_DIR/ollama-models"
SCRIPTS_DIR="$ISO_DIR/scripts"

log "Creating ISO project directory structure..."
mkdir -p "$HOMELAB_DIR"
mkdir -p "$DOCKER_DIR"
mkdir -p "$MODELS_DIR"
mkdir -p "$SCRIPTS_DIR"

success "✓ Created: $ISO_DIR"

# ========================================
# Google Cloud Storage Configuration
# ========================================

# Try to get bucket name from GCloud VM metadata
BUCKET_FROM_METADATA=""
if command -v curl &> /dev/null; then
    BUCKET_FROM_METADATA=$(curl -s -f -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name" 2>/dev/null)
fi

# Use metadata if available, otherwise fall back to environment variable
if [ -n "$BUCKET_FROM_METADATA" ]; then
    GCS_BUCKET="gs://${BUCKET_FROM_METADATA}"
    log "✓ Detected GCS bucket from VM metadata: $GCS_BUCKET"
elif [ -n "${GCS_BUCKET:-}" ]; then
    log "✓ Using GCS bucket from environment variable: $GCS_BUCKET"
else
    error "✗ No GCS bucket configured"
    GCS_BUCKET=""
fi

# Check if gsutil is available
check_gcs_available() {
    if [ -z "$GCS_BUCKET" ]; then
        return 1
    fi
    if command -v gsutil &> /dev/null; then
        if gsutil ls "$GCS_BUCKET" &> /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

if check_gcs_available; then
    success "✓ GCS bucket accessible: $GCS_BUCKET"
    GCS_ENABLED=true
else
    error "✗ GCS bucket not accessible - files will only be stored locally"
    GCS_ENABLED=false
fi

# Copy homelab scripts
header "Copying Homelab Scripts"

log "Copying homelab files..."
write_status "preparing" 26 "Copying homelab scripts"
rsync -rlv --no-times --no-perms --exclude='iso-artifacts' --exclude='.git' "$REPO_DIR/" "$HOMELAB_DIR/" || {
    warning "⚠ rsync reported errors (expected on gcsfuse)"
    log "Files copied successfully"
}
write_status "preparing" 27 "Generating custom docker-compose.yml"

# Generate custom docker-compose.yml with only selected services
log "Generating custom docker-compose.yml..."
python3 << PYTHON_EOF
import yaml
import sys

# Read original docker-compose.yml
with open('$REPO_DIR/docker-compose.yml', 'r') as f:
    compose = yaml.safe_load(f)

selected_services = '${SELECTED_SERVICES}'.split(',')

# Filter services
filtered_services = {}
for service in selected_services:
    if service in compose['services']:
        filtered_services[service] = compose['services'][service]

# Always include dependencies
def add_dependencies(service_name):
    service = compose['services'].get(service_name)
    if not service:
        return

    # Check depends_on
    if 'depends_on' in service:
        for dep in service['depends_on']:
            if dep not in filtered_services:
                filtered_services[dep] = compose['services'][dep]
                add_dependencies(dep)

for service in list(filtered_services.keys()):
    add_dependencies(service)

compose['services'] = filtered_services

# Enable GPU if requested
if '${GPU_ENABLED}' == 'true':
    for service_name in ['ollama', 'plex']:
        if service_name in filtered_services:
            if 'runtime' in compose['services'][service_name]:
                filtered_services[service_name]['runtime'] = 'nvidia'

# Write custom docker-compose.yml
with open('$HOMELAB_DIR/docker-compose.yml', 'w') as f:
    yaml.dump(compose, f, default_flow_style=False)

print(f"Generated docker-compose.yml with {len(filtered_services)} services")
PYTHON_EOF

success "✓ Custom docker-compose.yml generated"

# ========================================
# Step 0: Download Ubuntu Server ISO
# ========================================

header "Step 0: Downloading Ubuntu Server 24.04 LTS ISO"

write_status "downloading-ubuntu" 28 "Downloading Ubuntu Server ISO"

UBUNTU_VERSION="24.04.3"
UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_FILE="$ISO_DIR/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_GCS="iso/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

# Check if ISO already exists
if [ -f "$UBUNTU_ISO_FILE" ]; then
    log "Ubuntu Server ISO already downloaded"
    write_status "downloading-ubuntu" 29 "Ubuntu Server ISO already available"
elif [ "$GCS_ENABLED" = true ] && gsutil -q stat "$GCS_BUCKET/$UBUNTU_ISO_GCS" 2>/dev/null; then
    log "Downloading Ubuntu ISO from GCS..."
    gsutil cp "$GCS_BUCKET/$UBUNTU_ISO_GCS" "$UBUNTU_ISO_FILE"
    success "✓ Downloaded from GCS"
    write_status "downloading-ubuntu" 29 "Ubuntu Server ISO downloaded from cache"
else
    log "Downloading Ubuntu Server ISO from official source..."
    wget -O "$UBUNTU_ISO_FILE" "$UBUNTU_ISO_URL" || {
        error "Failed to download Ubuntu ISO"
        write_status "failed" 0 "Failed to download Ubuntu Server ISO"
        exit 1
    }
    success "✓ Downloaded Ubuntu ISO"
    write_status "downloading-ubuntu" 29 "Ubuntu Server ISO downloaded"
fi

# ========================================
# Step 1: Download Docker Images
# ========================================

header "Step 1: Downloading Selected Docker Images"

# Build list of required Docker images based on selected services
DOCKER_IMAGES=()

# Service to image mapping
declare -A SERVICE_IMAGES
SERVICE_IMAGES["ollama"]="ollama/ollama:0.12.9"
SERVICE_IMAGES["openwebui"]="ghcr.io/open-webui/open-webui:main"
SERVICE_IMAGES["langchain"]="langchain/langserve:latest"
SERVICE_IMAGES["langgraph"]="langchain/langgraph-api:3.11"
SERVICE_IMAGES["langgraph-db"]="postgres:16-alpine"
SERVICE_IMAGES["langgraph-redis"]="redis:7-alpine"
SERVICE_IMAGES["langflow"]="langflowai/langflow:latest"
SERVICE_IMAGES["n8n"]="n8nio/n8n:latest"
SERVICE_IMAGES["qdrant"]="qdrant/qdrant:latest"
SERVICE_IMAGES["homarr"]="ghcr.io/ajnart/homarr:latest"
SERVICE_IMAGES["hoarder"]="ghcr.io/hoarder-app/hoarder:latest"
SERVICE_IMAGES["plex"]="plexinc/pms-docker:latest"
SERVICE_IMAGES["nextcloud"]="nextcloud:latest"
SERVICE_IMAGES["nextcloud-db"]="postgres:16-alpine"
SERVICE_IMAGES["nextcloud-redis"]="redis:7-alpine"
SERVICE_IMAGES["pihole"]="pihole/pihole:latest"
SERVICE_IMAGES["portainer"]="portainer/portainer-ce:latest"
SERVICE_IMAGES["docker-socket-proxy"]="tecnativa/docker-socket-proxy:latest"

# Add images for selected services
for service in "${SERVICES[@]}"; do
    if [ -n "${SERVICE_IMAGES[$service]}" ]; then
        DOCKER_IMAGES+=("${SERVICE_IMAGES[$service]}")
    fi
done

# Remove duplicates
DOCKER_IMAGES=($(printf "%s\n" "${DOCKER_IMAGES[@]}" | sort -u))

log "Downloading ${#DOCKER_IMAGES[@]} Docker images..."

# Calculate progress increment per image (30-55% range for Docker images)
TOTAL_IMAGES=${#DOCKER_IMAGES[@]}
PROGRESS_START=30
PROGRESS_END=55
if [ $TOTAL_IMAGES -gt 0 ]; then
    PROGRESS_PER_IMAGE=$(( (PROGRESS_END - PROGRESS_START) / TOTAL_IMAGES ))
else
    PROGRESS_PER_IMAGE=0
fi
CURRENT_PROGRESS=$PROGRESS_START
IMAGE_COUNT=0

for image in "${DOCKER_IMAGES[@]}"; do
    IMAGE_COUNT=$((IMAGE_COUNT + 1))
    filename=$(echo "$image" | sed 's/[\/:]/_/g')
    local_file="$DOCKER_DIR/${filename}.tar.gz"
    gcs_filename="docker-images/${filename}.tar.gz"

    # Update progress
    write_status "downloading-images" $CURRENT_PROGRESS "Downloading Docker image $IMAGE_COUNT/$TOTAL_IMAGES: $image"

    # Check if already exists locally
    if [ -f "$local_file" ]; then
        log "✓ $image (exists locally)"
        CURRENT_PROGRESS=$((CURRENT_PROGRESS + PROGRESS_PER_IMAGE))
        continue
    fi

    # Check if exists in GCS
    if [ "$GCS_ENABLED" = true ] && gsutil -q stat "$GCS_BUCKET/$gcs_filename" 2>/dev/null; then
        log "Downloading $image from GCS..."
        gsutil cp "$GCS_BUCKET/$gcs_filename" "$local_file"
        success "✓ $image (from GCS)"
    else
        log "Pulling $image from Docker Hub..."
        sudo docker pull "$image"

        log "Saving $image..."
        if command -v pigz &> /dev/null; then
            sudo docker save "$image" | pigz -p 4 > "$local_file"
        else
            sudo docker save "$image" | gzip > "$local_file"
        fi

        success "✓ $image (downloaded and saved)"
    fi

    # Increment progress
    CURRENT_PROGRESS=$((CURRENT_PROGRESS + PROGRESS_PER_IMAGE))
done

write_status "downloading-images" 55 "All Docker images downloaded"
success "✓ All Docker images ready"

# ========================================
# Step 2: Download Ollama Models
# ========================================

if [ ${#MODELS[@]} -gt 0 ]; then
    header "Step 2: Downloading Selected Ollama Models"

    # Calculate progress increment per model (56-59% range for Ollama models)
    TOTAL_MODELS=${#MODELS[@]}
    PROGRESS_START=56
    PROGRESS_END=59
    if [ $TOTAL_MODELS -gt 0 ]; then
        PROGRESS_PER_MODEL=$(( (PROGRESS_END - PROGRESS_START) / TOTAL_MODELS ))
        if [ $PROGRESS_PER_MODEL -lt 1 ]; then
            PROGRESS_PER_MODEL=1
        fi
    else
        PROGRESS_PER_MODEL=0
    fi
    CURRENT_PROGRESS=$PROGRESS_START
    MODEL_COUNT=0

    for model in "${MODELS[@]}"; do
        MODEL_COUNT=$((MODEL_COUNT + 1))
        model_filename=$(echo "$model" | sed 's/[\/:]/_/g')
        model_tar_file="$MODELS_DIR/${model_filename}.tar.gz"
        model_gcs_filename="ollama-models/${model_filename}.tar.gz"

        # Update progress
        write_status "downloading-models" $CURRENT_PROGRESS "Downloading Ollama model $MODEL_COUNT/$TOTAL_MODELS: $model"

        # Check if already exists
        if [ -f "$model_tar_file" ]; then
            log "✓ $model (exists locally)"
            CURRENT_PROGRESS=$((CURRENT_PROGRESS + PROGRESS_PER_MODEL))
            continue
        fi

        # Check if exists in GCS
        if [ "$GCS_ENABLED" = true ] && gsutil -q stat "$GCS_BUCKET/$model_gcs_filename" 2>/dev/null; then
            log "Downloading $model from GCS..."
            gsutil cp "$GCS_BUCKET/$model_gcs_filename" "$model_tar_file"
            success "✓ $model (from GCS)"
            CURRENT_PROGRESS=$((CURRENT_PROGRESS + PROGRESS_PER_MODEL))
            continue
        fi

        # Download model
        log "Downloading Ollama model: $model (this may take a while)"

        container_name="ollama-temp-${model_filename}"
        volume_name="ollama-temp-${model_filename}"

        sudo docker run -d --name "$container_name" -v "$volume_name":/root/.ollama ollama/ollama:0.12.9
        sleep 5

        if sudo docker exec "$container_name" ollama pull "$model"; then
            success "✓ Downloaded: $model"

            log "Exporting model to tar file..."
            sudo docker run --rm -v "$volume_name":/models alpine \
                sh -c "cd /models && tar czf - ." > "$model_tar_file"

            success "✓ Exported: $model"
        else
            warning "Failed to download: $model, skipping"
        fi

        # Cleanup
        sudo docker stop "$container_name" 2>/dev/null || true
        sudo docker rm "$container_name" 2>/dev/null || true
        sudo docker volume rm "$volume_name" 2>/dev/null || true

        # Increment progress
        CURRENT_PROGRESS=$((CURRENT_PROGRESS + PROGRESS_PER_MODEL))
    done

    write_status "downloading-models" 59 "All Ollama models downloaded"
    success "✓ All Ollama models ready"
else
    write_status "downloading-models" 56 "No Ollama models selected, skipping"
    log "No Ollama models selected, skipping model download"
fi

# ========================================
# Summary
# ========================================

header "Preparation Complete!"

log "Configuration:"
echo "  - Services: ${#SERVICES[@]}"
echo "  - Docker Images: ${#DOCKER_IMAGES[@]}"
echo "  - Ollama Models: ${#MODELS[@]}"
echo "  - GPU Enabled: ${GPU_ENABLED:-false}"
echo ""

write_status "preparation-complete" 59 "All dependencies downloaded, ready for ISO build"
success "✓ Ready for ISO building"
log "Next step: Run create-custom-iso.sh to build the ISO"
