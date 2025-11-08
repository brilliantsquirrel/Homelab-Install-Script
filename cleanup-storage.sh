#!/bin/bash

# Homelab Storage Cleanup Script
# Safely removes all homelab storage partitions for fresh testing

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

header "Homelab Storage Cleanup"

warning "This script will:"
echo "  1. Unmount all homelab storage partitions (/mnt/fast, /mnt/ai-data, /mnt/models, /mnt/bulk)"
echo "  2. Remove homelab entries from /etc/fstab"
echo "  3. Optionally wipe selected drive(s)"
echo ""

# Detect drives with homelab partitions
log "Detecting homelab partitions..."
HOMELAB_MOUNTS=$(mount | grep -E '(/mnt/fast|/mnt/ai-data|/mnt/models|/mnt/bulk)' || true)

if [ -z "$HOMELAB_MOUNTS" ]; then
    log "No homelab partitions currently mounted"
else
    echo ""
    echo "Currently mounted homelab partitions:"
    echo "$HOMELAB_MOUNTS"
    echo ""
fi

# Get unique drives from mounted homelab partitions
DRIVES_IN_USE=$(mount | grep -E '(/mnt/fast|/mnt/ai-data|/mnt/models|/mnt/bulk)' | awk '{print $1}' | sed 's/[0-9]*$//' | sort -u || true)

# Show available drives
echo ""
echo "Available drives on system:"
lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep disk
echo ""

# Ask for confirmation
read -p "Do you want to proceed with cleanup? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Cleanup cancelled"
    exit 0
fi

# Step 1: Unmount all homelab partitions
header "Step 1: Unmounting Partitions"

for mount_point in /mnt/fast /mnt/ai-data /mnt/models /mnt/bulk; do
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log "Unmounting $mount_point..."
        sudo umount "$mount_point" || warning "Failed to unmount $mount_point (may not be mounted)"
        success "✓ Unmounted $mount_point"
    else
        log "$mount_point is not mounted, skipping"
    fi
done

# Step 2: Clean up fstab
header "Step 2: Cleaning /etc/fstab"

log "Backing up /etc/fstab to /etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"
sudo cp /etc/fstab "/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"

log "Removing homelab mount entries from /etc/fstab..."
sudo sed -i '/\/mnt\/fast/d; /\/mnt\/ai-data/d; /\/mnt\/models/d; /\/mnt\/bulk/d' /etc/fstab

log "Reloading systemd daemon..."
sudo systemctl daemon-reload

success "✓ Cleaned /etc/fstab"

# Step 3: Remove mount point directories (optional)
header "Step 3: Mount Point Directories"

read -p "Remove mount point directories (/mnt/fast, /mnt/ai-data, etc.)? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    for mount_point in /mnt/fast /mnt/ai-data /mnt/models /mnt/bulk; do
        if [ -d "$mount_point" ]; then
            log "Removing $mount_point..."
            sudo rm -rf "$mount_point"
            success "✓ Removed $mount_point"
        fi
    done
else
    log "Keeping mount point directories"
fi

# Step 4: Wipe drives (optional)
header "Step 4: Drive Wiping"

echo "Detected drives that had homelab partitions:"
if [ -n "$DRIVES_IN_USE" ]; then
    echo "$DRIVES_IN_USE"
else
    log "No drives detected with homelab partitions"
fi
echo ""

read -p "Do you want to wipe any drives? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Available drives:"
    lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep disk | nl -w2 -s'. '
    echo ""

    read -p "Enter drive name to wipe (e.g., sdb), or press Enter to skip: " DRIVE_TO_WIPE

    if [ -n "$DRIVE_TO_WIPE" ]; then
        # Validate drive exists
        if [ ! -b "/dev/$DRIVE_TO_WIPE" ]; then
            error "Drive /dev/$DRIVE_TO_WIPE does not exist"
            exit 1
        fi

        # Get boot drive to prevent wiping it
        BOOT_DRIVE=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null || echo "")

        if [ "$DRIVE_TO_WIPE" = "$BOOT_DRIVE" ]; then
            error "Cannot wipe boot drive /dev/$DRIVE_TO_WIPE!"
            exit 1
        fi

        warning "⚠️  WARNING: This will PERMANENTLY ERASE all data on /dev/$DRIVE_TO_WIPE!"
        echo ""
        lsblk "/dev/$DRIVE_TO_WIPE"
        echo ""

        read -p "Type 'WIPE' in uppercase to confirm: " CONFIRM

        if [ "$CONFIRM" = "WIPE" ]; then
            log "Wiping /dev/$DRIVE_TO_WIPE..."
            sudo wipefs -a "/dev/$DRIVE_TO_WIPE"
            success "✓ Wiped /dev/$DRIVE_TO_WIPE"

            echo ""
            log "Drive /dev/$DRIVE_TO_WIPE after wipe:"
            lsblk "/dev/$DRIVE_TO_WIPE"
        else
            log "Wipe cancelled (confirmation failed)"
        fi
    else
        log "No drive specified, skipping wipe"
    fi
else
    log "Skipping drive wipe"
fi

# Step 5: Clean up storage config file
header "Step 5: Configuration Files"

if [ -f "$HOME/.homelab-storage.conf" ]; then
    log "Removing storage configuration file..."
    rm -f "$HOME/.homelab-storage.conf"
    success "✓ Removed $HOME/.homelab-storage.conf"
else
    log "No storage configuration file found"
fi

# Summary
header "Cleanup Complete"

success "✓ All homelab storage partitions have been cleaned up"
echo ""
log "You can now run ./post-install.sh to create fresh partitions with optimal alignment"
echo ""
