# Cubic Custom ISO Integration Guide

This guide explains how to create a custom Ubuntu ISO with all homelab dependencies pre-installed using [Cubic](https://github.com/PJ-Singh-001/Cubic) (Custom Ubuntu ISO Creator).

## Quick Start

**Complete workflow from start to finish:**

### On Your Build Machine (Terminal)

```bash
# 1. Install prerequisites
sudo apt update && sudo apt install -y git
sudo apt-add-repository ppa:cubic-wizard/release && sudo apt update
sudo apt install --no-install-recommends cubic
curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER

# IMPORTANT: Log out and log back in for Docker group to take effect

# 2. Clone repository
cd ~
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script
git checkout main

# 3. Download all dependencies (70-110GB, takes several hours)
./cubic-prepare.sh

# 4. Verify downloads completed
ls -lh cubic-artifacts/
```

### Launch Cubic (GUI)

```bash
# 5. Launch Cubic and follow GUI wizard
cubic
# - Select project directory: ~/cubic-homelab
# - Select Ubuntu Server 24.04 LTS ISO
# - Click Next through extraction
```

### In Cubic Chroot Terminal (root@cubic)

```bash
# 6. Copy homelab files to ISO
mkdir -p /opt/homelab /opt/homelab-offline

# Verify artifacts exist
ls /root/Homelab-Install-Script/cubic-artifacts/

# Copy files
cp -r /root/Homelab-Install-Script/* /opt/homelab/
cp -r /root/Homelab-Install-Script/cubic-artifacts/* /opt/homelab-offline/
chmod +x /opt/homelab/*.sh /opt/homelab-offline/scripts/*.sh

# 7. Pre-install Docker (see Step 3.2 below for full commands)
# 8. Optionally pre-install NVIDIA drivers (see Step 3.3)
# 9. Create systemd services and desktop shortcuts (see Step 3.4-3.5)
# 10. Clean up and exit Cubic chroot

# See detailed steps below for complete customization
```

## Overview

By integrating homelab dependencies into a custom ISO, you can:
- ✅ Install homelab completely offline (no internet required)
- ✅ Faster installation (no large downloads)
- ✅ Consistent deployment across multiple servers
- ✅ Include NVIDIA drivers in the ISO
- ✅ Pre-configure system settings

## Prerequisites

### On Your Build Machine (with Internet)

```bash
# Install Git
sudo apt update
sudo apt install -y git

# Install Cubic
sudo apt-add-repository universe
sudo apt-add-repository ppa:cubic-wizard/release
sudo apt update
sudo apt install --no-install-recommends cubic

# Install Docker (for downloading images)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in for group to take effect
```

### Disk Space Requirements

- **Build machine**: 150-200 GB free space
  - Ubuntu ISO: ~5 GB
  - Docker images: ~30 GB
  - Ollama models: ~80 GB
  - Cubic working directory: ~20 GB
  - Final custom ISO: ~100-130 GB

- **Target server**: 100 GB minimum for root partition

## Step 1: Clone Repository and Prepare Dependencies

**⚠️ IMPORTANT: Run these commands on your BUILD MACHINE, NOT in Cubic chroot!**

First, clone the homelab repository and download all dependencies:

```bash
# ============================================
# RUN ON YOUR BUILD MACHINE (your laptop/desktop)
# NOT in Cubic chroot environment!
# ============================================

# Clone the repository
cd ~
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script

# Checkout the latest version
git checkout main
# Or checkout a specific branch if needed:
# git checkout claude/homelab-ai-server-setup-011CUtxQCR38wt4JF7UqHJVZ

# Download all Docker images and Ollama models
# This requires Docker to be running on your BUILD MACHINE
./cubic-prepare.sh
```

This will create `cubic-artifacts/` directory containing:
- `docker-images/` - All Docker images as compressed tar files (~30 GB)
- `ollama-models/` - All Ollama models as compressed archive (~80 GB)
- `scripts/` - Installation scripts for offline deployment

**Note**:
- This process can take **several hours** depending on your internet connection
- Verify `cubic-artifacts/` directory exists before proceeding to Step 2
- You must complete this step BEFORE launching Cubic

## Step 2: Launch Cubic

```bash
# Create a project directory
mkdir -p ~/cubic-homelab
cd ~/cubic-homelab

# Launch Cubic
cubic
```

In Cubic GUI:
1. **Project Directory**: Select `~/cubic-homelab`
2. **Original ISO**: Download and select Ubuntu Server 24.04 LTS
3. **Custom ISO filename**: `ubuntu-24.04-homelab-amd64.iso`
4. Click **Next** through the extraction process

## Step 3: Customize the ISO (Chroot Terminal)

**⚠️ You are now INSIDE the Cubic chroot environment (you are 'root' here)**

Cubic will open a terminal inside the ISO's chroot environment. Run these commands:

### 3.1: Copy Homelab Files

```bash
# ============================================
# RUN THESE COMMANDS IN CUBIC CHROOT (you are root@cubic)
# ============================================

# Create directories
mkdir -p /opt/homelab
mkdir -p /opt/homelab-offline

# In Cubic chroot, you can access your build machine's home directory
# Cubic mounts it automatically (usually at /root or your username)

# First, verify the artifacts exist on your build machine:
ls /root/Homelab-Install-Script/cubic-artifacts/

# If that doesn't work, try:
# ls ~/Homelab-Install-Script/cubic-artifacts/

# Copy homelab installation scripts
# Adjust path based on where you see the files above
cp -r /root/Homelab-Install-Script/* /opt/homelab/
cp -r /root/Homelab-Install-Script/cubic-artifacts/* /opt/homelab-offline/

# Alternative: Use Cubic's file manager to copy files graphically
# Right-click in Cubic -> Open File Manager -> Navigate to build machine's home
# Look for Homelab-Install-Script directory

# Set permissions
chmod +x /opt/homelab/*.sh
chmod +x /opt/homelab-offline/scripts/*.sh

# Verify files were copied
ls -lh /opt/homelab/
ls -lh /opt/homelab-offline/docker-images/
ls -lh /opt/homelab-offline/ollama-models/
```

### 3.2: Pre-install Docker

```bash
# Install Docker in the ISO
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 3.3: Pre-install NVIDIA Drivers (Optional)

```bash
# Install ubuntu-drivers-common
apt-get install -y ubuntu-drivers-common

# Detect and install recommended NVIDIA driver
ubuntu-drivers autoinstall

# Or install specific version
# apt-get install -y nvidia-driver-535
```

### 3.4: Load Docker Images into ISO

```bash
# Start Docker daemon (in chroot, this may require special handling)
# If Docker daemon won't start in chroot, skip this and load images on first boot instead

# Alternative: Create a systemd service to load images on first boot
cat > /etc/systemd/system/load-homelab-images.service << 'EOF'
[Unit]
Description=Load Homelab Docker Images on First Boot
After=docker.service
Requires=docker.service
ConditionPathExists=/opt/homelab-offline/docker-images
ConditionPathExists=!/var/lib/homelab-images-loaded

[Service]
Type=oneshot
ExecStart=/opt/homelab-offline/scripts/load-docker-images.sh
ExecStartPost=/usr/bin/touch /var/lib/homelab-images-loaded
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable load-homelab-images.service
```

### 3.5: Create Desktop Shortcuts

```bash
# Create desktop shortcut for installer
mkdir -p /etc/skel/Desktop

cat > /etc/skel/Desktop/install-homelab.desktop << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Install AI Homelab
Comment=Install AI homelab with pre-downloaded dependencies
Exec=gnome-terminal -- bash -c "cd /opt/homelab && sudo /opt/homelab-offline/scripts/install-offline.sh; read -p 'Press Enter to close...'"
Icon=system-run
Terminal=true
Categories=System;
EOF

chmod +x /etc/skel/Desktop/install-homelab.desktop
```

### 3.6: Pre-configure System (Optional)

```bash
# Disable automatic updates (for lab environment)
systemctl disable apt-daily.timer
systemctl disable apt-daily-upgrade.timer

# Pre-configure SSH
apt-get install -y openssh-server
systemctl enable ssh

# Install useful utilities
apt-get install -y vim htop tree net-tools pciutils lsof
```

### 3.7: Clean Up

```bash
# Clean package cache to reduce ISO size
apt-get clean
apt-get autoremove -y

# Remove temporary files
rm -rf /tmp/*
rm -rf /var/tmp/*
```

## Step 4: Generate the ISO

1. Click **Next** in Cubic to proceed
2. **Kernel selection**: Select the latest kernel
3. **Boot configuration**:
   - Boot label: `Ubuntu 24.04 AI Homelab`
   - Disk name: `Ubuntu AI Homelab`
4. **Compression**: Use `xz` for best compression (slower) or `gzip` for faster
5. Click **Generate** to create the ISO

The final ISO will be saved in your project directory.

## Step 5: Test the ISO

```bash
# Test in QEMU/KVM
virt-install \
  --name homelab-test \
  --memory 16384 \
  --vcpus 4 \
  --disk size=200 \
  --cdrom ~/cubic-homelab/ubuntu-24.04-homelab-amd64.iso \
  --os-variant ubuntu24.04

# Or use VirtualBox, VMware, or burn to USB
```

## Using the Custom ISO

### First Boot Installation

1. **Boot from ISO**
2. **Install Ubuntu** normally
3. **After first login**, run:

```bash
# Option 1: Desktop shortcut (if using GUI)
# Double-click "Install AI Homelab" on desktop

# Option 2: Manual from terminal
cd /opt/homelab
sudo /opt/homelab-offline/scripts/install-offline.sh
```

### What Gets Installed

The offline installation script will:
1. ✅ Load all Docker images from ISO (~5 minutes)
2. ✅ Run storage configuration (partition selection)
3. ✅ Install all system packages
4. ✅ Start all Docker containers
5. ✅ Load pre-downloaded Ollama models (~10 minutes)
6. ✅ Configure services

**Total time**: 20-30 minutes (vs 3-4 hours with online installation)

## Deployment Scenarios

### Scenario 1: Fully Offline Installation

- No internet required
- All dependencies on ISO
- Fastest installation

### Scenario 2: Hybrid (ISO + Updates)

- Use ISO for large files (Docker images, models)
- Connect to internet for latest security updates
- Balanced approach

### Scenario 3: Multiple Server Deployment

- Create ISO once
- Deploy to multiple Dell R630 servers
- Consistent configuration across fleet

## Advanced Customization

### Custom Preseed for Automated Installation

Create `preseed.cfg` for fully automated installation:

```bash
# In Cubic chroot
cat > /preseed/homelab-preseed.cfg << 'EOF'
# Regional settings
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

# Network configuration
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string homelab-server
d-i netcfg/get_domain string local

# User creation
d-i passwd/user-fullname string Homelab Admin
d-i passwd/username string admin
d-i passwd/user-password password changeme
d-i passwd/user-password-again password changeme
d-i user-setup/allow-password-weak boolean true

# Partitioning (use entire disk)
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# Package selection
tasksel tasksel/first multiselect ubuntu-server
d-i pkgsel/include string openssh-server docker-ce

# Run homelab installation post-install
d-i preseed/late_command string \
    in-target systemctl enable load-homelab-images.service ; \
    in-target /opt/homelab-offline/scripts/load-docker-images.sh
EOF
```

### Custom Boot Options

Edit `/boot/grub/grub.cfg` in Cubic to add custom boot options:

```
menuentry "Ubuntu AI Homelab - Automated Install" {
    set gfxpayload=keep
    linux /casper/vmlinuz file=/cdrom/preseed/homelab-preseed.cfg boot=casper automatic-ubiquity noprompt quiet splash ---
    initrd /casper/initrd
}
```

## Troubleshooting

### Error: "Please run this script as a regular user, not as root"

**Problem**: Getting this error when running `cubic-prepare.sh` inside Cubic chroot

**Cause**: You're trying to run `cubic-prepare.sh` in the wrong place!

**Solution**:
- `cubic-prepare.sh` must be run on your **BUILD MACHINE** (before launching Cubic)
- NOT inside the Cubic chroot environment
- Exit the Cubic chroot and run it on your laptop/desktop

```bash
# On your BUILD MACHINE (not in Cubic):
cd ~/Homelab-Install-Script
./cubic-prepare.sh

# Wait for downloads to complete, then go back to Cubic
```

**Why**: The chroot environment doesn't have Docker running and you're always root there. The script needs Docker on your build machine to download images.

### cubic-artifacts Directory Not Found in Chroot

**Problem**: Can't find `~/Homelab-Install-Script/cubic-artifacts/` in Cubic chroot

**Cause**: The artifacts weren't downloaded yet, or you're looking in the wrong path

**Solution**:
1. Verify artifacts exist on build machine (exit Cubic first):
   ```bash
   ls ~/Homelab-Install-Script/cubic-artifacts/
   ```
2. If missing, run `./cubic-prepare.sh` on build machine
3. In Cubic chroot, try different paths:
   ```bash
   ls /root/Homelab-Install-Script/cubic-artifacts/
   # Or
   ls ~/Homelab-Install-Script/cubic-artifacts/
   ```
4. Use Cubic's file manager to locate files graphically

### ISO Too Large for DVD

**Solution**: Use USB drive or split ISO

```bash
# Split ISO for multi-disc
split -b 4GB ubuntu-24.04-homelab-amd64.iso homelab-disc-

# Or create USB bootable drive
sudo dd if=ubuntu-24.04-homelab-amd64.iso of=/dev/sdX bs=4M status=progress
```

### Docker Images Not Loading

**Check**:
```bash
ls -lh /opt/homelab-offline/docker-images/
systemctl status load-homelab-images.service
journalctl -u load-homelab-images.service
```

**Fix**: Manually load images
```bash
sudo /opt/homelab-offline/scripts/load-docker-images.sh
```

### Ollama Models Missing

**Check**:
```bash
ls -lh /opt/homelab-offline/ollama-models/
sudo docker exec ollama ollama list
```

**Fix**: Manually load models
```bash
sudo /opt/homelab-offline/scripts/load-ollama-models.sh
```

### NVIDIA Drivers Not Working After Install

**Fix**: Reboot required after NVIDIA driver installation
```bash
sudo reboot
nvidia-smi  # Verify after reboot
```

## ISO Maintenance

### Updating Dependencies

When new Docker images or Ollama models are released:

```bash
# 1. Update homelab repository
cd ~/Homelab-Install-Script
git pull

# 2. Re-run preparation script
./cubic-prepare.sh

# 3. Rebuild ISO in Cubic
# - Replace /opt/homelab-offline/ contents
# - Regenerate ISO
```

### Version Control

Tag your ISO versions:

```bash
# Rename ISO with version
mv ubuntu-24.04-homelab-amd64.iso ubuntu-24.04-homelab-v1.0-amd64.iso

# Create checksum
sha256sum ubuntu-24.04-homelab-v1.0-amd64.iso > ubuntu-24.04-homelab-v1.0-amd64.iso.sha256
```

## Best Practices

1. **Test ISO in VM first** before deploying to physical hardware
2. **Keep source files** - Save cubic-artifacts/ for future rebuilds
3. **Document customizations** - Track any manual changes made in Cubic
4. **Regular updates** - Rebuild ISO monthly for security updates
5. **Verify checksums** - Always verify ISO integrity before deployment

## Resources

- **Cubic**: https://github.com/PJ-Singh-001/Cubic
- **Ubuntu Preseed**: https://help.ubuntu.com/lts/installation-guide/amd64/apb.html
- **Docker Offline**: https://docs.docker.com/engine/reference/commandline/save/
- **Ollama**: https://ollama.com/

## Support

For issues specific to:
- **Cubic ISO creation**: https://github.com/PJ-Singh-001/Cubic/issues
- **Homelab installation**: https://github.com/brilliantsquirrel/Homelab-Install-Script/issues
