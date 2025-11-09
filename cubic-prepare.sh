#!/bin/bash

# Cubic ISO Preparation Script
# Downloads all large dependencies and creates a Cubic project directory
# Usage: Run this script, then launch Cubic pointing to cubic-artifacts/ as project directory
#
# This script creates cubic-artifacts/ which serves as BOTH:
# - The download location for Docker images and models
# - The Cubic project directory (point Cubic here!)

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

# Get the repository root directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

header "Cubic ISO Preparation - Homelab Dependencies"

log "This script will:"
log "  1. Create cubic-artifacts/ as your Cubic project directory"
log "  2. Copy all homelab scripts into cubic-artifacts/homelab/"
log "  3. Download Ubuntu Server 24.04 LTS ISO (~2.5GB)"
log "  4. Download Docker images (~20-30GB)"
log "  5. Download Ollama models (~50-80GB)"
log ""
log "Total download size: ~52-102GB depending on selected models"
echo ""

# Create output directory structure
CUBIC_DIR="$REPO_DIR/cubic-artifacts"
HOMELAB_DIR="$CUBIC_DIR/homelab"
DOCKER_DIR="$CUBIC_DIR/docker-images"
MODELS_DIR="$CUBIC_DIR/ollama-models"
SCRIPTS_DIR="$CUBIC_DIR/scripts"

log "Creating Cubic project directory structure..."
mkdir -p "$HOMELAB_DIR"
mkdir -p "$DOCKER_DIR"
mkdir -p "$MODELS_DIR"
mkdir -p "$SCRIPTS_DIR"

success "✓ Created: $CUBIC_DIR (this will be your Cubic project directory)"

# Copy homelab scripts to cubic-artifacts/homelab/
header "Copying Homelab Scripts"

log "Copying all homelab files to cubic-artifacts/homelab/..."
rsync -av --exclude='cubic-artifacts' --exclude='.git' "$REPO_DIR/" "$HOMELAB_DIR/"

success "✓ Copied homelab scripts to: $HOMELAB_DIR"

# ========================================
# Step 0: Download Ubuntu Server ISO
# ========================================

header "Step 0: Downloading Ubuntu Server 24.04 LTS ISO"

UBUNTU_VERSION="24.04.1"
UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_FILE="$CUBIC_DIR/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

# Check if ISO already exists
if [ -f "$UBUNTU_ISO_FILE" ]; then
    existing_size=$(du -h "$UBUNTU_ISO_FILE" | cut -f1)
    log "Ubuntu Server ISO already downloaded: $(basename $UBUNTU_ISO_FILE) ($existing_size)"
    success "✓ Skipping ISO download (already exists)"
    echo ""
else
    log "Downloading Ubuntu Server 24.04 LTS ISO (~2.5GB)"
    log "Source: $UBUNTU_ISO_URL"
    echo ""

    read -p "Download Ubuntu Server 24.04 LTS ISO (~2.5GB)? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warning "Skipping Ubuntu ISO download"
        warning "You will need to manually provide the ISO to Cubic"
    else
        log "Downloading ISO (this may take several minutes)..."

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
        else
            error "ISO download failed"
            exit 1
        fi
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
            filename=$(echo "$image" | sed 's/[\/:]/_/g')
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

# Check if models already exist
if [ -f "$MODELS_DIR/ollama-models.tar.gz" ]; then
    existing_size=$(du -h "$MODELS_DIR/ollama-models.tar.gz" | cut -f1)
    log "Ollama models already downloaded: ollama-models.tar.gz ($existing_size)"
    success "✓ Skipping Ollama model download (already exists)"
    echo ""
else
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
        size=$(du -h "$MODELS_DIR/ollama-models.tar.gz" | cut -f1)
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
# Homelab Cubic Project Directory

**IMPORTANT**: This directory IS your Cubic project directory!
When launching Cubic, select THIS directory as your project directory.

## Directory Structure

```
cubic-artifacts/              # <- Point Cubic here!
├── ubuntu-24.04.1-live-server-amd64.iso  # Ubuntu Server ISO
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

## How to Use with Cubic

### Step 1: Launch Cubic

```bash
# Launch Cubic and point it to THIS directory
cubic

# In Cubic GUI:
# - Project Directory: /path/to/Homelab-Install-Script/cubic-artifacts
# - Original ISO: Select ubuntu-24.04.1-live-server-amd64.iso (in this directory)
# - Click Next
```

### Step 2: In Cubic Chroot Terminal

When Cubic opens the chroot terminal, all files are already accessible!

```bash
# You are now root@cubic inside the ISO chroot environment
# All your files are accessible at /root/

# Verify files exist
ls ~/homelab/
ls ~/docker-images/
ls ~/ollama-models/

# Copy to ISO locations
mkdir -p /opt/homelab /opt/homelab-offline

# Copy homelab scripts
cp -r ~/homelab/* /opt/homelab/

# Copy offline artifacts
cp -r ~/docker-images ~/ollama-models ~/scripts /opt/homelab-offline/

# Set permissions
chmod +x /opt/homelab/*.sh
chmod +x /opt/homelab-offline/scripts/*.sh
```

### Step 3: Create Desktop Shortcut (Optional)

```bash
# In Cubic chroot environment
mkdir -p /etc/skel/Desktop

cat > /etc/skel/Desktop/install-homelab.desktop << 'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Install Homelab (Offline)
Comment=Install homelab with pre-downloaded dependencies
Exec=gnome-terminal -- bash -c "cd /opt/homelab && sudo /opt/homelab-offline/scripts/install-offline.sh; read -p 'Press Enter to close...'"
Icon=system-run
Terminal=true
Categories=System;
DESKTOP

chmod +x /etc/skel/Desktop/install-homelab.desktop
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

- **Ubuntu Server ISO**: ~2.5 GB
- **Docker Images**: ~20-30 GB
- **Ollama Models**: ~50-80 GB
- **Total**: ~72-112 GB

Ensure your system has sufficient space for these artifacts.

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

echo "Cubic project directory: $CUBIC_DIR"
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
    TOTAL_SIZE=$(du -sh "$CUBIC_DIR" | cut -f1)
    log "Total size: $TOTAL_SIZE"
fi

echo ""
success "✓ Ready for Cubic ISO integration"
echo ""
log "Next steps:"
echo ""
echo "  1. Launch Cubic:"
echo "     $ cubic"
echo ""
echo "  2. In Cubic GUI, select PROJECT DIRECTORY:"
echo "     $CUBIC_DIR"
echo ""
if [ -f "$UBUNTU_ISO_FILE" ]; then
    echo "  3. Select Ubuntu Server 24.04 LTS ISO:"
    echo "     $UBUNTU_ISO_FILE"
else
    echo "  3. Select Ubuntu Server 24.04 LTS ISO (you'll need to download it)"
fi
echo ""
echo "  4. In Cubic chroot terminal, run:"
echo "     # mkdir -p /opt/homelab /opt/homelab-offline"
echo "     # cp -r ~/homelab/* /opt/homelab/"
echo "     # cp -r ~/docker-images ~/ollama-models ~/scripts /opt/homelab-offline/"
echo ""
log "See CUBIC.md for detailed step-by-step guide"
