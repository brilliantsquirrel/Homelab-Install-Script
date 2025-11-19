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
# SECURITY: Validates all inputs and uses secure temporary files
write_status() {
    local stage="$1"
    local progress="$2"
    local message="$3"

    # Only write status if BUILD_ID and DOWNLOADS_BUCKET are set
    if [ -z "${BUILD_ID:-}" ] || [ -z "${DOWNLOADS_BUCKET:-}" ]; then
        return 0
    fi

    # SECURITY: Validate BUILD_ID format (UUID only, no shell metacharacters)
    if ! [[ "$BUILD_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "[ERROR] Invalid BUILD_ID format in write_status: $BUILD_ID"
        return 1
    fi

    # SECURITY: Validate DOWNLOADS_BUCKET format (GCS bucket naming rules)
    if ! [[ "$DOWNLOADS_BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]]; then
        echo "[ERROR] Invalid DOWNLOADS_BUCKET format in write_status: $DOWNLOADS_BUCKET"
        return 1
    fi

    # Safe substring (already validated format)
    local BUILD_ID_SHORT="${BUILD_ID:0:8}"
    local STATUS_FILE="gs://${DOWNLOADS_BUCKET}/build-status-${BUILD_ID_SHORT}.json"

    # SECURITY: Create secure temporary file (atomic, exclusive, mode 0600)
    local TEMP_STATUS
    TEMP_STATUS=$(mktemp /tmp/build-status.XXXXXXXXXX) || {
        echo "[ERROR] Failed to create secure temporary file"
        return 1
    }

    # Ensure cleanup on function exit
    trap "rm -f '$TEMP_STATUS'" RETURN

    # Write to secure temporary file
    cat > "$TEMP_STATUS" <<EOF
{
  "stage": "$stage",
  "progress": $progress,
  "message": "$message",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Upload from secure temp file (retry up to 3 times, silently)
    for i in {1..3}; do
        if gsutil cp "$TEMP_STATUS" "$STATUS_FILE" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # Explicit cleanup (trap will also clean up, but be explicit)
    rm -f "$TEMP_STATUS"
}

# Get the repository root directory
# This script is in webapp/scripts/, so go up 2 levels to get repo root
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

header "Dynamic ISO Preparation - Custom Homelab Configuration"

log "Script location: ${BASH_SOURCE[0]}"
log "Repository root: $REPO_DIR"

# Validation function for service/model names (SECURITY: Prevent command injection)
validate_name() {
    local name="$1"
    local type="$2"

    # Check for empty
    if [ -z "$name" ]; then
        error "Empty $type name detected"
        return 1
    fi

    # SECURITY: Only allow alphanumeric, dash, underscore, colon, slash, dot (for docker images)
    # Reject any shell metacharacters: ; | & $ ( ) ` < > \ " ' space newline
    if ! [[ "$name" =~ ^[a-zA-Z0-9:/_.-]+$ ]]; then
        error "Invalid $type name: $name (contains prohibited characters)"
        error "Only alphanumeric, dash, underscore, colon, slash, and dot allowed"
        return 1
    fi

    # Additional safety: Max length check (prevent buffer overflow attempts)
    if [ ${#name} -gt 200 ]; then
        error "Invalid $type name: $name (exceeds 200 character limit)"
        return 1
    fi

    return 0
}

# Whitelist of valid services (SECURITY: Defense in depth)
VALID_SERVICES="ollama openwebui langchain langgraph langgraph-db langgraph-redis langflow n8n qdrant homarr hoarder plex nextcloud nextcloud-db nextcloud-redis pihole portainer docker-socket-proxy nginx-proxy comfyui huggingface-tgi code-server"

# Whitelist of valid model patterns (allow version tags)
VALID_MODEL_PATTERN='^[a-z0-9-]+:[a-z0-9.-]+$'

# Parse and validate environment variables
IFS=',' read -ra SERVICES_RAW <<< "$SELECTED_SERVICES"
IFS=',' read -ra MODELS_RAW <<< "$SELECTED_MODELS"

# Validate and filter services
SERVICES=()
for service in "${SERVICES_RAW[@]}"; do
    # Trim whitespace
    service=$(echo "$service" | xargs)

    # Skip empty
    [ -z "$service" ] && continue

    # Validate format
    if ! validate_name "$service" "service"; then
        error "Skipping invalid service: $service"
        write_status "failed" 0 "Invalid service name: $service"
        exit 1
    fi

    # Check against whitelist
    if ! echo "$VALID_SERVICES" | grep -wq "$service"; then
        error "Unknown/unauthorized service: $service"
        error "Valid services: $VALID_SERVICES"
        write_status "failed" 0 "Unknown service: $service"
        exit 1
    fi

    SERVICES+=("$service")
done

# Validate and filter models
MODELS=()
for model in "${MODELS_RAW[@]}"; do
    # Trim whitespace
    model=$(echo "$model" | xargs)

    # Skip empty
    [ -z "$model" ] && continue

    # Validate format
    if ! validate_name "$model" "model"; then
        error "Skipping invalid model: $model"
        write_status "failed" 0 "Invalid model name: $model"
        exit 1
    fi

    # Validate model format (name:tag)
    if ! [[ "$model" =~ $VALID_MODEL_PATTERN ]]; then
        error "Invalid model format: $model (expected format: modelname:tag)"
        write_status "failed" 0 "Invalid model format: $model"
        exit 1
    fi

    MODELS+=("$model")
done

# Validate we have at least one service
if [ ${#SERVICES[@]} -eq 0 ]; then
    error "No valid services selected"
    write_status "failed" 0 "No valid services selected"
    exit 1
fi

log "Validated services: ${SERVICES[*]}"
log "Validated models: ${MODELS[*]}"
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

# Note: Progress values are offset by +20% to account for initial VM creation phase
# This ensures the progress bar never goes backward (was issue where it went from 20% → 5%)

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
write_status "preparing" 38 "Copying homelab scripts"
rsync -rlv --no-times --no-perms --exclude='iso-artifacts' --exclude='.git' "$REPO_DIR/" "$HOMELAB_DIR/" || {
    warning "⚠ rsync reported errors (expected on gcsfuse)"
    log "Files copied successfully"
}

# Ensure Python and PyYAML are available
log "Checking Python dependencies..."
if ! command -v python3 &> /dev/null; then
    error "Python3 not found, installing..."
    sudo apt-get update
    sudo apt-get install -y python3
fi

if ! python3 -c "import yaml" 2>/dev/null; then
    log "Installing PyYAML..."
    sudo apt-get install -y python3-yaml
fi

write_status "preparing" 39 "Generating custom docker-compose.yml"

# Generate custom docker-compose.yml with only selected services
log "Generating custom docker-compose.yml..."
log "REPO_DIR=$REPO_DIR"
log "HOMELAB_DIR=$HOMELAB_DIR"
log "Checking if docker-compose.yml exists..."
if [ ! -f "$REPO_DIR/docker-compose.yml" ]; then
    error "docker-compose.yml not found at $REPO_DIR/docker-compose.yml"
    write_status "failed" 0 "docker-compose.yml not found"
    exit 1
fi

REPO_DIR="$REPO_DIR" HOMELAB_DIR="$HOMELAB_DIR" SELECTED_SERVICES="$SELECTED_SERVICES" GPU_ENABLED="${GPU_ENABLED:-false}" python3 << 'PYTHON_EOF'
import yaml
import sys
import os

# Get variables from environment
repo_dir = os.environ.get('REPO_DIR', '.')
homelab_dir = os.environ.get('HOMELAB_DIR', './homelab')
selected_services_str = os.environ.get('SELECTED_SERVICES', '')
gpu_enabled = os.environ.get('GPU_ENABLED', 'false')

print(f"[DEBUG] repo_dir={repo_dir}")
print(f"[DEBUG] homelab_dir={homelab_dir}")
print(f"[DEBUG] selected_services={selected_services_str}")
print(f"[DEBUG] gpu_enabled={gpu_enabled}")

# Read original docker-compose.yml
compose_path = f"{repo_dir}/docker-compose.yml"
print(f"[DEBUG] Reading {compose_path}")

try:
    with open(compose_path, 'r') as f:
        compose = yaml.safe_load(f)
except Exception as e:
    print(f"[ERROR] Failed to read docker-compose.yml: {e}", file=sys.stderr)
    sys.exit(1)

selected_services = [s.strip() for s in selected_services_str.split(',') if s.strip()]
print(f"[DEBUG] Selected services: {selected_services}")

# Filter services
filtered_services = {}
for service in selected_services:
    if service in compose.get('services', {}):
        filtered_services[service] = compose['services'][service]
    else:
        print(f"[WARNING] Service '{service}' not found in docker-compose.yml")

# Always include dependencies
def add_dependencies(service_name):
    service = compose.get('services', {}).get(service_name)
    if not service:
        return

    # Check depends_on
    if 'depends_on' in service:
        for dep in service['depends_on']:
            if dep not in filtered_services:
                if dep in compose['services']:
                    filtered_services[dep] = compose['services'][dep]
                    add_dependencies(dep)

for service in list(filtered_services.keys()):
    add_dependencies(service)

compose['services'] = filtered_services

# Enable GPU if requested
if gpu_enabled == 'true':
    for service_name in ['ollama', 'plex']:
        if service_name in filtered_services:
            # Check if runtime field exists in original config
            if 'runtime' in compose.get('services', {}).get(service_name, {}):
                filtered_services[service_name]['runtime'] = 'nvidia'

# Write custom docker-compose.yml
output_path = f"{homelab_dir}/docker-compose.yml"
print(f"[DEBUG] Writing to {output_path}")

try:
    with open(output_path, 'w') as f:
        yaml.dump(compose, f, default_flow_style=False)
    print(f"Generated docker-compose.yml with {len(filtered_services)} services")
except Exception as e:
    print(f"[ERROR] Failed to write docker-compose.yml: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF

if [ $? -ne 0 ]; then
    error "Failed to generate docker-compose.yml"
    write_status "failed" 0 "Failed to generate docker-compose.yml"
    exit 1
fi

success "✓ Custom docker-compose.yml generated"

# ========================================
# Step 0: Download Ubuntu Server ISO
# ========================================

header "Step 0: Downloading Ubuntu Server 24.04 LTS ISO"

write_status "downloading-ubuntu" 39 "Downloading Ubuntu Server ISO"

UBUNTU_VERSION="24.04.3"
UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_FILE="$ISO_DIR/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_GCS="iso/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

# Check if ISO already exists
if [ -f "$UBUNTU_ISO_FILE" ]; then
    log "Ubuntu Server ISO already downloaded"
    write_status "downloading-ubuntu" 40 "Ubuntu Server ISO already available"
elif [ "$GCS_ENABLED" = true ] && gsutil -q stat "$GCS_BUCKET/$UBUNTU_ISO_GCS" 2>/dev/null; then
    log "Downloading Ubuntu ISO from GCS cache..."
    gsutil cp "$GCS_BUCKET/$UBUNTU_ISO_GCS" "$UBUNTU_ISO_FILE"
    success "✓ Downloaded from GCS cache"
    write_status "downloading-ubuntu" 40 "Ubuntu Server ISO downloaded from cache"
else
    log "Downloading Ubuntu Server ISO from official source (this will be cached for future builds)..."
    wget -O "$UBUNTU_ISO_FILE" "$UBUNTU_ISO_URL" || {
        error "Failed to download Ubuntu ISO"
        write_status "failed" 0 "Failed to download Ubuntu Server ISO"
        exit 1
    }
    success "✓ Downloaded Ubuntu ISO"
    write_status "downloading-ubuntu" 40 "Ubuntu Server ISO downloaded"

    # Upload to GCS cache for future builds (run in background)
    if [ "$GCS_ENABLED" = true ] && [ -f "$UBUNTU_ISO_FILE" ]; then
        log "Caching Ubuntu ISO to GCS for future builds..."
        (
            if gsutil -m cp "$UBUNTU_ISO_FILE" "$GCS_BUCKET/$UBUNTU_ISO_GCS" 2>/dev/null; then
                echo "[INFO] ✓ Cached Ubuntu ISO in GCS for future builds"
            fi
        ) &
    fi
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

# Calculate progress increment per image (41-62% range for Docker images)
TOTAL_IMAGES=${#DOCKER_IMAGES[@]}
PROGRESS_START=41
PROGRESS_END=62
if [ $TOTAL_IMAGES -gt 0 ]; then
    PROGRESS_PER_IMAGE=$(( (PROGRESS_END - PROGRESS_START) / TOTAL_IMAGES ))
else
    PROGRESS_PER_IMAGE=0
fi
CURRENT_PROGRESS=$PROGRESS_START
IMAGE_COUNT=0

# Install pigz for parallel compression if not available
if ! command -v pigz &> /dev/null; then
    log "Installing pigz for faster compression..."
    sudo apt-get update -qq && sudo apt-get install -y pigz >/dev/null 2>&1
fi

# Function to download a single Docker image
download_docker_image() {
    local image="$1"
    local filename=$(echo "$image" | sed 's/[\/:]/_/g')
    local local_file="$DOCKER_DIR/${filename}.tar.gz"
    local gcs_filename="docker-images/${filename}.tar.gz"

    # Check if already exists locally
    if [ -f "$local_file" ]; then
        echo "[INFO] ✓ $image (exists locally)"
        return 0
    fi

    # Check if exists in GCS
    if [ "$GCS_ENABLED" = true ] && gsutil -q stat "$GCS_BUCKET/$gcs_filename" 2>/dev/null; then
        echo "[INFO] Downloading $image from GCS..."
        if gsutil -m cp "$GCS_BUCKET/$gcs_filename" "$local_file" 2>/dev/null; then
            echo "[SUCCESS] ✓ $image (from GCS)"
            return 0
        fi
    fi

    # Download from Docker Hub
    echo "[INFO] Pulling $image from Docker Hub..."
    if sudo docker pull "$image" 2>&1 | grep -q "Downloaded\|up to date"; then
        echo "[INFO] Saving $image..."
        # Use pigz with all available cores for maximum speed
        sudo docker save "$image" | pigz -p $(nproc) > "$local_file"
        echo "[SUCCESS] ✓ $image (downloaded and saved)"

        # Upload to GCS cache for future builds (run in background)
        if [ "$GCS_ENABLED" = true ]; then
            (
                if gsutil -m cp "$local_file" "$GCS_BUCKET/$gcs_filename" 2>/dev/null; then
                    echo "[INFO] ✓ Cached $image in GCS for future builds"
                fi
            ) &
        fi
        return 0
    else
        echo "[ERROR] Failed to download $image"
        return 1
    fi
}

export -f download_docker_image
export DOCKER_DIR
export GCS_ENABLED
export GCS_BUCKET

# Parallel download with GNU parallel
# Automatically adjust based on CPU cores (use 25% of cores, max 12 for optimal network/disk balance)
PARALLEL_JOBS=$(( $(nproc) / 4 ))
if [ $PARALLEL_JOBS -lt 4 ]; then
    PARALLEL_JOBS=4
fi
if [ $PARALLEL_JOBS -gt 12 ]; then
    PARALLEL_JOBS=12
fi
log "Using $PARALLEL_JOBS parallel downloads ($(nproc) CPU cores available)"

# Check if GNU parallel is available, install if not
if ! command -v parallel &> /dev/null; then
    log "Installing GNU parallel for faster downloads..."
    sudo apt-get update -qq && sudo apt-get install -y parallel >/dev/null 2>&1
fi

log "Downloading images in parallel (${PARALLEL_JOBS} concurrent)..."
write_status "downloading-images" 41 "Downloading ${TOTAL_IMAGES} Docker images in parallel"

# Download all images in parallel, showing progress
printf "%s\n" "${DOCKER_IMAGES[@]}" | parallel -j "$PARALLEL_JOBS" --line-buffer download_docker_image {}

# Update progress to completion
write_status "downloading-images" 62 "All Docker images downloaded"
success "✓ All Docker images ready (downloaded in parallel)"

# ========================================
# Step 2: Download Ollama Models
# ========================================

if [ ${#MODELS[@]} -gt 0 ]; then
    header "Step 2: Downloading Selected Ollama Models"

    TOTAL_MODELS=${#MODELS[@]}

    # Function to download a single Ollama model
    download_ollama_model() {
        local model="$1"
        local model_filename=$(echo "$model" | sed 's/[\/:]/_/g')
        local model_tar_file="$MODELS_DIR/${model_filename}.tar.gz"
        local model_gcs_filename="ollama-models/${model_filename}.tar.gz"

        # Check if already exists
        if [ -f "$model_tar_file" ]; then
            echo "[INFO] ✓ $model (exists locally)"
            return 0
        fi

        # Check if exists in GCS
        if [ "$GCS_ENABLED" = true ] && gsutil -q stat "$GCS_BUCKET/$model_gcs_filename" 2>/dev/null; then
            echo "[INFO] Downloading $model from GCS..."
            if gsutil -m cp "$GCS_BUCKET/$model_gcs_filename" "$model_tar_file" 2>/dev/null; then
                echo "[SUCCESS] ✓ $model (from GCS)"
                return 0
            fi
        fi

        # Download model
        echo "[INFO] Downloading Ollama model: $model (this may take a while)"

        local container_name="ollama-temp-${model_filename}-$$"
        local volume_name="ollama-temp-${model_filename}-$$"

        # Run Ollama container
        if sudo docker run -d --name "$container_name" -v "$volume_name":/root/.ollama ollama/ollama:0.12.9 >/dev/null 2>&1; then
            sleep 5

            if sudo docker exec "$container_name" ollama pull "$model" 2>&1 | tail -5; then
                echo "[SUCCESS] ✓ Downloaded: $model"

                echo "[INFO] Exporting model to tar file..."
                # Use pigz for faster compression
                sudo docker run --rm -v "$volume_name":/models alpine \
                    sh -c "cd /models && tar cf - ." | pigz -p $(nproc) > "$model_tar_file"

                echo "[SUCCESS] ✓ Exported: $model"

                # Upload to GCS cache for future builds (run in background)
                if [ "$GCS_ENABLED" = true ] && [ -f "$model_tar_file" ]; then
                    (
                        if gsutil -m cp "$model_tar_file" "$GCS_BUCKET/$model_gcs_filename" 2>/dev/null; then
                            echo "[INFO] ✓ Cached $model in GCS for future builds"
                        fi
                    ) &
                fi

                # Cleanup
                sudo docker stop "$container_name" >/dev/null 2>&1 || true
                sudo docker rm "$container_name" >/dev/null 2>&1 || true
                sudo docker volume rm "$volume_name" >/dev/null 2>&1 || true
                return 0
            else
                echo "[ERROR] Failed to download: $model"
                # Cleanup
                sudo docker stop "$container_name" >/dev/null 2>&1 || true
                sudo docker rm "$container_name" >/dev/null 2>&1 || true
                sudo docker volume rm "$volume_name" >/dev/null 2>&1 || true
                return 1
            fi
        else
            echo "[ERROR] Failed to start container for: $model"
            return 1
        fi
    }

    export -f download_ollama_model
    export MODELS_DIR

    # Download models in parallel
    # Ollama models are very large, so we use fewer parallel jobs (2-4 concurrent)
    # Adjust based on number of models and available CPU
    if [ $TOTAL_MODELS -eq 1 ]; then
        MODEL_PARALLEL_JOBS=1
    elif [ $TOTAL_MODELS -eq 2 ]; then
        MODEL_PARALLEL_JOBS=2
    elif [ $(nproc) -ge 32 ]; then
        # High-CPU VMs can handle 4 concurrent model downloads
        MODEL_PARALLEL_JOBS=4
    else
        MODEL_PARALLEL_JOBS=3
    fi

    log "Downloading Ollama models in parallel (${MODEL_PARALLEL_JOBS} concurrent)..."
    write_status "downloading-models" 63 "Downloading ${TOTAL_MODELS} Ollama models in parallel"

    # Download all models in parallel
    printf "%s\n" "${MODELS[@]}" | parallel -j "$MODEL_PARALLEL_JOBS" --line-buffer download_ollama_model {}

    write_status "downloading-models" 66 "All Ollama models downloaded"
    success "✓ All Ollama models ready (downloaded in parallel)"
else
    write_status "downloading-models" 63 "No Ollama models selected, skipping"
    log "No Ollama models selected, skipping model download"
fi

# ========================================
# Wait for GCS Cache Uploads
# ========================================

# Wait for any background GCS upload jobs to complete
# This ensures artifacts are cached before the VM shuts down
if [ "$GCS_ENABLED" = true ]; then
    BACKGROUND_JOBS=$(jobs -r | wc -l)
    if [ "$BACKGROUND_JOBS" -gt 0 ]; then
        log "Waiting for $BACKGROUND_JOBS background cache upload(s) to complete..."
        wait
        success "✓ All cache uploads completed"
    fi
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

write_status "preparation-complete" 66 "All dependencies downloaded, ready for ISO build"
success "✓ Ready for ISO building"
log "Next step: Run create-custom-iso.sh to build the ISO"
