#!/bin/bash

# ISO Preparation Script
# Downloads all large dependencies and creates an ISO build artifacts directory
# Usage: Run this script, then run create-custom-iso.sh to build the ISO
#
# This script creates iso-artifacts/ which contains:
# - The download location for Docker images and models
# - The homelab scripts and configuration files
# - The Ubuntu Server ISO

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions - use stdout for clean sequential output
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

# Performance configuration
MAX_PARALLEL_DOWNLOADS=4  # Number of parallel Docker image downloads

# Process a single Docker image (pull, compress, upload)
# Runs in background, output suppressed to avoid jumbled display
process_docker_image() {
    local image="$1"
    local filename=$(echo "$image" | sed 's/[\/:]/_/g')
    local local_file="$DOCKER_DIR/${filename}.tar.gz"
    local gcs_filename="docker-images/${filename}.tar.gz"
    local status_file="/tmp/docker_status_$$_${filename}"

    # Check if file exists locally
    if [ -f "$local_file" ]; then
        echo "EXISTS:$image" > "$status_file"
        return 0
    fi

    local needs_update=false
    local gcs_exists=false

    # Check if file exists in GCS bucket
    if [ "$GCS_ENABLED" = true ] && check_gcs_file "$gcs_filename" 2>/dev/null; then
        gcs_exists=true

        # Pull latest version from Docker Hub to check for updates
        if sudo docker pull "$image" >/dev/null 2>&1; then
            local latest_digest=$(sudo docker inspect --format='{{.Id}}' "$image" 2>/dev/null)

            # Download and load the GCS version to compare
            local temp_file="/tmp/${filename}_gcs.tar.gz"
            if download_from_gcs "$gcs_filename" "$temp_file" >/dev/null 2>&1; then
                # Load the GCS image with a temporary tag to compare
                if gunzip -c "$temp_file" | sudo docker load >/dev/null 2>&1; then
                    # Get the digest of the loaded image
                    local gcs_digest=$(sudo docker inspect --format='{{.Id}}' "$image" 2>/dev/null)

                    # Compare digests
                    if [ "$latest_digest" != "$gcs_digest" ]; then
                        needs_update=true
                        sudo rm -f "$temp_file"
                    else
                        # Same version, use the GCS file
                        mv "$temp_file" "$local_file"
                        echo "GCS:$image" > "$status_file"
                        return 0
                    fi
                else
                    # Failed to load GCS file, need to update
                    needs_update=true
                    sudo rm -f "$temp_file"
                fi
            else
                # Failed to download GCS file, need to update
                needs_update=true
            fi
        else
            # Failed to pull latest, try using GCS version
            if download_from_gcs "$gcs_filename" "$local_file" >/dev/null 2>&1; then
                if gunzip -c "$local_file" | sudo docker load >/dev/null 2>&1; then
                    echo "GCS:$image" > "$status_file"
                    return 0
                fi
            fi
            echo "FAILED:$image" > "$status_file"
            return 1
        fi
    else
        # No GCS file exists, pull from Docker Hub
        if ! sudo docker pull "$image" >/dev/null 2>&1; then
            echo "FAILED:$image" > "$status_file"
            return 1
        fi
    fi

    # Save image to tar file with parallel compression
    if command -v pigz &> /dev/null; then
        sudo docker save "$image" | pigz -p 2 > "$local_file" 2>/dev/null
    else
        sudo docker save "$image" | gzip > "$local_file" 2>/dev/null
    fi

    if [ ! -f "$local_file" ]; then
        echo "FAILED:$image" > "$status_file"
        return 1
    fi

    # Upload to GCS bucket (replacing old version if exists)
    if [ "$GCS_ENABLED" = true ]; then
        if gsutil -m -o GSUtil:parallel_composite_upload_threshold=150M cp "$local_file" "$GCS_BUCKET/$gcs_filename" >/dev/null 2>&1; then
            if check_gcs_file "$gcs_filename" 2>/dev/null; then
                rm -f "$local_file"
                if [ "$needs_update" = true ]; then
                    echo "UPDATED:$image" > "$status_file"
                else
                    echo "UPLOADED:$image" > "$status_file"
                fi
            else
                echo "LOCAL:$image" > "$status_file"
            fi
        else
            echo "LOCAL:$image" > "$status_file"
        fi
    else
        echo "LOCAL:$image" > "$status_file"
    fi

    return 0
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    error "Please run this script as a regular user with sudo privileges, not as root"
    exit 1
fi

# Get the repository root directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

header "ISO Preparation - Homelab Dependencies"

log "This script will:"
log "  1. Create iso-artifacts/ directory for ISO building"
log "  2. Copy all homelab scripts into iso-artifacts/homelab/"
log "  3. Download Ubuntu Server 24.04 LTS ISO (~2.5GB)"
log "  4. Download Docker images (~20-30GB)"
log "  5. Download Ollama models (~50-80GB)"
log ""
log "Total download size: ~52-102GB depending on selected models"
echo ""

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

success "✓ Created: $ISO_DIR (this will be your ISO build directory)"

# ========================================
# Google Cloud Storage Configuration
# ========================================

# GCS bucket for storing large artifacts
# Try to get bucket name from GCloud VM metadata, fallback to environment variable

# First, try GCloud VM metadata
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
    GCS_BUCKET=""
    log "✗ No GCS bucket configured (neither VM metadata nor GCS_BUCKET env var)"
fi

# Check if gsutil is available
check_gcs_available() {
    # Check if GCS_BUCKET is set
    if [ -z "$GCS_BUCKET" ]; then
        return 1
    fi

    if command -v gsutil &> /dev/null; then
        if gsutil ls "$GCS_BUCKET" &> /dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

# Check if file exists in GCS bucket
check_gcs_file() {
    local filename="$1"
    if check_gcs_available; then
        if gsutil -q stat "$GCS_BUCKET/$filename"; then
            return 0
        fi
    fi
    return 1
}

# Download file from GCS bucket
download_from_gcs() {
    local filename="$1"
    local destination="$2"

    log "Downloading from GCS bucket: $filename"
    if gsutil cp "$GCS_BUCKET/$filename" "$destination"; then
        success "✓ Downloaded from GCS: $filename"
        return 0
    else
        error "Failed to download from GCS: $filename"
        return 1
    fi
}

# Upload file to GCS bucket
upload_to_gcs() {
    local filepath="$1"
    local destination="${2:-$(basename "$filepath")}"  # Optional destination path in bucket

    if ! check_gcs_available; then
        warning "GCS not available, skipping upload: $(basename "$filepath")"
        return 1
    fi

    log "Uploading to GCS bucket: $destination"
    # Use parallel composite uploads for files larger than 150MB
    if gsutil -m -o GSUtil:parallel_composite_upload_threshold=150M cp "$filepath" "$GCS_BUCKET/$destination"; then
        success "✓ Uploaded to GCS: $destination"
        return 0
    else
        error "Failed to upload to GCS: $destination"
        return 1
    fi
}

# Check GCS availability at startup
echo ""
log "Checking GCS bucket configuration..."

if check_gcs_available; then
    success "✓ GCS bucket accessible: $GCS_BUCKET"
    log "Files will be uploaded to GCS and local copies will be removed to save disk space"
    GCS_ENABLED=true
else
    if [ -z "$GCS_BUCKET" ]; then
        error "✗ GCS bucket not configured - files will only be stored locally"
        log "To enable GCS: set GCS_BUCKET environment variable or run on GCloud VM"
        log "Detected environment: GCS_BUCKET='$GCS_BUCKET'"
    elif ! command -v gsutil &> /dev/null; then
        error "✗ gsutil not found - files will only be stored locally"
        log "To enable GCS: install gcloud CLI (https://cloud.google.com/sdk/docs/install)"
    else
        error "✗ GCS bucket $GCS_BUCKET not accessible - files will only be stored locally"
        log "Verify bucket exists and you have access: gsutil ls $GCS_BUCKET"

        # Try to get more details about the error
        log "Testing bucket access..."
        if gsutil ls "$GCS_BUCKET" 2>&1 | head -5; then
            warning "Bucket access test completed (see output above)"
        fi
    fi
    GCS_ENABLED=false

    warning "⚠ IMPORTANT: GCS is NOT enabled - all files will remain on local disk!"
    warning "⚠ This will use ~70-110GB of disk space on this machine!"
fi
echo ""

# Copy homelab scripts to iso-artifacts/homelab/
header "Copying Homelab Scripts"

log "Copying all homelab files to iso-artifacts/homelab/..."
# Note: --no-times --no-perms are needed for gcsfuse-mounted filesystems
rsync -rlv --no-times --no-perms --exclude='iso-artifacts' --exclude='.git' "$REPO_DIR/" "$HOMELAB_DIR/" || {
    warning "⚠ rsync reported errors (this is expected on gcsfuse filesystems)"
    log "Files were copied successfully despite timestamp/permission warnings"
}

success "✓ Copied homelab scripts to: $HOMELAB_DIR"

# ========================================
# Step 0: Download Ubuntu Server ISO
# ========================================

header "Step 0: Downloading Ubuntu Server 24.04 LTS ISO"

UBUNTU_VERSION="24.04.3"
UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_FILE="$ISO_DIR/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_GCS="iso/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

# Check if ISO already exists locally
if [ -f "$UBUNTU_ISO_FILE" ]; then
    existing_size=$(du -h "$UBUNTU_ISO_FILE" | cut -f1)
    log "Ubuntu Server ISO already downloaded: $(basename $UBUNTU_ISO_FILE) ($existing_size)"
    success "✓ Skipping ISO download (already exists locally)"
    echo ""
elif [ "$GCS_ENABLED" = true ] && check_gcs_file "$UBUNTU_ISO_GCS"; then
    # Check if ISO exists in GCS bucket
    log "Ubuntu Server ISO found in GCS bucket"
    if download_from_gcs "$UBUNTU_ISO_GCS" "$UBUNTU_ISO_FILE"; then
        existing_size=$(du -h "$UBUNTU_ISO_FILE" | cut -f1)
        success "✓ Retrieved Ubuntu ISO from GCS ($existing_size)"
        echo ""
    else
        warning "Failed to download from GCS, will download from Ubuntu releases"
    fi
fi

# If ISO still doesn't exist, download it
if [ ! -f "$UBUNTU_ISO_FILE" ]; then
    log "Downloading Ubuntu Server 24.04 LTS ISO (~2.5GB)"
    log "Source: $UBUNTU_ISO_URL"
    log "Downloading ISO (this may take several minutes)..."
    echo ""

    # Download with wget (shows progress bar) or curl as fallback
    if command -v wget &> /dev/null; then
        wget -O "$UBUNTU_ISO_FILE" "$UBUNTU_ISO_URL" || {
            error "Failed to download Ubuntu ISO"
            rm -f "$UBUNTU_ISO_FILE"
            exit 1
        }
    elif command -v curl &> /dev/null; then
        curl -L -o "$UBUNTU_ISO_FILE" "$UBUNTU_ISO_URL" || {
            error "Failed to download Ubuntu ISO"
            rm -f "$UBUNTU_ISO_FILE"
            exit 1
        }
    else
        error "Neither wget nor curl is available"
        error "Please install wget: sudo apt-get install wget"
        exit 1
    fi

    # Verify download completed
    if [ -f "$UBUNTU_ISO_FILE" ]; then
        iso_size=$(du -h "$UBUNTU_ISO_FILE" | cut -f1)
        success "✓ Downloaded: $(basename $UBUNTU_ISO_FILE) ($iso_size)"
        log "ISO location: $UBUNTU_ISO_FILE"

        # Upload to GCS bucket (keep local copy for ISO building)
        if [ "$GCS_ENABLED" = true ]; then
            if upload_to_gcs "$UBUNTU_ISO_FILE" "$UBUNTU_ISO_GCS"; then
                # Verify the upload succeeded
                if check_gcs_file "$UBUNTU_ISO_GCS"; then
                    log "Verifying GCS upload..."
                    success "✓ Verified: ISO exists in GCS bucket"
                    log "Keeping local copy for ISO building"
                    success "✓ ISO available both locally and in GCS"
                else
                    warning "Upload verification failed, but local copy available"
                fi
            else
                warning "Failed to upload to GCS, but local copy available"
            fi
        fi
    else
        error "ISO download failed"
        exit 1
    fi
    echo ""
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Please install Docker first:"
    error "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# Check if Docker daemon is running
if ! sudo docker info &> /dev/null; then
    error "Docker daemon is not running. Please start Docker:"
    error "  sudo systemctl start docker"
    exit 1
fi

success "✓ Docker is available"

# ========================================
# Step 1: Pull and Save Docker Images
# ========================================

header "Step 1: Downloading Docker Images"

# List of Docker images from docker-compose.yml
# Note: Using Ollama 0.12.9 for qwen3-vl:8b support (released Nov 2025)
DOCKER_IMAGES=(
    "ollama/ollama:0.12.9"
    "ghcr.io/open-webui/open-webui:main"
    "langchain/langserve:latest"
    "langchain/langgraph-api:3.11"
    "postgres:16-alpine"
    "redis:7-alpine"
    "langflowai/langflow:latest"
    "n8nio/n8n:latest"
    "qdrant/qdrant:latest"
    "ghcr.io/ajnart/homarr:latest"
    "ghcr.io/hoarder-app/hoarder:latest"
    "plexinc/pms-docker:latest"
    "nextcloud:latest"
    "pihole/pihole:latest"
    "portainer/portainer-ce:latest"
    "tecnativa/docker-socket-proxy:latest"
)

# Custom nginx image (needs to be built first)
CUSTOM_IMAGES=(
    "homelab-install-script-nginx:latest"
)

log "Found ${#DOCKER_IMAGES[@]} Docker images to download"
log "Processing images with $MAX_PARALLEL_DOWNLOADS parallel downloads (output suppressed)..."
echo ""

# Track which images are being processed
declare -a processing_images=()

# Process images in parallel with job control
for image in "${DOCKER_IMAGES[@]}"; do
    processing_images+=("$image")
    # Launch processing in background
    process_docker_image "$image" &

    # Limit concurrent jobs
    while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_DOWNLOADS ]; do
        sleep 2
    done
done

# Wait for all background jobs to complete
log "Waiting for all downloads to complete..."
wait

# Display results
echo ""
log "Results:"
for image in "${processing_images[@]}"; do
    filename=$(echo "$image" | sed 's/[\/:]/_/g')
    status_file="/tmp/docker_status_$$_${filename}"

    if [ -f "$status_file" ]; then
        status=$(cat "$status_file")
        case "${status%%:*}" in
            EXISTS)
                echo "  ${GREEN}✓${NC} $image (already exists)"
                ;;
            GCS)
                echo "  ${GREEN}✓${NC} $image (loaded from GCS)"
                ;;
            UPLOADED)
                echo "  ${GREEN}✓${NC} $image (uploaded to GCS)"
                ;;
            UPDATED)
                echo "  ${GREEN}✓${NC} $image (updated from outdated version)"
                ;;
            LOCAL)
                echo "  ${GREEN}✓${NC} $image (saved locally)"
                ;;
            FAILED)
                echo "  ${RED}✗${NC} $image (failed)"
                ;;
        esac
        rm -f "$status_file"
    else
        echo "  ${YELLOW}?${NC} $image (status unknown)"
    fi
done

echo ""
success "✓ All Docker images processed"

# Build custom nginx image
log "Building custom nginx image..."
nginx_filename="homelab-install-script-nginx_latest"
nginx_local_file="$DOCKER_DIR/${nginx_filename}.tar.gz"
nginx_gcs_filename="docker-images/${nginx_filename}.tar.gz"

# Check if nginx image exists locally or in GCS
nginx_exists=false
if [ -f "$nginx_local_file" ]; then
    log "Custom nginx image already exists locally"
    nginx_exists=true
elif [ "$GCS_ENABLED" = true ] && check_gcs_file "$nginx_gcs_filename"; then
    log "Custom nginx image found in GCS bucket"
    if download_from_gcs "$nginx_gcs_filename" "$nginx_local_file"; then
        if gunzip -c "$nginx_local_file" | sudo docker load; then
            success "✓ Loaded custom nginx from GCS"
            nginx_exists=true
        fi
    fi
fi

if [ "$nginx_exists" = false ]; then
    if [ -d "$REPO_DIR/nginx" ] && [ -f "$REPO_DIR/nginx/Dockerfile" ]; then
        if sudo docker build -t homelab-install-script-nginx:latest "$REPO_DIR/nginx/"; then
            success "✓ Built custom nginx image"

            log "Saving custom nginx image..."
            # Use pigz if available, otherwise fall back to gzip
            if command -v pigz &> /dev/null; then
                if sudo docker save homelab-install-script-nginx:latest | pigz -p 8 > "$nginx_local_file"; then
                    success "✓ Saved: ${nginx_filename}.tar.gz (compressed with pigz)"
                else
                    error "Failed to save nginx image"
                fi
            else
                if sudo docker save homelab-install-script-nginx:latest | gzip > "$nginx_local_file"; then
                    success "✓ Saved: ${nginx_filename}.tar.gz"
                else
                    error "Failed to save nginx image"
                fi
            fi

            # Upload to GCS bucket and delete local copy after verification
            if [ "$GCS_ENABLED" = true ] && [ -f "$nginx_local_file" ]; then
                log "Uploading to GCS (parallel mode)..."
                if gsutil -m -o GSUtil:parallel_composite_upload_threshold=150M cp "$nginx_local_file" "$GCS_BUCKET/$nginx_gcs_filename"; then
                    # Verify the upload succeeded
                    if check_gcs_file "$nginx_gcs_filename"; then
                        log "Verifying GCS upload..."
                        success "✓ Verified: ${nginx_filename}.tar.gz exists in GCS bucket"
                        log "Removing local copy (now in GCS bucket)..."
                        rm -f "$nginx_local_file"
                        success "✓ Cleaned up local tar file"
                    else
                        warning "Upload verification failed, keeping local copy"
                    fi
                else
                    warning "Failed to upload to GCS, keeping local copy"
                fi
            fi
        else
            warning "Failed to build custom nginx image"
        fi
    else
        warning "nginx directory not found, skipping custom image"
    fi
fi

if [ "$GCS_ENABLED" = true ]; then
    success "✓ All Docker images uploaded to GCS: $GCS_BUCKET/docker-images/"
    log "Local files cleaned up to save disk space"
else
    success "✓ All Docker images saved to: $DOCKER_DIR"
fi

# ========================================
# Step 2: Download Ollama Models
# ========================================

header "Step 2: Downloading Ollama Models"

OLLAMA_MODELS=(
    "gpt-oss:20b"
    "qwen3-vl:8b"
    "qwen3-coder:30b"
    "qwen3:8b"
)

# Process each model individually to save disk space
# Key optimization: Use a fresh volume for each model, export immediately, then clean up
for model in "${OLLAMA_MODELS[@]}"; do
    # Create a safe filename from the model name
    model_filename=$(echo "$model" | sed 's/[\/:]/_/g')
    model_tar_file="$MODELS_DIR/${model_filename}.tar.gz"
    model_gcs_filename="ollama-models/${model_filename}.tar.gz"

    # Check if model already exists locally
    if [ -f "$model_tar_file" ]; then
        existing_size=$(du -h "$model_tar_file" | cut -f1)
        log "Model $model already downloaded: ${model_filename}.tar.gz ($existing_size)"
        success "✓ Skipping: $model (already exists locally)"
        echo ""
        continue
    fi

    # Check if model exists in GCS bucket
    if [ "$GCS_ENABLED" = true ] && check_gcs_file "$model_gcs_filename"; then
        log "Model $model found in GCS bucket"
        if download_from_gcs "$model_gcs_filename" "$model_tar_file"; then
            existing_size=$(du -h "$model_tar_file" | cut -f1)
            success "✓ Retrieved $model from GCS ($existing_size)"
            echo ""
            continue
        else
            warning "Failed to download from GCS, will download model fresh"
        fi
    fi

    # If model doesn't exist locally or in GCS, download it
    if [ ! -f "$model_tar_file" ]; then
        log "Downloading Ollama model: $model"

        # Create a unique container and volume name for this model
        container_name="ollama-temp-${model_filename}"
        volume_name="ollama-temp-${model_filename}"

        # Start fresh Ollama container with dedicated volume for this model
        log "Starting Ollama container for $model..."
        # Using Ollama 0.12.9 for qwen3-vl:8b support
        sudo docker run -d --name "$container_name" -v "$volume_name":/root/.ollama ollama/ollama:0.12.9
        sleep 5

        # Download the model
        log "Pulling model: $model (this may take a long time)"
        if sudo docker exec "$container_name" ollama pull "$model"; then
            success "✓ Downloaded: $model"
        else
            warning "Failed to download: $model, skipping"
            # Clean up failed container and volume
            sudo docker stop "$container_name" 2>/dev/null || true
            sudo docker rm "$container_name" 2>/dev/null || true
            sudo docker volume rm "$volume_name" 2>/dev/null || true
            echo ""
            continue
        fi

        # Export this specific model to a tar file
        log "Exporting $model from Docker volume..."

        # Create target directory if it doesn't exist
        # Note: Must create directory before Docker tries to mount it (gcsfuse compatibility)
        mkdir -p "$MODELS_DIR" 2>/dev/null || true

        # Pipe tar output to stdout and redirect to file to avoid Docker bind mount issues with gcsfuse
        # This approach works around Docker's inability to bind mount directories on gcsfuse filesystems
        log "Creating compressed archive..."
        sudo docker run --rm -v "$volume_name":/models alpine \
            sh -c "cd /models && tar czf - ." > "$model_tar_file"

        if [ -f "$model_tar_file" ]; then
            size=$(du -h "$model_tar_file" | cut -f1)
            success "✓ Exported: ${model_filename}.tar.gz ($size)"

            # Upload to GCS bucket and delete local copy after verification
            if [ "$GCS_ENABLED" = true ]; then
                log "Uploading to GCS (parallel mode)..."
                if gsutil -m -o GSUtil:parallel_composite_upload_threshold=150M cp "$model_tar_file" "$GCS_BUCKET/$model_gcs_filename"; then
                    # Verify the upload succeeded
                    if check_gcs_file "$model_gcs_filename"; then
                        log "Verifying GCS upload..."
                        success "✓ Verified: ${model_filename}.tar.gz exists in GCS bucket"
                        log "Removing local copy (now in GCS bucket)..."
                        rm -f "$model_tar_file"
                        success "✓ Cleaned up local tar file"
                    else
                        warning "Upload verification failed, keeping local copy"
                    fi
                else
                    warning "Failed to upload to GCS, keeping local copy"
                fi
            fi
        else
            error "Failed to export model: $model"
        fi

        # Clean up this model's container and volume immediately to save disk space
        log "Cleaning up container and volume for $model to save disk space..."
        sudo docker stop "$container_name" 2>/dev/null || true
        sudo docker rm "$container_name" 2>/dev/null || true
        sudo docker volume rm "$volume_name" 2>/dev/null || true
        success "✓ Cleaned up $model resources"

        echo ""
    fi
done

if [ "$GCS_ENABLED" = true ]; then
    success "✓ All Ollama models uploaded to GCS: $GCS_BUCKET/ollama-models/"
    log "Local files cleaned up to save disk space"
else
    success "✓ All Ollama models saved to: $MODELS_DIR"
fi

# ========================================
# Step 3: Create Offline Installation Scripts
# ========================================

header "Step 3: Creating Offline Installation Scripts"

# Create Docker image loader script
cat > "$SCRIPTS_DIR/load-docker-images.sh" << 'EOF'
#!/bin/bash
# Load Docker images from tar files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="$SCRIPT_DIR/../docker-images"

echo "[INFO] Loading Docker images from: $IMAGES_DIR"

if [ ! -d "$IMAGES_DIR" ]; then
    echo "[ERROR] Images directory not found: $IMAGES_DIR"
    exit 1
fi

for tarfile in "$IMAGES_DIR"/*.tar.gz; do
    if [ -f "$tarfile" ]; then
        echo "[INFO] Loading: $(basename $tarfile)"
        gunzip -c "$tarfile" | sudo docker load
        echo "[SUCCESS] Loaded: $(basename $tarfile)"
    fi
done

echo "[SUCCESS] All Docker images loaded"
sudo docker images
EOF

chmod +x "$SCRIPTS_DIR/load-docker-images.sh"
success "✓ Created: load-docker-images.sh"

# Create Ollama models loader script
cat > "$SCRIPTS_DIR/load-ollama-models.sh" << 'EOF'
#!/bin/bash
# Load Ollama models from tar file

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="$SCRIPT_DIR/../ollama-models/ollama-models.tar.gz"

echo "[INFO] Loading Ollama models from: $MODELS_FILE"

if [ ! -f "$MODELS_FILE" ]; then
    echo "[ERROR] Models file not found: $MODELS_FILE"
    exit 1
fi

# Check if Ollama container is running
if ! sudo docker ps | grep -q ollama; then
    echo "[ERROR] Ollama container is not running"
    echo "Please start containers first: sudo docker compose up -d"
    exit 1
fi

# Extract models into Ollama container
echo "[INFO] Extracting models into Ollama container..."
sudo docker run --rm \
    -v ollama_data:/root/.ollama \
    -v "$SCRIPT_DIR/../ollama-models":/backup \
    alpine \
    sh -c "cd /root/.ollama && tar xzf /backup/ollama-models.tar.gz"

echo "[SUCCESS] Ollama models loaded"
echo ""
echo "Verify models with: sudo docker exec ollama ollama list"
EOF

chmod +x "$SCRIPTS_DIR/load-ollama-models.sh"
success "✓ Created: load-ollama-models.sh"

# Create master installation script
cat > "$SCRIPTS_DIR/install-offline.sh" << 'EOF'
#!/bin/bash
# Offline Homelab Installation
# This script loads pre-downloaded Docker images and Ollama models

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Offline Homelab Installation"
echo "========================================="
echo ""

# Step 1: Load Docker images
echo "[INFO] Step 1: Loading Docker images..."
bash "$SCRIPT_DIR/load-docker-images.sh"
echo ""

# Step 2: Run main installation (will skip downloads)
echo "[INFO] Step 2: Running homelab installation..."
cd "$SCRIPT_DIR/../../"
export OFFLINE_MODE=true
bash post-install.sh
echo ""

# Step 3: Load Ollama models
echo "[INFO] Step 3: Loading Ollama models..."
bash "$SCRIPT_DIR/load-ollama-models.sh"
echo ""

echo "========================================="
echo "Offline Installation Complete!"
echo "========================================="
EOF

chmod +x "$SCRIPTS_DIR/install-offline.sh"
success "✓ Created: install-offline.sh"

# Create README for ISO building
cat > "$ISO_DIR/README.md" << 'EOF'
# Homelab ISO Build Artifacts Directory

**IMPORTANT**: This directory contains all files needed for ISO building!
Run create-custom-iso.sh from the repository root to build the custom ISO.

## Directory Structure

```
iso-artifacts/
├── ubuntu-24.04.3-live-server-amd64.iso  # Ubuntu Server ISO
├── homelab/                  # All homelab installation scripts
│   ├── post-install.sh
│   ├── docker-compose.yml
│   ├── lib/
│   ├── nginx/
│   └── ... (all homelab files)
├── docker-images/            # Pre-downloaded Docker images (.tar.gz)
├── ollama-models/            # Pre-downloaded Ollama models (.tar.gz)
├── scripts/                  # Offline installation scripts
│   ├── load-docker-images.sh
│   ├── load-ollama-models.sh
│   └── install-offline.sh
└── README.md                 # This file
```

## How to Build Custom ISO

### Step 1: Prepare Dependencies

Run this script to download all dependencies:

```bash
./iso-prepare.sh
```

This downloads Ubuntu ISO, Docker images, and Ollama models into iso-artifacts/.

### Step 2: Build the Custom ISO

Run the ISO builder script:

```bash
./create-custom-iso.sh
```

This will:
1. Extract the Ubuntu Server ISO
2. Modify the squashfs filesystem
3. Copy all homelab files and dependencies
4. Repack into a new bootable ISO

The output will be: `iso-artifacts/ubuntu-24.04.3-homelab-amd64.iso`

## Manual Installation from ISO

After booting from the custom ISO:

### Option 1: Automatic (Recommended)

```bash
cd /opt/homelab
/opt/homelab-offline/scripts/install-offline.sh
```

### Option 2: Step-by-Step

```bash
# 1. Load Docker images
/opt/homelab-offline/scripts/load-docker-images.sh

# 2. Run main installation
cd /opt/homelab
./post-install.sh

# 3. Load Ollama models
/opt/homelab-offline/scripts/load-ollama-models.sh
```

## Disk Space Requirements

- **Ubuntu Server ISO**: ~2.5 GB
- **Docker Images**: ~20-30 GB
- **Ollama Models**: ~50-80 GB
- **Total**: ~72-112 GB

Ensure your system has sufficient space for these artifacts.

## Updating Dependencies

To update the offline artifacts, run `iso-prepare.sh` again on a system
with internet access. The script will automatically detect and update
outdated Docker images in the GCS bucket.

## Verification

After running `iso-prepare.sh`, verify:

```bash
# Check Docker images
ls -lh iso-artifacts/docker-images/

# Check Ollama models
ls -lh iso-artifacts/ollama-models/

# Check scripts
ls -lh iso-artifacts/scripts/
```

All files should be present and have reasonable sizes.
EOF

success "✓ Created: README.md"

# ========================================
# Summary
# ========================================

header "Preparation Complete!"

echo "ISO build directory: $ISO_DIR"
echo ""
echo "Directory contents:"
if [ -f "$UBUNTU_ISO_FILE" ]; then
    iso_size=$(du -h "$UBUNTU_ISO_FILE" | cut -f1)
    echo "  - $(basename $UBUNTU_ISO_FILE) : Ubuntu Server ISO ($iso_size)"
else
    echo "  - Ubuntu ISO         : NOT DOWNLOADED (you'll need to provide it)"
fi
echo "  - homelab/           : All homelab installation scripts"
echo "  - docker-images/     : $(ls -1 "$DOCKER_DIR" 2>/dev/null | wc -l) Docker image tar files"
echo "  - ollama-models/     : $(ls -1 "$MODELS_DIR" 2>/dev/null | wc -l) Ollama model archives"
echo "  - scripts/           : 3 offline installation scripts"
echo "  - README.md          : Integration instructions"
echo ""

# Calculate total size
if command -v du &> /dev/null; then
    TOTAL_SIZE=$(du -sh "$ISO_DIR" | cut -f1)
    log "Total size: $TOTAL_SIZE"
fi

echo ""
success "✓ Ready for ISO building"
echo ""
log "Next steps:"
echo ""
echo "  1. Build the custom ISO:"
echo "     $ ./create-custom-iso.sh"
echo ""
echo "  2. The output ISO will be created at:"
echo "     $ISO_DIR/ubuntu-24.04.3-homelab-amd64.iso"
echo ""
echo "  3. Write to USB or burn to DVD:"
echo "     $ sudo dd if=$ISO_DIR/ubuntu-24.04.3-homelab-amd64.iso of=/dev/sdX bs=4M status=progress"
echo ""
log "See README.md in iso-artifacts/ for detailed information"
