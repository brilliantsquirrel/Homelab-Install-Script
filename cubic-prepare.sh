#!/bin/bash

# Cubic ISO Preparation Script
# Downloads all large dependencies for inclusion in custom Ubuntu ISO
# Usage: Run this script to download Docker images and Ollama models
#        Then copy the generated artifacts to your Cubic ISO

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

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    error "Please run this script as a regular user with sudo privileges, not as root"
    exit 1
fi

header "Cubic ISO Preparation - Homelab Dependencies"

log "This script will download all large dependencies for offline installation"
log "Total download size: ~50-100GB depending on selected models"
echo ""

# Create output directory structure
CUBIC_DIR="$(pwd)/cubic-artifacts"
DOCKER_DIR="$CUBIC_DIR/docker-images"
MODELS_DIR="$CUBIC_DIR/ollama-models"
SCRIPTS_DIR="$CUBIC_DIR/scripts"

log "Creating directory structure..."
mkdir -p "$DOCKER_DIR"
mkdir -p "$MODELS_DIR"
mkdir -p "$SCRIPTS_DIR"

success "✓ Created: $CUBIC_DIR"

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
DOCKER_IMAGES=(
    "ollama/ollama:latest"
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
echo ""

# Ask user for confirmation
read -p "Download all Docker images (~20-30GB)? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    warning "Skipping Docker image download"
else
    for image in "${DOCKER_IMAGES[@]}"; do
        log "Pulling: $image"
        if sudo docker pull "$image"; then
            success "✓ Pulled: $image"

            # Save image to tar file
            local filename=$(echo "$image" | sed 's/[\/:]/_/g')
            log "Saving to: $DOCKER_DIR/${filename}.tar"

            if sudo docker save "$image" | gzip > "$DOCKER_DIR/${filename}.tar.gz"; then
                success "✓ Saved: ${filename}.tar.gz"
            else
                error "Failed to save: $image"
            fi
        else
            error "Failed to pull: $image"
        fi
        echo ""
    done

    # Build custom nginx image
    log "Building custom nginx image..."
    if [ -d "nginx" ] && [ -f "nginx/Dockerfile" ]; then
        if sudo docker build -t homelab-install-script-nginx:latest nginx/; then
            success "✓ Built custom nginx image"

            log "Saving custom nginx image..."
            if sudo docker save homelab-install-script-nginx:latest | gzip > "$DOCKER_DIR/homelab-install-script-nginx_latest.tar.gz"; then
                success "✓ Saved: homelab-install-script-nginx_latest.tar.gz"
            fi
        else
            warning "Failed to build custom nginx image"
        fi
    else
        warning "nginx directory not found, skipping custom image"
    fi

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

log "Found ${#OLLAMA_MODELS[@]} Ollama models to download"
log "WARNING: This will download 50-80GB of model data"
echo ""

read -p "Download all Ollama models (50-80GB, may take hours)? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    warning "Skipping Ollama model download"
else
    # Check if Ollama container is running, start if needed
    if ! sudo docker ps | grep -q ollama; then
        log "Starting Ollama container for model downloads..."
        sudo docker run -d --name ollama-temp -v ollama-models:/root/.ollama ollama/ollama:latest
        sleep 5
    else
        log "Using existing Ollama container"
    fi

    for model in "${OLLAMA_MODELS[@]}"; do
        log "Downloading model: $model (this may take a long time)"
        log "Press Ctrl+C to skip this model and continue with the next one"

        if sudo docker exec ollama-temp ollama pull "$model"; then
            success "✓ Downloaded: $model"
        else
            warning "Failed to download: $model"
        fi
        echo ""
    done

    # Export models from Docker volume
    log "Exporting models from Docker volume..."

    # Create a temporary container to copy models from volume
    sudo docker run --rm -v ollama-models:/models -v "$MODELS_DIR":/backup alpine \
        sh -c "cd /models && tar czf /backup/ollama-models.tar.gz ."

    if [ -f "$MODELS_DIR/ollama-models.tar.gz" ]; then
        local size=$(du -h "$MODELS_DIR/ollama-models.tar.gz" | cut -f1)
        success "✓ Exported models: ollama-models.tar.gz ($size)"
    else
        error "Failed to export models"
    fi

    # Clean up temporary container
    if sudo docker ps -a | grep -q ollama-temp; then
        sudo docker stop ollama-temp 2>/dev/null || true
        sudo docker rm ollama-temp 2>/dev/null || true
    fi

    # Clean up temporary volume
    read -p "Remove temporary Ollama volume? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo docker volume rm ollama-models 2>/dev/null || true
        log "Cleaned up temporary volume"
    fi
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

# Create README for Cubic integration
cat > "$CUBIC_DIR/README.md" << 'EOF'
# Homelab Cubic ISO Integration

This directory contains all pre-downloaded dependencies for offline homelab installation.

## Directory Structure

```
cubic-artifacts/
├── docker-images/          # Docker images as .tar.gz files
├── ollama-models/          # Ollama models as .tar.gz file
├── scripts/                # Installation scripts
│   ├── load-docker-images.sh
│   ├── load-ollama-models.sh
│   └── install-offline.sh
└── README.md              # This file
```

## Integration with Cubic

### 1. Copy to ISO

In Cubic, copy this entire `cubic-artifacts` directory to your custom ISO:

```bash
# In Cubic chroot environment
mkdir -p /opt/homelab-offline
cp -r /path/to/cubic-artifacts/* /opt/homelab-offline/
```

### 2. Copy Homelab Scripts

Copy the main homelab repository to the ISO:

```bash
# In Cubic chroot environment
mkdir -p /opt/homelab
cp -r /path/to/Homelab-Install-Script/* /opt/homelab/
```

### 3. Create Desktop Shortcut (Optional)

```bash
# In Cubic chroot environment
cat > /home/ubuntu/Desktop/install-homelab.desktop << 'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Install Homelab (Offline)
Comment=Install homelab with pre-downloaded dependencies
Exec=gnome-terminal -- bash -c "cd /opt/homelab && /opt/homelab-offline/scripts/install-offline.sh; read -p 'Press Enter to close...'"
Icon=system-run
Terminal=true
Categories=System;
DESKTOP

chmod +x /home/ubuntu/Desktop/install-homelab.desktop
```

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

- **Docker Images**: ~20-30 GB
- **Ollama Models**: ~50-80 GB
- **Total**: ~70-110 GB

Ensure your ISO has sufficient space for these artifacts.

## Updating Dependencies

To update the offline artifacts, run `cubic-prepare.sh` again on a system
with internet access, then replace the contents of `cubic-artifacts/`.

## Verification

After running `cubic-prepare.sh`, verify:

```bash
# Check Docker images
ls -lh cubic-artifacts/docker-images/

# Check Ollama models
ls -lh cubic-artifacts/ollama-models/

# Check scripts
ls -lh cubic-artifacts/scripts/
```

All files should be present and have reasonable sizes.
EOF

success "✓ Created: README.md"

# ========================================
# Summary
# ========================================

header "Preparation Complete!"

echo "Artifacts saved to: $CUBIC_DIR"
echo ""
echo "Directory contents:"
echo "  - docker-images/     : $(ls -1 "$DOCKER_DIR" 2>/dev/null | wc -l) Docker image tar files"
echo "  - ollama-models/     : $(ls -1 "$MODELS_DIR" 2>/dev/null | wc -l) Ollama model archives"
echo "  - scripts/           : 3 installation scripts"
echo "  - README.md          : Integration instructions"
echo ""

# Calculate total size
if command -v du &> /dev/null; then
    TOTAL_SIZE=$(du -sh "$CUBIC_DIR" | cut -f1)
    log "Total size: $TOTAL_SIZE"
fi

echo ""
success "✓ Ready for Cubic ISO integration"
echo ""
log "Next steps:"
echo "  1. Copy cubic-artifacts/ to your Cubic ISO project"
echo "  2. Follow instructions in cubic-artifacts/README.md"
echo "  3. Build your custom ISO with Cubic"
echo ""
log "See CUBIC.md for detailed integration guide"
