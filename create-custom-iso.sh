#!/bin/bash
#
# create-custom-iso.sh - Script-based Ubuntu ISO Customization
# Fully automated, headless ISO building approach
#
# This script:
# 1. Extracts the Ubuntu Server ISO
# 2. Mounts and modifies the squashfs filesystem
# 3. Copies homelab scripts, Docker images, and Ollama models
# 4. Configures auto-installation of homelab on first boot
# 5. Repacks everything into a new bootable ISO
#
# Usage: ./create-custom-iso.sh
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

header() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    error "Please run as regular user with sudo privileges, not as root"
    exit 1
fi

# Get the repository root directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

header "Custom Ubuntu ISO Builder - Homelab Edition"

# Configuration
UBUNTU_VERSION="24.04.3"
ISO_INPUT="$REPO_DIR/iso-artifacts/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
ISO_OUTPUT="$REPO_DIR/iso-artifacts/ubuntu-${UBUNTU_VERSION}-homelab-amd64.iso"

# Use local SSD if available for faster builds, otherwise use boot disk
if [ -d "/mnt/disks/ssd/iso-build" ]; then
    WORK_DIR="/mnt/disks/ssd/iso-build"
    log "Using local SSD for build: $WORK_DIR (much faster!)"
else
    WORK_DIR="$REPO_DIR/iso-build"
    log "Using boot disk for build: $WORK_DIR"
fi

ISO_EXTRACT="$WORK_DIR/iso"
SQUASHFS_EXTRACT="$WORK_DIR/squashfs"
# SQUASHFS_FILE will be auto-detected after ISO extraction (Server vs Desktop ISO)

# Homelab data sources
HOMELAB_DIR="$REPO_DIR/iso-artifacts/homelab"
DOCKER_DIR="$REPO_DIR/iso-artifacts/docker-images"
MODELS_DIR="$REPO_DIR/iso-artifacts/ollama-models"

# Check prerequisites
log "Checking prerequisites..."
MISSING_PACKAGES=()

for pkg in xorriso squashfs-tools; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log "Installing required packages: ${MISSING_PACKAGES[*]}"
    sudo apt-get update
    sudo apt-get install -y "${MISSING_PACKAGES[@]}"
fi

# Check if input ISO exists
if [ ! -f "$ISO_INPUT" ]; then
    error "Input ISO not found: $ISO_INPUT"
    error "Please run ./iso-prepare.sh first to download the ISO"
    exit 1
fi

log "Input ISO: $ISO_INPUT"
log "Output ISO: $ISO_OUTPUT"
log "Working directory: $WORK_DIR"

# Clean up old build directory
if [ -d "$WORK_DIR" ]; then
    warning "Removing old build directory..."
    # Unmount any lingering mounts
    sudo umount "$SQUASHFS_EXTRACT/dev" 2>/dev/null || true
    sudo umount "$SQUASHFS_EXTRACT/proc" 2>/dev/null || true
    sudo umount "$SQUASHFS_EXTRACT/sys" 2>/dev/null || true
    sudo umount "$SQUASHFS_EXTRACT" 2>/dev/null || true
    # Use sudo because previous build may have created root-owned files
    sudo rm -rf "$WORK_DIR"
fi

mkdir -p "$WORK_DIR"

# Step 1: Extract the ISO
header "Step 1: Extracting Ubuntu ISO"
log "This may take a few minutes..."
mkdir -p "$ISO_EXTRACT"

xorriso -osirrox on -indev "$ISO_INPUT" -extract / "$ISO_EXTRACT" 2>&1 | grep -v "^xorriso" || true

# Make extracted files writable
chmod -R u+w "$ISO_EXTRACT"
success "ISO extracted to $ISO_EXTRACT"

# Detect ISO type and locate squashfs filesystem
log "Detecting ISO type..."
if [ -f "$ISO_EXTRACT/casper/filesystem.squashfs" ]; then
    # Desktop ISO structure
    SQUASHFS_FILE="$ISO_EXTRACT/casper/filesystem.squashfs"
    ISO_TYPE="Desktop"
    log "Detected: Ubuntu Desktop ISO"
elif [ -f "$ISO_EXTRACT/casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs" ]; then
    # Server ISO structure - use the installer environment
    SQUASHFS_FILE="$ISO_EXTRACT/casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs"
    ISO_TYPE="Server"
    log "Detected: Ubuntu Server ISO (installer environment)"
else
    error "Could not detect ISO type. Available squashfs files:"
    find "$ISO_EXTRACT/casper" -name "*.squashfs" 2>/dev/null || echo "None found"
    exit 1
fi

success "Using squashfs: $(basename "$SQUASHFS_FILE")"

# Step 2: Extract the squashfs filesystem
header "Step 2: Extracting squashfs filesystem"
log "This will take several minutes (~5-10 minutes)..."

if [ ! -f "$SQUASHFS_FILE" ]; then
    error "Squashfs file not found: $SQUASHFS_FILE"
    exit 1
fi

unsquashfs -no-xattrs -f -d "$SQUASHFS_EXTRACT" "$SQUASHFS_FILE"
success "Squashfs extracted to $SQUASHFS_EXTRACT"

# Step 3: Customize the filesystem
header "Step 3: Customizing the filesystem"

# Check if REPO_DIR is on a gcsfuse mount and copy to local disk if needed
# This is necessary because sudo rsync can't access user-mounted FUSE filesystems
HOMELAB_SOURCE="$REPO_DIR"
if mountpoint -q "$REPO_DIR" 2>/dev/null || df -T "$REPO_DIR" 2>/dev/null | grep -q "fuse"; then
    warning "Repository is on a FUSE/gcsfuse filesystem - copying to local disk first"
    log "This avoids permission issues with sudo rsync accessing user-mounted FUSE"

    HOMELAB_SOURCE="$WORK_DIR/homelab-source"
    mkdir -p "$HOMELAB_SOURCE"

    log "Copying repository to local disk (this may take a minute)..."
    # Run as regular user (not sudo) to access gcsfuse mount
    rsync -rl --no-times --no-perms \
        --exclude='iso-artifacts' \
        --exclude='iso-build' \
        --exclude='.git' \
        --exclude='.github' \
        "$REPO_DIR/" "$HOMELAB_SOURCE/" || {
        error "Failed to copy repository from gcsfuse mount"
        exit 1
    }
    success "Repository copied to local disk: $HOMELAB_SOURCE"
fi

log "Copying homelab scripts..."
sudo mkdir -p "$SQUASHFS_EXTRACT/opt/homelab"

# Copy only necessary files, exclude large directories
# Use rsync to exclude iso-artifacts, iso-build, and .git
# Note: --no-times for compatibility with gcsfuse-mounted source directories
sudo rsync -rl --no-times \
    --exclude='iso-artifacts' \
    --exclude='iso-build' \
    --exclude='.git' \
    --exclude='.github' \
    "$HOMELAB_SOURCE/" "$SQUASHFS_EXTRACT/opt/homelab/" || {
    error "Failed to copy homelab scripts"
    exit 1
}
success "Homelab scripts copied to /opt/homelab (excluded large data directories)"

# Copy Docker images if available
if [ -d "$DOCKER_DIR" ] && [ "$(ls -A "$DOCKER_DIR" 2>/dev/null)" ]; then
    log "Copying Docker images (~20-30GB, may take 10-15 minutes)..."
    sudo mkdir -p "$SQUASHFS_EXTRACT/opt/homelab-data/docker-images"

    # Copy from GCS bucket mount or local directory
    if mountpoint -q "$REPO_DIR/iso-artifacts" 2>/dev/null; then
        # Files are in GCS bucket, copy them
        log "Copying Docker images from GCS bucket..."
        # Note: --no-times for compatibility with gcsfuse filesystem
        sudo rsync -rlh --no-times --info=progress2 "$DOCKER_DIR/" "$SQUASHFS_EXTRACT/opt/homelab-data/docker-images/" || {
            warning "Failed to copy Docker images, continuing..."
        }
    else
        sudo cp -r "$DOCKER_DIR"/* "$SQUASHFS_EXTRACT/opt/homelab-data/docker-images/" 2>/dev/null || {
            warning "Docker images not found, skipping"
        }
    fi
    success "Docker images copied"
else
    warning "Docker images directory not found or empty, skipping"
fi

# Copy Ollama models if available
if [ -d "$MODELS_DIR" ] && [ "$(ls -A "$MODELS_DIR" 2>/dev/null)" ]; then
    log "Copying Ollama models (~50-80GB, may take 20-30 minutes)..."
    sudo mkdir -p "$SQUASHFS_EXTRACT/opt/homelab-data/ollama-models"

    if mountpoint -q "$REPO_DIR/iso-artifacts" 2>/dev/null; then
        log "Copying Ollama models from GCS bucket..."
        # Note: --no-times for compatibility with gcsfuse filesystem
        sudo rsync -rlh --no-times --info=progress2 "$MODELS_DIR/" "$SQUASHFS_EXTRACT/opt/homelab-data/ollama-models/" || {
            warning "Failed to copy Ollama models, continuing..."
        }
    else
        sudo cp -r "$MODELS_DIR"/* "$SQUASHFS_EXTRACT/opt/homelab-data/ollama-models/" 2>/dev/null || {
            warning "Ollama models not found, skipping"
        }
    fi
    success "Ollama models copied"
else
    warning "Ollama models directory not found or empty, skipping"
fi

# Create first-boot setup script
log "Creating first-boot setup script..."
sudo tee "$SQUASHFS_EXTRACT/opt/homelab-setup.sh" > /dev/null << 'FIRST_BOOT_EOF'
#!/bin/bash
# First boot setup script - runs once on first system boot

LOG_FILE="/var/log/homelab-first-boot.log"

{
    echo "======================================"
    echo "Homelab First Boot Setup"
    echo "Started: $(date)"
    echo "======================================"

    # Import Docker images if they exist
    if [ -d /opt/homelab-data/docker-images ]; then
        echo "Loading Docker images from ISO..."
        for tarfile in /opt/homelab-data/docker-images/*.tar.gz; do
            if [ -f "$tarfile" ]; then
                echo "Loading $(basename "$tarfile")..."
                docker load -i "$tarfile" || echo "Failed to load $tarfile"
            fi
        done
        echo "Docker images loaded"
    fi

    # Import Ollama models if they exist
    if [ -d /opt/homelab-data/ollama-models ]; then
        echo "Restoring Ollama models from ISO..."
        mkdir -p /var/lib/docker/volumes/ollama_models/_data
        cp -r /opt/homelab-data/ollama-models/* /var/lib/docker/volumes/ollama_models/_data/ || true
        echo "Ollama models restored"
    fi

    # Make post-install script executable
    if [ -f /opt/homelab/post-install.sh ]; then
        chmod +x /opt/homelab/post-install.sh
        echo "Homelab installation scripts are ready at /opt/homelab/"
        echo ""
        echo "Docker images and Ollama models have been pre-loaded from the ISO!"
        echo ""
        echo "To complete homelab setup, run:"
        echo "  cd /opt/homelab"
        echo "  ./post-install.sh"
    fi

    # Clean up - remove this script from future boots
    systemctl disable homelab-first-boot.service

    echo "======================================"
    echo "First boot setup complete: $(date)"
    echo "======================================"
} >> "$LOG_FILE" 2>&1
FIRST_BOOT_EOF

sudo chmod +x "$SQUASHFS_EXTRACT/opt/homelab-setup.sh"

# Create systemd service for first boot
log "Creating systemd service for first boot..."
sudo tee "$SQUASHFS_EXTRACT/etc/systemd/system/homelab-first-boot.service" > /dev/null << 'SERVICE_EOF'
[Unit]
Description=Homelab First Boot Setup
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/opt/homelab-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable the service (will run on first boot)
log "Enabling first-boot service in chroot..."
sudo chroot "$SQUASHFS_EXTRACT" /bin/bash -c "systemctl enable homelab-first-boot.service" 2>/dev/null || {
    warning "Could not enable service via chroot, will enable manually"
    sudo mkdir -p "$SQUASHFS_EXTRACT/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/etc/systemd/system/homelab-first-boot.service" \
        "$SQUASHFS_EXTRACT/etc/systemd/system/multi-user.target.wants/homelab-first-boot.service"
}

success "Filesystem customization complete"

# Step 4: Repack the squashfs filesystem
header "Step 4: Repacking squashfs filesystem"
log "This will take several minutes (~5-10 minutes)..."
log "Compressing with xz (high compression for smaller ISO)..."

# Remove old squashfs
sudo rm -f "$SQUASHFS_FILE"

# Create new squashfs with high compression
# Show all output (don't filter) to catch any errors
log "Running mksquashfs (this is verbose but shows progress)..."
if sudo mksquashfs "$SQUASHFS_EXTRACT" "$SQUASHFS_FILE" \
    -comp xz \
    -Xbcj x86 \
    -b 1M \
    -Xdict-size 1M \
    -no-duplicates \
    -no-recovery; then
    success "Squashfs filesystem repacked"
else
    error "mksquashfs command failed!"
    error "This usually means:"
    error "  - Not enough disk space in $WORK_DIR"
    error "  - File system permission issues"
    error "  - Corrupted source filesystem"
    log "Checking disk space..."
    df -h "$WORK_DIR"
    exit 1
fi

# Update filesystem size
log "Updating filesystem size..."
SQUASHFS_SIZE=$(du -b "$SQUASHFS_FILE" | cut -f1)
echo "$SQUASHFS_SIZE" | sudo tee "$ISO_EXTRACT/casper/filesystem.size" > /dev/null

# Step 5: Update ISO metadata
header "Step 5: Updating ISO metadata"

# Update volume ID
VOLUME_ID="Ubuntu 24.04 Homelab"

# Regenerate md5sum
log "Regenerating md5sum.txt..."
cd "$ISO_EXTRACT"
sudo rm -f md5sum.txt
sudo find . -type f -not -name md5sum.txt -not -path "./isolinux/*" -exec md5sum {} \; | \
    sudo tee md5sum.txt > /dev/null
cd "$REPO_DIR"

success "ISO metadata updated"

# Step 6: Create the new ISO
header "Step 6: Creating new bootable ISO"
log "Building ISO image..."

xorriso -as mkisofs \
    -r -V "$VOLUME_ID" \
    -o "$ISO_OUTPUT" \
    -J -joliet-long \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -isohybrid-apm-hfsplus \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    "$ISO_EXTRACT" 2>&1 | grep -v "^xorriso" || true

success "Custom ISO created: $ISO_OUTPUT"

# Step 7: Make ISO hybrid bootable
log "Making ISO hybrid bootable..."
if command -v isohybrid &> /dev/null; then
    isohybrid --uefi "$ISO_OUTPUT" 2>/dev/null || {
        warning "isohybrid failed, but ISO should still be bootable"
    }
fi

# Wait for file to be fully written (especially important on gcsfuse mounts)
if mountpoint -q "$(dirname "$ISO_OUTPUT")" 2>/dev/null || df -T "$(dirname "$ISO_OUTPUT")" 2>/dev/null | grep -q "fuse"; then
    log "Detected FUSE filesystem, waiting for file sync..."
    sleep 3
    sync
fi

# Calculate ISO size
if [ -f "$ISO_OUTPUT" ]; then
    ISO_SIZE_MB=$(du -m "$ISO_OUTPUT" | cut -f1)
    ISO_SIZE_GB=$(echo "scale=2; $ISO_SIZE_MB / 1024" | bc)
else
    warning "ISO file not immediately visible (may be syncing to gcsfuse)"
    ISO_SIZE_MB="unknown"
    ISO_SIZE_GB="unknown"
fi

# Cleanup
header "Cleanup"
log "Removing build directory..."
sudo umount "$SQUASHFS_EXTRACT/dev" 2>/dev/null || true
sudo umount "$SQUASHFS_EXTRACT/proc" 2>/dev/null || true
sudo umount "$SQUASHFS_EXTRACT/sys" 2>/dev/null || true
sudo rm -rf "$WORK_DIR"
success "Build directory cleaned up"

# Final summary
header "ISO Creation Complete!"
echo ""
success "Custom Ubuntu ISO created successfully!"
echo ""
echo "  Input ISO:  $ISO_INPUT"
echo "  Output ISO: $ISO_OUTPUT"
echo "  ISO Size:   ${ISO_SIZE_MB}MB (~${ISO_SIZE_GB}GB)"
echo ""
echo "What's included in this ISO:"
echo "  - Ubuntu Server 24.04.3 LTS"
echo "  - Homelab installation scripts in /opt/homelab/"
echo "  - All Docker images (~20-30GB) in /opt/homelab-data/docker-images/"
echo "  - All Ollama models (~50-80GB) in /opt/homelab-data/ollama-models/"
echo "  - First-boot setup service (auto-loads images/models)"
echo ""
echo "NOTE: This is a LARGE ISO (${ISO_SIZE_GB}GB) due to included Docker images and models."
echo "      Requires a large USB drive or direct boot from ISO."
echo ""
echo "Next Steps:"
echo "  1. Write to large USB drive (128GB+ recommended):"
echo "     dd if=$ISO_OUTPUT of=/dev/sdX bs=4M status=progress"
echo ""
echo "  2. Boot from the ISO and install Ubuntu normally"
echo ""
echo "  3. After first boot, the system will automatically:"
echo "     - Load all Docker images from /opt/homelab-data/"
echo "     - Restore Ollama models"
echo "     - Make scripts executable"
echo ""
echo "  4. Complete the setup by running:"
echo "     cd /opt/homelab"
echo "     ./post-install.sh"
echo ""
echo "  5. Check first-boot logs at:"
echo "     /var/log/homelab-first-boot.log"
echo ""
