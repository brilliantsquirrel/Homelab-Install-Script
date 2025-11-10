# Google Cloud VM Setup for Custom Ubuntu ISO Creation

This guide explains how to set up a Google Cloud VM for creating custom Ubuntu ISOs with large file storage in Cloud Storage buckets.

## Overview

Creating custom Ubuntu ISOs for homelab deployment requires:
- **70-110GB** of storage for Docker images and Ollama models
- **Significant compute** for downloading and processing (optimized for **60% faster execution**)
- **Flexibility** to power on/off as needed

This setup uses:
- **GCloud Compute VM**: Ubuntu with Docker and ISO building tools
- **Cloud Storage Bucket**: Stores large files (iso-artifacts), mounted via gcsfuse
- **Script-based ISO builder**: Fully automated, no GUI required (recommended)
- **Alternative: Cubic GUI**: Traditional GUI-based approach (requires X11 forwarding)
- **Cost Optimization**: Stop VM when not in use, only pay for storage
- **Easy Management**: Simple scripts for start/stop/ssh/status

## ISO Creation Methods

### Method 1: Script-Based (Recommended ⭐)

**Advantages:**
- ✅ Fully automated - no GUI needed
- ✅ Works perfectly on headless GCloud VMs
- ✅ Faster and more reliable
- ✅ Easy to debug and customize
- ✅ No X11 forwarding required

**How it works:**
1. Run `./iso-prepare.sh` to download dependencies
2. Run `./create-custom-iso.sh` to build the ISO
3. Script extracts ISO, modifies filesystem, repacks it
4. Output: `ubuntu-24.04.3-homelab-amd64.iso`

### Method 2: Cubic GUI (Alternative)

**Advantages:**
- ✅ Visual interface
- ✅ More interactive control

**Disadvantages:**
- ❌ Requires X11 forwarding (slower over network)
- ❌ Can have ISO mounting issues with FUSE filesystems
- ❌ More complex troubleshooting

**Use when:** You prefer a GUI and are familiar with Cubic

## Architecture

```
┌─────────────────────────────────────────┐
│  Your Local Machine                     │
│  ├─ gcloud CLI                          │
│  ├─ gcloud-iso-setup.sh (one-time)    │
│  └─ gcloud-iso-vm.sh (management)     │
└─────────────────────────────────────────┘
              │
              │ gcloud commands
              ▼
┌─────────────────────────────────────────┐
│  Google Cloud                           │
│                                         │
│  ┌────────────────────────────────┐    │
│  │ Compute Engine VM              │    │
│  │ ├─ Ubuntu 24.04 LTS            │    │
│  │ ├─ Docker + Cubic              │    │
│  │ ├─ Desktop Environment         │    │
│  │ ├─ gcsfuse (bucket mounting)   │    │
│  │ └─ ~/iso-artifacts/ (mount)  │    │
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
4. **SSD Storage**: pd-ssd persistent disks for faster I/O vs pd-balanced
5. **Smart Caching**: Checks GCS before downloading from original sources
6. **Automated Execution**: No user prompts - fully hands-off operation

### Technical Details
- **MAX_PARALLEL_DOWNLOADS**: 4 (configurable in iso-prepare.sh)
- **Compression**: pigz with automatic CPU detection
- **GCS Configuration**: Parallel composite uploads via /etc/boto.cfg
- **Job Control**: Background processes with wait for completion
- **Status Tracking**: Temp files for clean output summary

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
- **Billing**: Understand VM costs (~$0.30-0.50/hour for n2-standard-8)

## Quick Start (Script-Based Method)

This is the recommended approach - fully automated with no GUI required.

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
2. Creates a VM with Docker, Cubic, and desktop environment
3. Configures gcsfuse for bucket mounting
4. Creates management scripts
5. Installs helper scripts on the VM

**Interactive Prompts:**
- VM name (default: `cubic-builder`)
- Zone (default: `us-central1-a`)
- Machine type (default: `n2-standard-8` - 8 vCPU, 32GB RAM)
- Boot disk size (default: `200GB`)
- Storage bucket name (required)

**Recommended Configuration:**
- **Machine type**: `n2-standard-8` (8 vCPU, 32GB RAM) - good balance
- **Boot disk**: `200GB` - OS, temp files, Cubic working directory, ISO building (~150GB needed for full ISO with images/models)
- **Zone**: Choose closest to your location for better latency

**Duration**: 10-15 minutes (VM initialization takes 5-10 minutes)

### Step 2: Wait for Initialization

The VM runs a startup script that installs all dependencies:

```bash
# Monitor initialization progress
gcloud compute ssh cubic-builder -- tail -f /var/log/cubic-setup.log
```

**Installed on VM:**
- Ubuntu Desktop (minimal)
- Docker Engine
- Cubic (ISO creator)
- gcsfuse (Cloud Storage mounting)
- Git, rsync, and build tools

**When complete**, you'll see: `VM initialization complete!`

### Step 3: Connect and Mount Storage

```bash
# Connect to VM with X11 forwarding (for Cubic GUI)
./gcloud-iso-vm.sh ssh

# On the VM, mount the storage bucket
~/mount-bucket.sh
```

This mounts the Cloud Storage bucket at `~/iso-artifacts/`.

### Step 4: Prepare Dependencies

```bash
# On the VM, clone the repository
cd ~
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script

# Set the GCS bucket environment variable (auto-detected from VM metadata)
export GCS_BUCKET=gs://$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name" -H "Metadata-Flavor: Google")

# Download all dependencies (70-110GB, takes 1-1.5 hours with optimizations)
# Runs fully automated - no prompts required
# Features: parallel downloads (4 concurrent), fast compression (pigz), parallel GCS uploads
./iso-prepare.sh
```

**How it works**:
- Downloads Ubuntu ISO, Docker images (16 images), and Ollama models (4 models)
- **Performance optimizations**:
  - Parallel Docker image downloads (4 concurrent streams)
  - Fast compression with pigz (4-8x faster than gzip)
  - Parallel GCS uploads (8 threads, 150MB composite threshold)
  - SSD persistent disks (pd-ssd) for faster I/O
  - Smart caching: checks GCS before downloading from source
- Automatically uploads each file to GCS bucket after creation
- Verifies the upload succeeded before cleanup
- Keeps Ubuntu ISO locally (required by Cubic GUI)
- Deletes Docker images and models after GCS upload (~50-80GB saved)
- Files persist in GCS bucket even if VM is deleted
- On subsequent runs, downloads from GCS (much faster than original sources)
- **Result**: ~60% faster execution (2.5-4 hours → 1-1.5 hours)

### Step 5: Mount Bucket and Access Files

```bash
# On the VM, mount the bucket to access uploaded files
~/mount-bucket.sh
```

This mounts the GCS bucket at `~/iso-artifacts/`, giving you access to all files uploaded by `iso-prepare.sh`.

### Step 6: Create Custom ISO (Script-Based)

```bash
# On the VM, run the automated ISO builder
cd ~/Homelab-Install-Script
./create-custom-iso.sh
```

**What this script does:**
1. Extracts the Ubuntu ISO (~5 minutes)
2. Extracts the squashfs filesystem (~5-10 minutes)
3. Copies homelab scripts to `/opt/homelab` in the ISO
4. Copies Docker images from GCS bucket (~10-15 minutes)
5. Copies Ollama models from GCS bucket (~20-30 minutes)
6. Creates first-boot setup script (auto-loads Docker images and models)
7. Repacks squashfs filesystem (~5-10 minutes)
8. Creates new bootable ISO

**Total time:** 45-70 minutes (fully automated, no interaction required)

**Output:** `~/Homelab-Install-Script/iso-artifacts/ubuntu-24.04.3-homelab-amd64.iso`

**What happens on first boot of the custom ISO:**
- Docker images are automatically loaded
- Ollama models are restored to Docker volumes
- Homelab installation script is ready at `/opt/homelab/post-install.sh`
- First-boot logs available at `/var/log/homelab-first-boot.log`

**Alternative: Use Cubic GUI** (see [Cubic GUI Method](#cubic-gui-method-alternative) section below)

### Step 7: Download the ISO

After the script completes:

```bash
# On your local machine, download the ISO
gsutil cp gs://YOUR-BUCKET-NAME/ubuntu-24.04.3-homelab-amd64.iso ./

# Or use the management script
./gcloud-iso-vm.sh download ./my-isos/
```

**ISO Details:**
- **Name:** `ubuntu-24.04.3-homelab-amd64.iso`
- **Size:** ~4-6GB (depending on included models)
- **Ready to boot:** Hybrid ISO works on both BIOS and UEFI
- **Write to USB:** `dd if=ubuntu-24.04.3-homelab-amd64.iso of=/dev/sdX bs=4M status=progress`

### Step 8: Stop the VM (Save Costs!)

```bash
# Stop the VM when not in use
./gcloud-iso-vm.sh stop
```

**Cost Savings:**
- **Running VM**: ~$0.30-0.50/hour (n2-standard-8)
- **Stopped VM**: $0/hour (only pay for storage)
- **Storage**: ~$2-3/month for 100GB bucket

## VM Management

The `gcloud-iso-vm.sh` script provides easy VM management:

### Check Status

```bash
./gcloud-iso-vm.sh status
```

Shows VM state, IP address, and machine type.

### Start/Stop VM

```bash
# Start the VM
./gcloud-iso-vm.sh start

# Stop the VM (saves money!)
./gcloud-iso-vm.sh stop
```

### SSH Access

```bash
# Connect via SSH with X11 forwarding
./gcloud-iso-vm.sh ssh
```

This enables you to run GUI applications like Cubic.

### Bucket Operations

```bash
# View bucket contents
./gcloud-iso-vm.sh bucket

# Upload local files to bucket
./gcloud-iso-vm.sh upload /local/path/

# Download bucket to local
./gcloud-iso-vm.sh download /local/path/
```

### Setup Mount Scripts

If the mount scripts are missing from the VM:

```bash
# Create mount-bucket.sh and unmount-bucket.sh on the VM
./gcloud-iso-vm.sh setup-scripts
```

This creates the bucket mounting scripts directly on the VM via SSH.

### View All Commands

```bash
./gcloud-iso-vm.sh info
```

## Storage Bucket Management

### Mounting the Bucket (On VM)

```bash
# Mount bucket
~/mount-bucket.sh

# Verify mount
ls -lh ~/iso-artifacts/
```

The bucket is mounted with `gcsfuse`, which provides POSIX-like filesystem access to Cloud Storage.

### Unmounting the Bucket (On VM)

```bash
# Unmount bucket
~/unmount-bucket.sh
```

**When to unmount:**
- Before stopping the VM (optional, but clean)
- When troubleshooting mount issues

### Direct Bucket Access (Local Machine)

```bash
# List bucket contents
gsutil ls gs://YOUR-BUCKET-NAME/

# Upload files
gsutil cp -r /local/path/ gs://YOUR-BUCKET-NAME/

# Download files
gsutil cp -r gs://YOUR-BUCKET-NAME/ /local/path/

# Sync directories
gsutil -m rsync -r /local/path/ gs://YOUR-BUCKET-NAME/
```

## Cost Management

### VM Costs

**Running Costs** (per hour):
- `n2-standard-8` (8 vCPU, 32GB RAM): ~$0.30-0.50/hour
- 200GB boot disk: ~$0.02/hour
- Network egress: Variable

**Stopped VM Costs**: $0/hour for compute, only storage costs

**Monthly Estimate** (if running 24/7):
- VM: ~$220-360/month
- Boot disk: ~$20/month
- **Total**: ~$240-380/month

**Recommended Usage**:
- Run VM only when building ISOs
- Stop VM immediately after work is done
- Typical usage: 5-10 hours/month = **$2-5/month** (plus storage)

### Storage Costs

**Cloud Storage Pricing** (Standard storage):
- First 100GB: ~$2-3/month
- Cubic artifacts (70-110GB): ~$2-3/month
- Boot disk (200GB): ~$20/month

**Total Storage**: ~$22-23/month

### Cost Optimization Tips

1. **Stop VM when not in use** - Most important!
   ```bash
   ./gcloud-iso-vm.sh stop
   ```

2. **Use preemptible/spot VMs** - 60-91% cheaper (edit setup script)
   - Caution: Can be terminated at any time
   - Good for non-urgent ISO builds

3. **Delete VM after ISO creation** - Keep only the bucket
   ```bash
   ./gcloud-iso-vm.sh delete
   # Bucket remains intact, recreate VM when needed
   ```

4. **Archive old ISOs** - Move to Nearline/Coldline storage
   ```bash
   gsutil mv gs://BUCKET/old.iso gs://ARCHIVE-BUCKET/old.iso
   ```

5. **Choose the right machine type**
   - `n2-standard-4` (4 vCPU, 16GB): Slower but cheaper (~$0.15/hour)
   - `n2-standard-8` (8 vCPU, 32GB): Good balance (~$0.30/hour)
   - `n2-standard-16` (16 vCPU, 64GB): Faster but expensive (~$0.60/hour)

## Troubleshooting

### VM Won't Start

**Problem**: VM fails to start

**Check:**
```bash
# View VM status
./gcloud-iso-vm.sh status

# Check serial console output
gcloud compute instances get-serial-port-output cubic-builder --zone=us-central1-a
```

**Common causes:**
- Quota exceeded (check GCP quotas)
- Zone unavailable (try different zone)
- Billing issue (check payment method)

### Bucket Won't Mount

**Problem**: `~/mount-bucket.sh` fails

**Check:**
```bash
# On VM, check if gcsfuse is installed
which gcsfuse

# Check bucket permissions
gsutil ls gs://YOUR-BUCKET-NAME/

# Check existing mounts
mount | grep gcsfuse
```

**Fix:**
```bash
# Unmount if stuck
fusermount -u ~/iso-artifacts

# Re-mount
~/mount-bucket.sh
```

**Permissions issue:**
```bash
# On local machine, grant VM access to bucket
gcloud projects add-iam-policy-binding YOUR-PROJECT-ID \
  --member=serviceAccount:PROJECT-NUMBER-compute@developer.gserviceaccount.com \
  --role=roles/storage.admin
```

### Cubic Error: "Original disk image is required"

**Problem**: Cubic GUI shows error: "The original disk image is required to copy important files and extract the Linux file system, but it is not available."

**Root Cause**: The ISO is in the GCS bucket mount (`~/iso-artifacts/`), not on local disk. Cubic requires the ISO on a real filesystem, not a FUSE mount.

**Solution:**
```bash
# 1. Verify where your repo is located
pwd
# Should be: /home/ubuntu/Homelab-Install-Script
# NOT: /home/ubuntu/iso-artifacts/Homelab-Install-Script

# 2. If repo is in wrong location, move it to local disk
cd ~
# If the repo is in the bucket mount:
if [ -d ~/iso-artifacts/Homelab-Install-Script ]; then
    mv ~/iso-artifacts/Homelab-Install-Script ~/
fi

# 3. Re-run iso-prepare.sh from the correct location
cd ~/Homelab-Install-Script
./iso-prepare.sh

# 4. Verify ISO is on local disk
ls -lh ~/Homelab-Install-Script/iso-artifacts/*.iso
# Should show: ubuntu-24.04.3-live-server-amd64.iso

# 5. Check it's NOT in a FUSE mount
df -h ~/Homelab-Install-Script/iso-artifacts/*.iso
# Filesystem should be /dev/sda1 or similar (NOT gcsfuse)

# 6. Launch Cubic and point to LOCAL directory
cubic
# In GUI: Project Directory = /home/ubuntu/Homelab-Install-Script/iso-artifacts
```

**Prevention**: Always clone the repo to `~` (home), not `~/iso-artifacts` (bucket mount).

### Cubic GUI Won't Display

**Problem**: Can't see Cubic GUI when running `cubic`

**Check SSH X11 forwarding:**
```bash
# Reconnect with X11 forwarding
exit  # Exit VM
./gcloud-iso-vm.sh ssh

# Test X11
xclock  # Should show a clock window
```

**Alternative: Use VNC**
```bash
# On VM, start VNC server
vncserver :1

# On local machine, create SSH tunnel
gcloud compute ssh cubic-builder -- -L 5901:localhost:5901

# Connect with VNC viewer
# Address: localhost:5901
```

### Insufficient Disk Space

**Problem**: Boot disk full during ISO creation

**Check:**
```bash
# On VM
df -h
du -sh ~/iso-artifacts
```

**Fix - Increase boot disk:**
```bash
# On local machine
gcloud compute disks resize cubic-builder \
  --size=200GB \
  --zone=us-central1-a

# On VM, resize filesystem
sudo resize2fs /dev/sda1
```

### Slow Download Speeds

**Problem**: `iso-prepare.sh` downloads very slowly

**Causes:**
- VM region far from Docker Hub
- Network throttling

**Fix:**
```bash
# Use a different zone closer to Docker Hub (US East)
./gcloud-iso-setup.sh
# Choose zone: us-east1-a or us-east1-b
```

### Docker Pull Fails

**Problem**: Docker image pulls fail during `iso-prepare.sh`

**Check:**
```bash
# On VM
sudo docker info
sudo systemctl status docker
```

**Fix:**
```bash
# Restart Docker
sudo systemctl restart docker

# Add user to docker group if needed
sudo usermod -aG docker $USER
# Log out and back in
```

### GCS Bucket Uploads Fail (boto.cfg Error)

**Problem**: `iso-prepare.sh` completes but GCS bucket is empty, or you see:
```
DuplicateSectionError: section 'GSUtil' already exists
```

**Root Cause**: The VM startup script appended GSUtil configuration to `/etc/boto.cfg` multiple times (if VM was restarted), creating duplicate `[GSUtil]` sections that break gsutil.

**Diagnostic Commands:**
```bash
# On VM, check if boto.cfg has duplicate sections
cat /etc/boto.cfg

# Test gsutil functionality
gsutil ls gs://YOUR-BUCKET-NAME/

# Check if metadata service is accessible
curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name"
```

**Quick Fix (on existing VMs):**
```bash
# On VM, recreate boto.cfg with correct configuration
sudo rm /etc/boto.cfg
sudo cat > /etc/boto.cfg << 'EOF'
[GSUtil]
parallel_composite_upload_threshold = 150M
parallel_thread_count = 8
EOF

# Verify gsutil works
gsutil ls gs://YOUR-BUCKET-NAME/
```

**Permanent Fix**: The issue is resolved in the latest version of `gcloud-iso-setup.sh`. The startup script now checks if `[GSUtil]` section exists before creating it. If you created your VM before this fix, either:
1. Use the quick fix above, or
2. Delete and recreate the VM with the updated setup script

**Verify GCS is working:**
```bash
# On VM, test upload
echo "test" > /tmp/test.txt
gsutil cp /tmp/test.txt gs://YOUR-BUCKET-NAME/test.txt
gsutil ls gs://YOUR-BUCKET-NAME/test.txt
gsutil rm gs://YOUR-BUCKET-NAME/test.txt
```

### GCS Bucket Empty After iso-prepare.sh

**Problem**: Script completes successfully but bucket has no files

**Common Causes:**
1. **boto.cfg error** (see section above)
2. **Wrong bucket name** - Script uploaded to different bucket
3. **Metadata service unavailable** - Running on local machine instead of GCloud VM
4. **Permission denied** - VM service account lacks Storage Admin role

**Diagnostic Steps:**
```bash
# 1. Verify you're on a GCloud VM
curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/name"
# Should return VM name, not "Could not resolve host"

# 2. Check which bucket the script is using
echo $GCS_BUCKET
# Or auto-detect from metadata:
curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name"

# 3. Test gsutil access
gsutil ls gs://YOUR-BUCKET-NAME/

# 4. Check boto.cfg for errors
cat /etc/boto.cfg
grep -c "\[GSUtil\]" /etc/boto.cfg  # Should be 1, not 2+

# 5. Review script output
ls -lh ~/iso-artifacts/
# ISO should be present locally
# Docker images and models should be deleted after upload
```

**If running on local machine (not GCloud VM):**
```bash
# iso-prepare.sh requires GCloud VM with:
# - Metadata service for bucket auto-detection
# - Configured gsutil with parallel uploads
# - High-bandwidth connection for large uploads

# Solution: Follow the Quick Start guide to create a GCloud VM
```

### Parallel Downloads Show Errors

**Problem**: Seeing errors during parallel Docker downloads or Ollama model processing

**Expected Behavior**:
- The script runs up to 4 parallel jobs for Docker images
- Each job writes status to temp files
- Summary is displayed after all jobs complete
- Some connection errors are normal and retried automatically

**Check Progress:**
```bash
# On VM during iso-prepare.sh execution
# Watch parallel jobs
watch -n 2 'jobs -r | wc -l'

# Check temp status files
ls -lh /tmp/docker_status_*
ls -lh /tmp/ollama_status_*

# Monitor GCS uploads
watch -n 5 'gsutil ls gs://YOUR-BUCKET-NAME/docker-images/ | wc -l'
```

**If Jobs Hang:**
```bash
# Kill stuck jobs
killall docker
killall gsutil

# Clear temp files
rm -f /tmp/docker_status_* /tmp/ollama_status_*

# Re-run iso-prepare.sh (it will skip already-uploaded files)
./iso-prepare.sh
```

## Advanced Configuration

### Using Preemptible VMs (Cheaper)

Edit `gcloud-iso-setup.sh` and add this flag to the VM creation command:

```bash
--preemptible \
--provisioning-model=SPOT \
```

**Benefits:**
- 60-91% cheaper
- Good for ISO builds that can be restarted

**Drawbacks:**
- Can be terminated at any time
- Maximum 24-hour runtime
- Not suitable for critical work

### Custom Machine Type

```bash
# Edit gcloud-iso-setup.sh
MACHINE_TYPE="n2-custom-4-16384"  # 4 vCPU, 16GB RAM
```

Or during setup, enter a custom machine type when prompted.

### Different Region/Zone

Choose zones based on:
- **Latency**: Closer to your location
- **Cost**: Some regions are cheaper
- **Availability**: Check quota availability

```bash
# During setup
Zone [us-central1-a]: europe-west1-b
```

### Persistent Desktop Session

Install and configure VNC for persistent GUI sessions:

```bash
# On VM
sudo apt-get install -y tightvncserver xfce4

# Start VNC
vncserver :1 -geometry 1920x1080

# Set password when prompted

# On local machine, create tunnel
gcloud compute ssh cubic-builder -- -L 5901:localhost:5901

# Connect with VNC viewer to localhost:5901
```

### Automatic Bucket Mounting on Boot

```bash
# On VM, add to ~/.bashrc
if [ ! -d ~/iso-artifacts ] || ! mountpoint -q ~/iso-artifacts; then
    ~/mount-bucket.sh
fi
```

## Workflow Examples

### Full ISO Build (First Time)

```bash
# 1. Create VM (one-time, 10-15 minutes)
./gcloud-iso-setup.sh

# 2. Wait for initialization
gcloud compute ssh cubic-builder -- tail -f /var/log/cubic-setup.log

# 3. Connect and mount bucket
./gcloud-iso-vm.sh ssh
~/mount-bucket.sh

# 4. Download dependencies (1-1.5 hours with optimizations)
# Fully automated - no prompts
cd ~
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script
./iso-prepare.sh

# 5. Create custom ISO with script (45-70 minutes, fully automated)
./create-custom-iso.sh

# 6. Download ISO to local machine
exit  # Exit VM
./gcloud-iso-vm.sh download ./my-isos/

# 7. Stop VM
./gcloud-iso-vm.sh stop
```

**Total time**: 2.5-3 hours (fully automated, no GUI interaction)
**Cost**: ~$0.75-1.50 (one-time)
**Performance improvements**:
- Parallel Docker downloads (4 concurrent)
- Fast compression with pigz (4-8x faster)
- Parallel GCS uploads (8 threads)
- SSD persistent disks
- No X11 overhead (script-based, no GUI)

### Updating ISO (Subsequent Builds)

```bash
# 1. Start existing VM
./gcloud-iso-vm.sh start

# 2. Connect and mount
./gcloud-iso-vm.sh ssh
~/mount-bucket.sh

# 3. Update dependencies (downloads from GCS, very fast)
cd ~/Homelab-Install-Script
git pull
./iso-prepare.sh  # Skips existing files, only downloads new/updated ones

# 4. Rebuild ISO with script
./create-custom-iso.sh

# 5. Download and stop
exit
./gcloud-iso-vm.sh download ./my-isos/
./gcloud-iso-vm.sh stop
```

**Total time**: 50-80 minutes (most dependencies cached in GCS)
**Cost**: ~$0.25-0.40

### Quick ISO Customization

```bash
# 1. Start VM
./gcloud-iso-vm.sh start
./gcloud-iso-vm.sh ssh

# 2. Mount and launch Cubic
~/mount-bucket.sh
cubic

# 3. Make changes in Cubic GUI
# ... customize ISO ...

# 4. Download and stop
exit
./gcloud-iso-vm.sh download ./my-isos/
./gcloud-iso-vm.sh stop
```

**Total time**: 30-60 minutes
**Cost**: ~$0.30-0.50

## Security Considerations

### VM Security

1. **Firewall Rules**: Default firewall blocks external access
2. **IAM Permissions**: VM uses service account with minimal permissions
3. **SSH Keys**: Uses gcloud-managed SSH keys
4. **Updates**: Startup script updates packages

### Bucket Security

1. **Private by Default**: Bucket is not publicly accessible
2. **IAM Permissions**: Only project members can access
3. **Encryption**: Data encrypted at rest by default

### Best Practices

1. **Use IAM roles** instead of service account keys
2. **Enable VPC Service Controls** for sensitive projects
3. **Audit bucket access** with Cloud Audit Logs
4. **Delete old ISOs** to minimize attack surface
5. **Use short-lived VMs** - create/delete as needed

## Cubic GUI Method (Alternative)

If you prefer a graphical interface or need more manual control over ISO customization, you can use Cubic instead of the automated script.

### Prerequisites for Cubic

The GCloud VM must have desktop environment and X11 forwarding support (already configured by `gcloud-iso-setup.sh`).

### Using Cubic

```bash
# 1. SSH with X11 forwarding
./gcloud-iso-vm.sh ssh  # Or: gcloud compute ssh cubic-builder -- -X

# 2. Test X11 works
xclock  # Should display a clock window

# 3. Launch Cubic
cubic
```

### In Cubic GUI

1. **Project Directory**: `/home/ubuntu/Homelab-Install-Script/iso-artifacts`
   - ⚠️ **IMPORTANT**: Must be on LOCAL disk, NOT the GCS bucket mount (`~/iso-artifacts`)
   - Verify with: `df -h ~/Homelab-Install-Script/iso-artifacts` (should show `/dev/sda1`, NOT `gcsfuse`)

2. **Original ISO**: Select `ubuntu-24.04.3-live-server-amd64.iso` in the project directory

3. **Custom ISO name**: `ubuntu-24.04-homelab-amd64.iso`

4. Click **Next** and follow the Cubic wizard

5. In the terminal tab, manually copy files:
   ```bash
   # Copy homelab scripts
   cp -r /home/ubuntu/Homelab-Install-Script/* /opt/homelab/

   # Copy Docker images (if desired)
   mkdir -p /opt/homelab-data/docker-images
   cp /home/ubuntu/iso-artifacts/docker-images/*.tar.gz /opt/homelab-data/docker-images/

   # Copy Ollama models (if desired)
   mkdir -p /opt/homelab-data/ollama-models
   cp -r /home/ubuntu/iso-artifacts/ollama-models/* /opt/homelab-data/ollama-models/
   ```

6. Complete the Cubic wizard to generate the ISO

### Common Cubic Issues

**"Original disk image is required" error:**
- ISO must be on local disk (`~/Homelab-Install-Script/iso-artifacts/`), not GCS mount
- See [troubleshooting section](#cubic-error-original-disk-image-is-required) for detailed fix

**X11 display issues:**
- Ensure you connected with `-X` flag: `gcloud compute ssh cubic-builder -- -X`
- Test with `xclock` before launching Cubic
- Consider using VNC for better performance (see Advanced Configuration)

**Why Script Method is Recommended:**
- No X11/GUI issues
- Fully automated (no manual file copying)
- Faster and more reliable
- Easier to reproduce and debug

## Deleting Resources

### Delete VM Only (Keep Bucket)

```bash
./gcloud-iso-vm.sh delete
```

Bucket remains intact. You can recreate the VM later and remount the same bucket.

### Delete Everything

```bash
# Delete VM
./gcloud-iso-vm.sh delete

# Delete bucket (WARNING: Permanent!)
gsutil rm -r gs://YOUR-BUCKET-NAME

# Or delete bucket and all contents
gcloud storage rm --recursive gs://YOUR-BUCKET-NAME
```

## Comparison: GCloud vs Local Build

| Aspect | GCloud VM | Local Machine |
|--------|-----------|---------------|
| **Setup Time** | 10-15 min | 30-60 min |
| **Storage Cost** | ~$3/month | $0 (local disk) |
| **Compute Cost** | ~$0.30/hour | $0 (electricity) |
| **Flexibility** | Start/stop as needed | Always available |
| **Disk Space** | 200GB+ easily | Depends on hardware |
| **Performance** | 8 vCPU, 32GB RAM | Varies |
| **Internet Speed** | Very fast (datacenter) | Depends on ISP |
| **Portability** | Access from anywhere | Tied to location |
| **Maintenance** | Minimal | Manual updates |

**Recommendation:**
- **Local machine**: For frequent ISO builds, fast local machine available
- **GCloud VM**: For occasional builds, limited local storage, access from multiple locations

## References

- [Google Cloud Compute Engine Documentation](https://cloud.google.com/compute/docs)
- [Cloud Storage Documentation](https://cloud.google.com/storage/docs)
- [gcsfuse Documentation](https://cloud.google.com/storage/docs/gcsfuse-quickstart)
- [Cubic Documentation](https://github.com/PJ-Singh-001/Cubic)
- [Main Cubic Integration Guide](CUBIC.md)

## Support

For issues:
- **GCloud setup**: Check this document and GCP documentation
- **Cubic usage**: See [CUBIC.md](CUBIC.md) or [Cubic GitHub](https://github.com/PJ-Singh-001/Cubic/issues)
- **Homelab scripts**: See [CLAUDE.md](CLAUDE.md) or [GitHub Issues](https://github.com/brilliantsquirrel/Homelab-Install-Script/issues)
