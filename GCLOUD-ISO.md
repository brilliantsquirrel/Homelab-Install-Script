# Google Cloud VM Setup for Custom Ubuntu ISO Creation

This guide explains how to set up a Google Cloud VM for creating custom Ubuntu ISOs with large file storage in Cloud Storage buckets.

## Overview

Creating custom Ubuntu ISOs for homelab deployment requires:
- **70-110GB** of storage for Docker images and Ollama models
- **Significant compute** for downloading and processing (optimized for **60% faster execution**)
- **Flexibility** to power on/off as needed
- **Elastic scaling** for CPU, memory, and disk resources

This setup uses:
- **GCloud Compute VM**: Ubuntu with Docker and ISO building tools
- **Cloud Storage Bucket**: Stores large files (iso-artifacts), mounted via gcsfuse
- **Script-based ISO builder**: Fully automated, headless approach
- **Local SSDs**: Ultra-fast scratch space for builds (750GB default)
- **Elastic resources**: Scale CPU/memory/disk on-demand
- **Cost Optimization**: Stop VM when not in use, only pay for storage
- **Easy Management**: Simple scripts for start/stop/ssh/status/scaling

## ISO Creation Method

**Fully Automated Script-Based Approach:**

**Advantages:**
- ✅ Fully automated - no GUI needed
- ✅ Works perfectly on headless GCloud VMs
- ✅ Faster and more reliable
- ✅ Easy to debug and customize
- ✅ Elastic scaling capabilities
- ✅ No X11 forwarding required

**How it works:**
1. Run `bash iso-prepare.sh` to download dependencies (~1-1.5 hours)
2. Run `bash create-custom-iso.sh` to build the ISO (~30-45 minutes)
3. Script extracts ISO, modifies filesystem, repacks it
4. Output: `ubuntu-24.04.3-homelab-amd64.iso`

## Architecture

```
┌─────────────────────────────────────────┐
│  Your Local Machine                     │
│  ├─ gcloud CLI                          │
│  ├─ gcloud-iso-setup.sh (one-time)     │
│  └─ gcloud-iso-vm.sh (management)      │
└─────────────────────────────────────────┘
              │
              │ gcloud commands
              ▼
┌─────────────────────────────────────────┐
│  Google Cloud                           │
│                                         │
│  ┌────────────────────────────────┐    │
│  │ Compute Engine VM (iso-builder)│    │
│  │ ├─ Ubuntu 22.04 LTS            │    │
│  │ ├─ Docker Engine               │    │
│  │ ├─ xorriso + squashfs-tools    │    │
│  │ ├─ gcsfuse (bucket mounting)   │    │
│  │ ├─ ~/iso-artifacts/ (mount)    │    │
│  │ └─ /mnt/disks/ssd (local SSD)  │    │
│  └────────────────────────────────┘    │
│              │                          │
│              │ gcsfuse mount            │
│              ▼                          │
│  ┌────────────────────────────────┐    │
│  │ Cloud Storage Bucket           │    │
│  │ ├─ docker-images/   (~30 GB)   │    │
│  │ ├─ ollama-models/   (~80 GB)   │    │
│  │ └─ homelab/         (scripts)  │    │
│  └────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

## Performance Optimizations

This setup includes significant performance optimizations for faster ISO builds:

### Speed Improvements
- **Overall**: ~60% faster execution (2.5-4 hours → 1-1.5 hours for first build)
- **Docker images**: 45-60min → 12-18min (60-70% faster)
- **Ollama models**: 90-120min → 50-70min (35-45% faster)

### Key Optimizations
1. **Parallel Downloads**: 4 concurrent Docker image downloads instead of sequential
2. **Fast Compression**: pigz (parallel gzip) provides 4-8x faster compression than standard gzip
3. **Parallel GCS Uploads**: 8 threads with 150MB composite upload threshold
4. **SSD Storage**: pd-ssd persistent disks + local SSDs for ultra-fast I/O
5. **Smart Caching**: Checks GCS before downloading from original sources
6. **Automated Execution**: No user prompts - fully hands-off operation
7. **Elastic Scaling**: Scale resources up during build, down when idle

### Technical Details
- **MAX_PARALLEL_DOWNLOADS**: 4 (configurable in iso-prepare.sh)
- **Compression**: pigz with automatic CPU detection
- **GCS Configuration**: Parallel composite uploads via /etc/boto.cfg
- **Job Control**: Background processes with wait for completion
- **Status Tracking**: Temp files for clean output summary
- **Local SSDs**: 2 × 375GB = 750GB of ultra-fast scratch space

## Prerequisites

### On Your Local Machine

1. **Install gcloud CLI**
   ```bash
   # Installation instructions:
   # https://cloud.google.com/sdk/docs/install

   # Verify installation
   gcloud --version
   ```

2. **Authenticate and Configure**
   ```bash
   # Login to Google Cloud
   gcloud auth login

   # Set your project
   gcloud config set project YOUR_PROJECT_ID

   # List available projects
   gcloud projects list
   ```

3. **Enable Required APIs**
   ```bash
   # Enable Compute Engine API
   gcloud services enable compute.googleapis.com

   # Enable Cloud Storage API
   gcloud services enable storage.googleapis.com
   ```

### Google Cloud Account

- **Active GCP Project** with billing enabled
- **Permissions**: Compute Admin, Storage Admin (or Owner role)
- **Billing**: Understand VM costs (~$0.76/hour for n2-standard-16)

## Quick Start

### Step 1: Create the VM and Bucket

```bash
# Clone this repository
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script

# Make setup script executable
chmod +x gcloud-iso-setup.sh

# Run setup (interactive)
./gcloud-iso-setup.sh
```

**What this does:**
1. Creates a Cloud Storage bucket for large files
2. Creates a VM with Docker and ISO building tools
3. Configures gcsfuse for bucket mounting
4. Sets up local SSDs for fast scratch space
5. Creates management scripts
6. Installs helper scripts on the VM

**Interactive Prompts:**
- VM name (default: `iso-builder`)
- Zone (default: `us-west1-a`)
- Machine type (default: `n2-standard-16` - 16 vCPU, 64GB RAM)
- Boot disk size (default: `500GB`)
- Local SSD count (default: `2` × 375GB = 750GB)
- Storage bucket name (required)

**Recommended Configuration:**
- **Machine type**: `n2-standard-16` (16 vCPU, 64GB RAM) - fast builds
- **Boot disk**: `500GB` pd-ssd - OS and persistent storage
- **Local SSDs**: `2` (750GB) - ultra-fast scratch for builds
- **Zone**: Choose closest to your location for better latency

**Note on Local SSDs:**
- N2 machine types support: 0, 2, 4, 8, 16, or 24 SSDs (not 1)
- Each SSD is 375GB
- 10x faster than persistent disks
- Ephemeral (deleted when VM stops) - perfect for temporary build files

**Duration**: 5-10 minutes (VM initialization takes 3-5 minutes)

### Step 2: Wait for Initialization

The VM runs a startup script that installs all dependencies:

```bash
# Monitor initialization progress
gcloud compute ssh iso-builder -- tail -f /var/log/iso-setup.log
```

**Installed on VM:**
- Docker Engine
- xorriso (ISO creation)
- squashfs-tools (filesystem modification)
- gcsfuse (bucket mounting)
- pigz (parallel compression)
- Local SSD mounted at `/mnt/disks/ssd`

**Initialization time**: 3-5 minutes

### Step 3: Connect and Mount Bucket

```bash
# Connect to VM using management script
./gcloud-iso-vm.sh ssh

# Or connect directly
gcloud compute ssh iso-builder --zone=us-west1-a
```

**On the VM, mount the storage bucket:**

```bash
# Mount bucket
~/mount-bucket.sh

# Verify mount
ls ~/iso-artifacts
```

### Step 4: Clone Repository and Prepare

```bash
# Clone repository into bucket-mounted directory
cd ~/iso-artifacts

# If directory exists, update it; otherwise clone fresh
if [ -d "Homelab-Install-Script" ]; then
    cd Homelab-Install-Script
    git pull
else
    git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
    cd Homelab-Install-Script
fi

# IMPORTANT: gcsfuse-mounted filesystems don't support chmod properly
# Run scripts with 'bash' prefix instead of making them executable
# Or copy to local SSD for best performance (recommended)

# Download all dependencies (~1-1.5 hours with optimizations)
bash iso-prepare.sh
```

**What this downloads:**
- Ubuntu Server 24.04.3 ISO (~2.5GB)
- 16 Docker images (~20-30GB total)
- 4 Ollama AI models (~50-80GB total)

**Duration**: 1-1.5 hours for first run (with optimizations)
- Subsequent runs: Much faster (only downloads updates)

### Step 5: Build the Custom ISO

```bash
# Build the ISO (~30-45 minutes)
bash create-custom-iso.sh
```

**What this does:**
1. Extracts Ubuntu Server ISO
2. Extracts squashfs filesystem
3. Copies homelab scripts and dependencies
4. Repacks squashfs
5. Creates new bootable ISO

**Build location**: Uses `/mnt/disks/ssd/iso-build` if available (much faster!)

**Output**: `iso-artifacts/ubuntu-24.04.3-homelab-amd64.iso`

**Duration**: 30-45 minutes

### Step 6: Download the ISO

```bash
# Download from VM to local machine
./gcloud-iso-vm.sh download ~/Downloads/

# Or use gsutil directly
gsutil cp gs://your-bucket-name/ubuntu-24.04.3-homelab-amd64.iso ~/Downloads/
```

### Step 7: Stop the VM

```bash
# Stop VM to save costs
./gcloud-iso-vm.sh stop
```

## Elastic Scaling

Scale resources on-demand for faster builds or cost savings:

### Increase Disk Space

```bash
# Increase boot disk to 1TB (can do while VM is running!)
./gcloud-iso-vm.sh resize-disk 1000

# Then on VM, expand the filesystem:
sudo resize2fs /dev/sda1
```

### Scale CPU and Memory

```bash
# Scale up for heavy builds (requires VM stop)
./gcloud-iso-vm.sh change-machine n2-standard-32   # 32 vCPU, 128GB RAM

# Or for memory-intensive operations
./gcloud-iso-vm.sh change-machine n2-highmem-16    # 16 vCPU, 128GB RAM

# Start VM after changing
./gcloud-iso-vm.sh start
```

### Available Machine Types

| Machine Type | vCPU | RAM | Use Case | Cost/hour |
|--------------|------|-----|----------|-----------|
| n2-standard-8 | 8 | 32GB | Light workloads | ~$0.38 |
| n2-standard-16 | 16 | 64GB | Recommended | ~$0.76 |
| n2-standard-32 | 32 | 128GB | Heavy builds | ~$1.52 |
| n2-highmem-16 | 16 | 128GB | Memory-intensive | ~$1.08 |

### Cost Optimization Strategy

```bash
# Before starting build: Scale up for speed
./gcloud-iso-vm.sh stop
./gcloud-iso-vm.sh change-machine n2-standard-32
./gcloud-iso-vm.sh start

# Do your build (fast!)

# After build: Scale back down
./gcloud-iso-vm.sh stop
./gcloud-iso-vm.sh change-machine n2-standard-16
```

## Management Scripts

### VM Management (`gcloud-iso-vm.sh`)

Created during setup, provides easy VM control:

```bash
# Show VM status
./gcloud-iso-vm.sh status

# Start/stop VM
./gcloud-iso-vm.sh start
./gcloud-iso-vm.sh stop

# SSH into VM
./gcloud-iso-vm.sh ssh

# Show all commands
./gcloud-iso-vm.sh info

# Elastic scaling
./gcloud-iso-vm.sh resize-disk 1000
./gcloud-iso-vm.sh change-machine n2-standard-32

# Bucket operations
./gcloud-iso-vm.sh bucket              # List contents
./gcloud-iso-vm.sh upload ./local-dir  # Upload to bucket
./gcloud-iso-vm.sh download ./local    # Download from bucket

# Delete VM (keeps bucket)
./gcloud-iso-vm.sh delete
```

### Bucket Mounting (on VM)

Helper scripts are automatically created on the VM:

```bash
# Mount bucket
~/mount-bucket.sh

# Unmount bucket
~/unmount-bucket.sh

# Verify mount
mountpoint ~/iso-artifacts
```

## Cost Analysis

### VM Costs (n2-standard-16 in us-west1)

**Running costs** (~$0.76/hour):
- 16 vCPU: ~$0.48/hour
- 64GB RAM: ~$0.28/hour
- 2 × local SSDs: ~$0.20/hour
- Total: ~$0.96/hour

**Monthly if running 24/7**: ~$700/month

**Realistic usage** (4 hours/week):
- 4 hours × 4 weeks × $0.96 = ~$15.36/month

### Storage Costs

**Cloud Storage bucket** (~$0.020/GB/month):
- Base artifacts (70-110GB): ~$1.40-2.20/month
- ISOs (5-10GB each): ~$0.10-0.20/month each

**Persistent disk (500GB pd-ssd)**: ~$85/month
- Only charged when VM exists (not running)
- Delete when done if one-time use

### Total Monthly Cost Examples

**Light use** (2 ISO builds/month, 8 hours total):
- VM runtime: 8 × $0.96 = ~$7.68
- Storage: ~$2
- Persistent disk: ~$85 (delete after use: $0)
- **Total: ~$10-95/month** (depending on disk retention)

**Heavy use** (weekly builds, 16 hours/month):
- VM runtime: 16 × $0.96 = ~$15.36
- Storage: ~$2
- Persistent disk: ~$85 (or delete)
- **Total: ~$17-102/month**

**Cost savings tip:** Delete the VM when done, only keep the bucket!

## Workflow Summary

### One-Time Setup (10 minutes)

```bash
# 1. Create VM and bucket
./gcloud-iso-setup.sh

# 2. Wait for initialization (3-5 minutes)
gcloud compute ssh iso-builder -- tail -f /var/log/iso-setup.log
```

### Each ISO Build (1.5-2 hours)

```bash
# 3. Start VM if stopped
./gcloud-iso-vm.sh start

# 4. Connect to VM
./gcloud-iso-vm.sh ssh

# 5. Mount bucket (on VM)
~/mount-bucket.sh

# 6. Prepare dependencies (first time only: ~1.5 hours)
cd ~/iso-artifacts
if [ -d "Homelab-Install-Script" ]; then
    cd Homelab-Install-Script
    git pull
else
    git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
    cd Homelab-Install-Script
fi
bash iso-prepare.sh

# 7. Build ISO (~30-45 minutes)
bash create-custom-iso.sh

# 8. Download ISO (on local machine)
./gcloud-iso-vm.sh download ~/Downloads/

# 9. Stop VM to save costs
./gcloud-iso-vm.sh stop
```

## File Locations

### On VM

- **Bucket mount**: `~/iso-artifacts/` (FUSE mount to Cloud Storage)
- **Local SSD**: `/mnt/disks/ssd/` (750GB ultra-fast scratch)
- **Build directory**: `/mnt/disks/ssd/iso-build/` (auto-used by create-custom-iso.sh)
- **Logs**: `/var/log/iso-setup.log`
- **Helper scripts**: `~/mount-bucket.sh`, `~/unmount-bucket.sh`

### In Cloud Storage Bucket

```
gs://your-bucket-name/
├── docker-images/              # ~20-30GB (Docker image archives)
├── ollama-models/              # ~50-80GB (AI model archives)
├── homelab/                    # Homelab scripts
└── ubuntu-24.04.3-live-server-amd64.iso  # Base ISO
```

### Output ISO

**Location**: `~/iso-artifacts/ubuntu-24.04.3-homelab-amd64.iso`

**Size**: ~8-12GB (depends on Docker images and models included)

## Storage Strategy

The setup uses a hybrid approach to optimize disk usage:

### Cloud Storage Bucket (Permanent)
- **Purpose**: Long-term storage for large files
- **Contents**: Docker images, Ollama models, Ubuntu ISO
- **Access**: Mounted at `~/iso-artifacts` via gcsfuse
- **Cost**: ~$0.020/GB/month
- **Speed**: Good for sequential reads, slower for random access
- **Retention**: Keep forever, accessible from any VM

### Local SSD (Temporary)
- **Purpose**: Ultra-fast scratch space for builds
- **Contents**: Temporary build files (extracted ISO, squashfs)
- **Location**: `/mnt/disks/ssd/iso-build/`
- **Cost**: ~$0.10/GB/hour (only when VM running)
- **Speed**: 10x faster than persistent disks
- **Retention**: **Deleted when VM stops** (ephemeral)

### Boot Disk (Semi-Permanent)
- **Purpose**: OS, Docker, downloaded source files for building
- **Size**: 500GB pd-ssd
- **Cost**: ~$0.17/GB/month (~$85/month for 500GB)
- **Retention**: Persists when VM stops, deleted when VM deleted

## Troubleshooting

### VM Won't Start

**Check quota limits:**
```bash
gcloud compute project-info describe --project=YOUR_PROJECT_ID
```

**Look for quota errors:**
- CPUs, disks, or SSDs might be at quota limit
- Request quota increase or use smaller machine type

### Can't SSH Into VM

**1. Check VM is running:**
```bash
./gcloud-iso-vm.sh status
```

**2. Check firewall rules:**
```bash
gcloud compute firewall-rules list --filter="name~'default-allow-ssh'"
```

**3. Try direct connection:**
```bash
gcloud compute ssh iso-builder --zone=us-west1-a --troubleshoot
```

### Bucket Won't Mount

**Problem**: `~/mount-bucket.sh` fails or `~/iso-artifacts` is empty

**Solution 1 - Check bucket name in metadata:**
```bash
curl -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name
```

**Solution 2 - Verify bucket access:**
```bash
gsutil ls gs://your-bucket-name
```

**Solution 3 - Manual mount:**
```bash
mkdir -p ~/iso-artifacts
gcsfuse --implicit-dirs your-bucket-name ~/iso-artifacts
```

### Out of Disk Space

**Check disk usage:**
```bash
df -h
```

**Solution 1 - Increase boot disk size:**
```bash
# Increase disk (can do while running!)
./gcloud-iso-vm.sh resize-disk 1000

# Expand filesystem on VM
sudo resize2fs /dev/sda1
```

**Solution 2 - Clean up build artifacts:**
```bash
# Remove temporary build files (on VM)
rm -rf /mnt/disks/ssd/iso-build/*
rm -rf ~/iso-artifacts/Homelab-Install-Script/iso-build/*
```

### ISO Build Fails

**Check available space:**
```bash
df -h /mnt/disks/ssd
df -h ~/iso-artifacts
```

**Check logs:**
```bash
# Last 100 lines of create-custom-iso.sh output
tail -100 ~/iso-artifacts/Homelab-Install-Script/create-custom-iso.log
```

**Common issues:**
- Out of space: Increase disk or use local SSD
- Missing dependencies: Re-run `bash iso-prepare.sh`
- Corrupted downloads: Delete and re-download

### Slow Build Performance

**Solution 1 - Scale up machine:**
```bash
./gcloud-iso-vm.sh stop
./gcloud-iso-vm.sh change-machine n2-standard-32
./gcloud-iso-vm.sh start
```

**Solution 2 - Verify local SSD usage:**
```bash
# Check if build is using local SSD
ls -la /mnt/disks/ssd/iso-build/

# If empty, local SSD not detected
# Check SSD mount:
df -h | grep ssd
```

**Solution 3 - Check network throttling:**
```bash
# GCS transfer speeds
gsutil perfdiag gs://your-bucket-name
```

### Local SSD Not Available

**Problem**: `/mnt/disks/ssd` doesn't exist or shows no space

**Cause**: VM doesn't have local SSDs attached

**Solution - Add SSDs when creating VM:**
```bash
# Delete and recreate with SSDs
./gcloud-iso-vm.sh delete
./gcloud-iso-setup.sh  # Choose 2 or more SSDs when prompted
```

**Note**: Can't add local SSDs to running VM, must recreate

## Advanced Configuration

### Customize VM Configuration

Edit `gcloud-iso-setup.sh` before running:

```bash
# Default configuration variables (line ~42)
VM_NAME="iso-builder"
ZONE="us-west1-a"
MACHINE_TYPE="n2-standard-16"
BOOT_DISK_SIZE="500GB"
LOCAL_SSD_COUNT="2"
BUCKET_NAME="cloud-ai-server-iso-artifacts"
```

### Use Different Zones

**List available zones:**
```bash
gcloud compute zones list
```

**Pricing varies by zone:**
- `us-west1` (Oregon): Standard pricing
- `us-central1` (Iowa): Standard pricing
- `us-east1` (South Carolina): Standard pricing
- `europe-west1` (Belgium): ~10% higher
- `asia-southeast1` (Singapore): ~10% higher

### Increase Parallel Downloads

Edit `iso-prepare.sh` (line ~46):

```bash
# Change from 4 to 8 for faster downloads (needs more CPU/memory)
MAX_PARALLEL_DOWNLOADS=8
```

### Add More Local SSDs

During VM creation, choose more SSDs for even faster builds:
- 4 SSDs = 1.5TB scratch space
- 8 SSDs = 3TB scratch space

**Cost**: ~$0.10/GB/hour per SSD (only when running)

## Monitoring and Logs

### Check VM Logs

```bash
# Startup script log
gcloud compute ssh iso-builder -- tail -f /var/log/iso-setup.log

# System log
gcloud compute ssh iso-builder -- sudo journalctl -f
```

### Monitor Resource Usage

```bash
# Connect to VM
./gcloud-iso-vm.sh ssh

# CPU and memory
htop

# Disk usage
df -h

# Disk I/O
iostat -x 1

# Network usage
iftop
```

### GCS Transfer Logs

```bash
# Check gsutil transfer logs (on VM)
ls ~/.gsutil/
cat ~/.gsutil/tracker-files/*
```

## Cleanup

### After Build is Complete

**Option 1: Keep everything (resume builds later)**
```bash
# Just stop the VM
./gcloud-iso-vm.sh stop
```

**Option 2: Delete VM, keep bucket (recommended)**
```bash
# Delete VM (keeps all files in bucket)
./gcloud-iso-vm.sh delete

# Later, create new VM pointing to same bucket
./gcloud-iso-setup.sh  # Use same bucket name
```

**Option 3: Delete everything**
```bash
# Delete VM
./gcloud-iso-vm.sh delete

# Delete bucket (WARNING: loses all files!)
gsutil rm -r gs://your-bucket-name
```

### Cost Comparison

| Option | Monthly Cost | Resume Speed | Data Safety |
|--------|-------------|--------------|-------------|
| Stop VM | ~$87 (disk) | Instant | ✅ Safe |
| Delete VM | ~$2 (bucket) | 5 min setup | ✅ Safe |
| Delete All | $0 | 2 hours rebuild | ❌ Lost |

**Recommendation**: Delete VM, keep bucket (~$2/month, instant resume)

## Additional Resources

- [ISO Preparation Script (iso-prepare.sh)](iso-prepare.sh)
- [ISO Building Script (create-custom-iso.sh)](create-custom-iso.sh)
- [Main Project Documentation](README.md)
- [GCloud Compute Engine Pricing](https://cloud.google.com/compute/pricing)
- [GCloud Storage Pricing](https://cloud.google.com/storage/pricing)
- [xorriso Documentation](https://www.gnu.org/software/xorriso/)
- [squashfs-tools Documentation](https://github.com/plougher/squashfs-tools)
