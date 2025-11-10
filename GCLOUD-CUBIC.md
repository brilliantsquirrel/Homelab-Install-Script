# Google Cloud VM Setup for Cubic ISO Creation

This guide explains how to set up a Google Cloud VM for creating Cubic ISOs with large file storage in Cloud Storage buckets.

## Overview

Creating custom Ubuntu ISOs with Cubic requires:
- **70-110GB** of storage for Docker images and Ollama models
- **GUI environment** for the Cubic wizard
- **Significant compute** for downloading and processing
- **Flexibility** to power on/off as needed

This setup uses:
- **GCloud Compute VM**: Ubuntu with desktop environment, Docker, and Cubic
- **Cloud Storage Bucket**: Stores large files (cubic-artifacts), mounted via gcsfuse
- **Cost Optimization**: Stop VM when not in use, only pay for storage
- **Easy Management**: Simple scripts for start/stop/ssh/status

## Architecture

```
┌─────────────────────────────────────────┐
│  Your Local Machine                     │
│  ├─ gcloud CLI                          │
│  ├─ gcloud-cubic-setup.sh (one-time)    │
│  └─ gcloud-cubic-vm.sh (management)     │
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
│  │ └─ ~/cubic-artifacts/ (mount)  │    │
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

## Quick Start

### Step 1: Create the VM and Bucket

```bash
# Clone this repository
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script

# Make setup script executable
chmod +x gcloud-cubic-setup.sh

# Run setup (interactive)
./gcloud-cubic-setup.sh
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
- Boot disk size (default: `100GB`)
- Storage bucket name (required)

**Recommended Configuration:**
- **Machine type**: `n2-standard-8` (8 vCPU, 32GB RAM) - good balance
- **Boot disk**: `100GB` - OS, temp files, Cubic working directory
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
./gcloud-cubic-vm.sh ssh

# On the VM, mount the storage bucket
~/mount-bucket.sh
```

This mounts the Cloud Storage bucket at `~/cubic-artifacts/`.

### Step 4: Prepare Dependencies

```bash
# On the VM, clone the repository
cd ~
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script

# Set the GCS bucket environment variable
export GCS_BUCKET=gs://$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name" -H "Metadata-Flavor: Google")

# Download all dependencies (70-110GB, takes 2-4 hours)
# Files are automatically uploaded to GCS and local copies are deleted to save disk space
./cubic-prepare.sh
```

**How it works**:
- Downloads Ubuntu ISO, Docker images, and Ollama models
- Automatically uploads each file to GCS bucket after creation
- Verifies the upload succeeded
- Deletes local copy to save VM disk space (~70-110GB saved)
- Files persist in GCS bucket even if VM is deleted
- On subsequent runs, downloads from GCS (much faster than original sources)

### Step 5: Mount Bucket and Access Files

```bash
# On the VM, mount the bucket to access uploaded files
~/mount-bucket.sh
```

This mounts the GCS bucket at `~/cubic-artifacts/`, giving you access to all files uploaded by `cubic-prepare.sh`.

### Step 6: Launch Cubic

```bash
# On the VM, launch Cubic GUI
cubic
```

**In Cubic GUI:**
1. **Project Directory**: Select `/home/ubuntu/cubic-artifacts` (the mounted bucket)
2. **Original ISO**: Will be available from GCS bucket
3. **Custom ISO name**: `ubuntu-24.04-homelab-amd64.iso`
4. Click **Next** to proceed

Follow the instructions in [CUBIC.md](CUBIC.md) for customizing the ISO.

**Note**: All Docker images and Ollama models are available in the mounted bucket's subdirectories (`docker-images/`, `ollama-models/`).

### Step 7: Download the ISO

After Cubic generates the ISO:

```bash
# On your local machine, download the ISO
gsutil cp gs://YOUR-BUCKET-NAME/ubuntu-24.04-homelab-amd64.iso ./
```

Or use the management script:

```bash
./gcloud-cubic-vm.sh download ./my-isos/
```

### Step 8: Stop the VM (Save Costs!)

```bash
# Stop the VM when not in use
./gcloud-cubic-vm.sh stop
```

**Cost Savings:**
- **Running VM**: ~$0.30-0.50/hour (n2-standard-8)
- **Stopped VM**: $0/hour (only pay for storage)
- **Storage**: ~$2-3/month for 100GB bucket

## VM Management

The `gcloud-cubic-vm.sh` script provides easy VM management:

### Check Status

```bash
./gcloud-cubic-vm.sh status
```

Shows VM state, IP address, and machine type.

### Start/Stop VM

```bash
# Start the VM
./gcloud-cubic-vm.sh start

# Stop the VM (saves money!)
./gcloud-cubic-vm.sh stop
```

### SSH Access

```bash
# Connect via SSH with X11 forwarding
./gcloud-cubic-vm.sh ssh
```

This enables you to run GUI applications like Cubic.

### Bucket Operations

```bash
# View bucket contents
./gcloud-cubic-vm.sh bucket

# Upload local files to bucket
./gcloud-cubic-vm.sh upload /local/path/

# Download bucket to local
./gcloud-cubic-vm.sh download /local/path/
```

### Setup Mount Scripts

If the mount scripts are missing from the VM:

```bash
# Create mount-bucket.sh and unmount-bucket.sh on the VM
./gcloud-cubic-vm.sh setup-scripts
```

This creates the bucket mounting scripts directly on the VM via SSH.

### View All Commands

```bash
./gcloud-cubic-vm.sh info
```

## Storage Bucket Management

### Mounting the Bucket (On VM)

```bash
# Mount bucket
~/mount-bucket.sh

# Verify mount
ls -lh ~/cubic-artifacts/
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
- 100GB boot disk: ~$0.01/hour
- Network egress: Variable

**Stopped VM Costs**: $0/hour for compute, only storage costs

**Monthly Estimate** (if running 24/7):
- VM: ~$220-360/month
- Boot disk: ~$10/month
- **Total**: ~$230-370/month

**Recommended Usage**:
- Run VM only when building ISOs
- Stop VM immediately after work is done
- Typical usage: 5-10 hours/month = **$2-5/month** (plus storage)

### Storage Costs

**Cloud Storage Pricing** (Standard storage):
- First 100GB: ~$2-3/month
- Cubic artifacts (70-110GB): ~$2-3/month
- Boot disk (100GB): ~$10/month

**Total Storage**: ~$12-13/month

### Cost Optimization Tips

1. **Stop VM when not in use** - Most important!
   ```bash
   ./gcloud-cubic-vm.sh stop
   ```

2. **Use preemptible/spot VMs** - 60-91% cheaper (edit setup script)
   - Caution: Can be terminated at any time
   - Good for non-urgent ISO builds

3. **Delete VM after ISO creation** - Keep only the bucket
   ```bash
   ./gcloud-cubic-vm.sh delete
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
./gcloud-cubic-vm.sh status

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
fusermount -u ~/cubic-artifacts

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

### Cubic GUI Won't Display

**Problem**: Can't see Cubic GUI when running `cubic`

**Check SSH X11 forwarding:**
```bash
# Reconnect with X11 forwarding
exit  # Exit VM
./gcloud-cubic-vm.sh ssh

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
du -sh ~/cubic-artifacts
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

**Problem**: `cubic-prepare.sh` downloads very slowly

**Causes:**
- VM region far from Docker Hub
- Network throttling

**Fix:**
```bash
# Use a different zone closer to Docker Hub (US East)
./gcloud-cubic-setup.sh
# Choose zone: us-east1-a or us-east1-b
```

### Docker Pull Fails

**Problem**: Docker image pulls fail during `cubic-prepare.sh`

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

## Advanced Configuration

### Using Preemptible VMs (Cheaper)

Edit `gcloud-cubic-setup.sh` and add this flag to the VM creation command:

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
# Edit gcloud-cubic-setup.sh
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
if [ ! -d ~/cubic-artifacts ] || ! mountpoint -q ~/cubic-artifacts; then
    ~/mount-bucket.sh
fi
```

## Workflow Examples

### Full ISO Build (First Time)

```bash
# 1. Create VM (one-time, 10-15 minutes)
./gcloud-cubic-setup.sh

# 2. Wait for initialization
gcloud compute ssh cubic-builder -- tail -f /var/log/cubic-setup.log

# 3. Connect and mount bucket
./gcloud-cubic-vm.sh ssh
~/mount-bucket.sh

# 4. Download dependencies (2-4 hours)
cd ~/cubic-artifacts
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script
./cubic-prepare.sh

# 5. Launch Cubic and create ISO (30-60 minutes)
cubic

# 6. Download ISO to local machine
exit  # Exit VM
./gcloud-cubic-vm.sh download ./my-isos/

# 7. Stop VM
./gcloud-cubic-vm.sh stop
```

**Total time**: 3-5 hours (mostly automated)
**Cost**: ~$1.50-2.50 (one-time)

### Updating ISO (Subsequent Builds)

```bash
# 1. Start existing VM
./gcloud-cubic-vm.sh start

# 2. Connect and mount
./gcloud-cubic-vm.sh ssh
~/mount-bucket.sh

# 3. Update dependencies
cd ~/cubic-artifacts/Homelab-Install-Script
git pull
./cubic-prepare.sh

# 4. Rebuild ISO in Cubic
cubic

# 5. Download and stop
exit
./gcloud-cubic-vm.sh download ./my-isos/
./gcloud-cubic-vm.sh stop
```

**Total time**: 1-2 hours
**Cost**: ~$0.50-1.00

### Quick ISO Customization

```bash
# 1. Start VM
./gcloud-cubic-vm.sh start
./gcloud-cubic-vm.sh ssh

# 2. Mount and launch Cubic
~/mount-bucket.sh
cubic

# 3. Make changes in Cubic GUI
# ... customize ISO ...

# 4. Download and stop
exit
./gcloud-cubic-vm.sh download ./my-isos/
./gcloud-cubic-vm.sh stop
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

## Deleting Resources

### Delete VM Only (Keep Bucket)

```bash
./gcloud-cubic-vm.sh delete
```

Bucket remains intact. You can recreate the VM later and remount the same bucket.

### Delete Everything

```bash
# Delete VM
./gcloud-cubic-vm.sh delete

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
| **Disk Space** | 100GB+ easily | Depends on hardware |
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
