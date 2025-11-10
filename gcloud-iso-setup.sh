#!/bin/bash

# Google Cloud VM Setup for ISO Creation
# This script creates a GCloud VM optimized for script-based ISO building with cloud storage bucket integration
# Large files (70-110GB) are stored in a cloud storage bucket, not on VM disk

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

# Configuration
PROJECT_ID=""
VM_NAME="iso-builder"
ZONE="us-west1-a"
MACHINE_TYPE="n2-standard-16"  # 16 vCPU, 64GB RAM (elastic builds need more power)
BOOT_DISK_SIZE="500GB"  # Large disk for ISO builds with all artifacts
LOCAL_SSD_COUNT="1"  # Number of 375GB local SSDs for fast temporary storage
BUCKET_NAME="cloud-ai-server-iso-artifacts"
IMAGE_FAMILY="ubuntu-2204-lts"  # Ubuntu 22.04 LTS (stable, well-supported)
IMAGE_PROJECT="ubuntu-os-cloud"
# Alternative machine types for different workloads:
# n2-standard-8    - 8 vCPU, 32GB RAM (lighter workloads)
# n2-standard-16   - 16 vCPU, 64GB RAM (recommended for ISO builds)
# n2-standard-32   - 32 vCPU, 128GB RAM (heavy parallel builds)
# n2-highmem-16    - 16 vCPU, 128GB RAM (memory-intensive operations)

header "Google Cloud VM Setup for ISO Builder"

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    error "gcloud CLI is not installed. Please install it first:"
    error "  https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Get current project ID
CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -z "$CURRENT_PROJECT" ]; then
    error "No default project configured. Please set your project:"
    echo "  gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

log "Using project: $CURRENT_PROJECT"
PROJECT_ID="$CURRENT_PROJECT"

# Prompt for configuration
echo ""
read -p "VM name [$VM_NAME]: " input_vm_name
VM_NAME="${input_vm_name:-$VM_NAME}"

read -p "Zone [$ZONE]: " input_zone
ZONE="${input_zone:-$ZONE}"

read -p "Machine type [$MACHINE_TYPE]: " input_machine_type
MACHINE_TYPE="${input_machine_type:-$MACHINE_TYPE}"

read -p "Boot disk size [$BOOT_DISK_SIZE]: " input_disk_size
BOOT_DISK_SIZE="${input_disk_size:-$BOOT_DISK_SIZE}"

read -p "Local SSD count (0-8, each 375GB) [$LOCAL_SSD_COUNT]: " input_ssd_count
LOCAL_SSD_COUNT="${input_ssd_count:-$LOCAL_SSD_COUNT}"

# Prompt for bucket name
echo ""
log "Storage bucket configuration:"
log "  Large files (70-110GB) will be stored in a cloud storage bucket"
log "  This bucket will be mounted to the VM using gcsfuse"
if [ "$LOCAL_SSD_COUNT" -gt 0 ]; then
    log "  Local SSD(s) will be mounted at /mnt/disks/ssd for fast temporary storage"
fi
echo ""

read -p "Storage bucket name [$BUCKET_NAME]: " input_bucket
BUCKET_NAME="${input_bucket:-$BUCKET_NAME}"

if [ -z "$BUCKET_NAME" ]; then
    error "Bucket name is required"
    exit 1
fi

echo ""
log "Configuration:"
echo "  Project:       $PROJECT_ID"
echo "  VM Name:       $VM_NAME"
echo "  Zone:          $ZONE"
echo "  Machine Type:  $MACHINE_TYPE"
echo "  Boot Disk:     $BOOT_DISK_SIZE (pd-ssd)"
if [ "$LOCAL_SSD_COUNT" -gt 0 ]; then
    total_ssd_gb=$((LOCAL_SSD_COUNT * 375))
    echo "  Local SSDs:    $LOCAL_SSD_COUNT x 375GB = ${total_ssd_gb}GB (fast scratch)"
fi
echo "  Bucket:        $BUCKET_NAME"
echo ""

read -p "Create VM with this configuration? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Aborted"
    exit 0
fi

# Create storage bucket if it doesn't exist
header "Step 1: Creating Storage Bucket"

if gsutil ls -b "gs://${BUCKET_NAME}" &> /dev/null; then
    warning "Bucket gs://${BUCKET_NAME} already exists, skipping creation"
else
    log "Creating bucket: gs://${BUCKET_NAME}"
    gsutil mb -p "$PROJECT_ID" -l "$(echo $ZONE | sed 's/-[^-]*$//')" "gs://${BUCKET_NAME}"
    success "✓ Created bucket: gs://${BUCKET_NAME}"
fi

# Create startup script for VM
header "Step 2: Creating VM Startup Script"

cat > /tmp/iso-vm-startup.sh << 'STARTUP_SCRIPT'
#!/bin/bash

# VM Startup Script - Installs ISO building dependencies on first boot

set -e

LOG_FILE="/var/log/iso-setup.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if already initialized
if [ -f /var/lib/iso-initialized ]; then
    log "VM already initialized, skipping setup"
    exit 0
fi

log "Starting ISO builder VM initialization..."

# Update system
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install required packages
log "Installing required packages..."
apt-get install -y \
    git \
    rsync \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    software-properties-common \
    fuse \
    pigz \
    pv

# Install gcsfuse for mounting cloud storage
log "Installing gcsfuse..."
export GCSFUSE_REPO=gcsfuse-$(lsb_release -c -s)
echo "deb https://packages.cloud.google.com/apt $GCSFUSE_REPO main" | tee /etc/apt/sources.list.d/gcsfuse.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
apt-get update
apt-get install -y gcsfuse

# Configure gsutil for better performance
log "Configuring gsutil for parallel uploads..."
mkdir -p /etc

# Only create boto.cfg if it doesn't exist or doesn't have GSUtil section
if ! grep -q "\[GSUtil\]" /etc/boto.cfg 2>/dev/null; then
    cat > /etc/boto.cfg << 'BOTO_EOF'
[GSUtil]
parallel_composite_upload_threshold = 150M
parallel_thread_count = 8
BOTO_EOF
else
    log "boto.cfg already configured, skipping"
fi

# Install Docker
log "Installing Docker..."
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# Install ISO building tools
log "Installing ISO building tools..."
apt-get install -y xorriso squashfs-tools

# Mount local SSDs if available
log "Checking for local SSDs..."
if ls /dev/disk/by-id/google-local-ssd-* &> /dev/null; then
    log "Local SSDs detected, setting up..."
    mkdir -p /mnt/disks/ssd

    # Format and mount the first local SSD
    # Note: If multiple SSDs, they'll be at google-local-ssd-0, google-local-ssd-1, etc.
    SSD_DEVICE="/dev/disk/by-id/google-local-ssd-0"
    if [ -b "$SSD_DEVICE" ]; then
        log "Formatting local SSD..."
        mkfs.ext4 -F "$SSD_DEVICE"

        log "Mounting local SSD at /mnt/disks/ssd..."
        mount -o discard,defaults "$SSD_DEVICE" /mnt/disks/ssd
        chmod a+w /mnt/disks/ssd

        # Add to fstab for auto-mount (but comment out since local SSDs are ephemeral)
        # echo "$SSD_DEVICE /mnt/disks/ssd ext4 discard,defaults,nofail 0 2" >> /etc/fstab

        log "Local SSD mounted at /mnt/disks/ssd ($(df -h /mnt/disks/ssd | tail -1 | awk '{print $2}') available)"

        # Create build directory on fast SSD
        mkdir -p /mnt/disks/ssd/iso-build
        chown ubuntu:ubuntu /mnt/disks/ssd/iso-build
    else
        log "Local SSD device not found at $SSD_DEVICE"
    fi
else
    log "No local SSDs detected, using boot disk for all operations"
fi

# Mark as initialized
touch /var/lib/iso-initialized

log "VM initialization complete!"
log "Next steps:"
log "  1. Connect via SSH: gcloud compute ssh $VM_NAME"
log "  2. Mount the storage bucket: ~/mount-bucket.sh"
log "  3. Clone homelab repo and run iso-prepare.sh to download dependencies"
log "  4. Run create-custom-iso.sh to build the ISO"

STARTUP_SCRIPT

success "✓ Created startup script"

# Create VM
header "Step 3: Creating VM Instance"

log "Creating VM: $VM_NAME"
log "This may take several minutes..."

# Build the gcloud command
GCLOUD_CMD="gcloud compute instances create \"$VM_NAME\" \
    --project=\"$PROJECT_ID\" \
    --zone=\"$ZONE\" \
    --machine-type=\"$MACHINE_TYPE\" \
    --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
    --maintenance-policy=MIGRATE \
    --provisioning-model=STANDARD \
    --scopes=https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
    --create-disk=auto-delete=yes,boot=yes,device-name=\"$VM_NAME\",image=projects/$IMAGE_PROJECT/global/images/family/$IMAGE_FAMILY,mode=rw,size=$BOOT_DISK_SIZE,type=pd-ssd"

# Add local SSDs if requested
if [ "$LOCAL_SSD_COUNT" -gt 0 ]; then
    log "Adding $LOCAL_SSD_COUNT local SSD(s)..."
    for i in $(seq 0 $((LOCAL_SSD_COUNT - 1))); do
        GCLOUD_CMD="$GCLOUD_CMD --local-ssd=interface=SCSI"
    done
fi

GCLOUD_CMD="$GCLOUD_CMD \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=purpose=iso-builder,environment=development \
    --metadata-from-file=startup-script=/tmp/iso-vm-startup.sh \
    --metadata=bucket-name=\"$BUCKET_NAME\",local-ssd-count=\"$LOCAL_SSD_COUNT\""

# Execute the command
eval $GCLOUD_CMD

success "✓ VM created: $VM_NAME"

# Create helper scripts on local machine
header "Step 4: Creating Helper Scripts"

# Create bucket mounting script (to be copied to VM)
cat > /tmp/mount-bucket.sh << 'MOUNT_SCRIPT'
#!/bin/bash

# Mount Google Cloud Storage Bucket
# This script mounts the cloud storage bucket to ~/iso-artifacts

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Get bucket name from instance metadata
BUCKET_NAME=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name" -H "Metadata-Flavor: Google")

if [ -z "$BUCKET_NAME" ]; then
    error "Could not retrieve bucket name from metadata"
    exit 1
fi

MOUNT_POINT="$HOME/iso-artifacts"

log "Mounting bucket: gs://${BUCKET_NAME}"
log "Mount point: $MOUNT_POINT"

# Create mount point
mkdir -p "$MOUNT_POINT"

# Check if already mounted
if mountpoint -q "$MOUNT_POINT"; then
    log "Bucket already mounted at $MOUNT_POINT"
    exit 0
fi

# Mount the bucket
log "Mounting bucket with gcsfuse..."
gcsfuse --implicit-dirs "$BUCKET_NAME" "$MOUNT_POINT"

success "✓ Bucket mounted successfully"
log "Access your files at: $MOUNT_POINT"

# Verify mount
if [ -d "$MOUNT_POINT" ]; then
    log "Contents:"
    ls -lh "$MOUNT_POINT" 2>/dev/null || log "(empty)"
fi

MOUNT_SCRIPT

chmod +x /tmp/mount-bucket.sh

# Create unmount script
cat > /tmp/unmount-bucket.sh << 'UNMOUNT_SCRIPT'
#!/bin/bash

# Unmount Google Cloud Storage Bucket

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

MOUNT_POINT="$HOME/iso-artifacts"

if ! mountpoint -q "$MOUNT_POINT"; then
    log "Bucket not mounted at $MOUNT_POINT"
    exit 0
fi

log "Unmounting: $MOUNT_POINT"
fusermount -u "$MOUNT_POINT"

success "✓ Bucket unmounted"

UNMOUNT_SCRIPT

chmod +x /tmp/unmount-bucket.sh

# Create local VM management script
cat > "gcloud-iso-vm.sh" << VMSCRIPT
#!/bin/bash

# GCloud ISO VM Management Script
# Manages the ISO builder VM (start, stop, ssh, status)

set -e

PROJECT_ID="$PROJECT_ID"
VM_NAME="$VM_NAME"
ZONE="$ZONE"
BUCKET_NAME="$BUCKET_NAME"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "\${GREEN}[INFO]\${NC} \$1"; }
error() { echo -e "\${RED}[ERROR]\${NC} \$1"; }
success() { echo -e "\${GREEN}[SUCCESS]\${NC} \$1"; }
header() {
    echo ""
    echo -e "\${BLUE}========================================\${NC}"
    echo -e "\${BLUE}\$1\${NC}"
    echo -e "\${BLUE}========================================\${NC}"
    echo ""
}

cmd_status() {
    header "VM Status"
    gcloud compute instances describe "\$VM_NAME" \\
        --project="\$PROJECT_ID" \\
        --zone="\$ZONE" \\
        --format="table(name,status,machineType,networkInterfaces[0].accessConfigs[0].natIP)"
}

cmd_start() {
    header "Starting VM"
    log "Starting VM: \$VM_NAME"
    gcloud compute instances start "\$VM_NAME" \\
        --project="\$PROJECT_ID" \\
        --zone="\$ZONE"
    success "✓ VM started"
    log "Waiting for VM to be ready..."
    sleep 10
    cmd_status
}

cmd_stop() {
    header "Stopping VM"
    log "Stopping VM: \$VM_NAME"
    gcloud compute instances stop "\$VM_NAME" \\
        --project="\$PROJECT_ID" \\
        --zone="\$ZONE"
    success "✓ VM stopped"
}

cmd_ssh() {
    header "SSH Connection"
    log "Connecting to VM: \$VM_NAME"
    log "The bucket will be mounted automatically if not already mounted"
    gcloud compute ssh "\$VM_NAME" \\
        --project="\$PROJECT_ID" \\
        --zone="\$ZONE" \\
        -- -X
}

cmd_upload() {
    header "Upload Files to Bucket"
    if [ -z "\$1" ]; then
        error "Usage: \$0 upload <local-path>"
        exit 1
    fi
    log "Uploading: \$1 -> gs://\${BUCKET_NAME}/"
    gsutil -m rsync -r "\$1" "gs://\${BUCKET_NAME}/"
    success "✓ Upload complete"
}

cmd_download() {
    header "Download Files from Bucket"
    if [ -z "\$1" ]; then
        error "Usage: \$0 download <local-path>"
        exit 1
    fi
    log "Downloading: gs://\${BUCKET_NAME}/ -> \$1"
    mkdir -p "\$1"
    gsutil -m rsync -r "gs://\${BUCKET_NAME}/" "\$1"
    success "✓ Download complete"
}

cmd_bucket() {
    header "Bucket Contents"
    log "Bucket: gs://\${BUCKET_NAME}"
    gsutil ls -lh "gs://\${BUCKET_NAME}/" || log "(empty)"
}

cmd_setup_scripts() {
    header "Setup Mount Scripts"
    log "Creating mount-bucket.sh on VM..."

    gcloud compute ssh "\$VM_NAME" \\
        --project="\$PROJECT_ID" \\
        --zone="\$ZONE" \\
        --command="cat > ~/mount-bucket.sh << 'SCRIPT_EOF'
#!/bin/bash

# Mount Google Cloud Storage Bucket
# This script mounts the cloud storage bucket to ~/iso-artifacts

set -e

GREEN='\\033[0;32m'
RED='\\033[0;31m'
YELLOW='\\033[1;33m'
NC='\\033[0m'

log() { echo -e \"\\\${GREEN}[INFO]\\\${NC} \\\$1\"; }
error() { echo -e \"\\\${RED}[ERROR]\\\${NC} \\\$1\"; }
success() { echo -e \"\\\${GREEN}[SUCCESS]\\\${NC} \\\$1\"; }

# Get bucket name from instance metadata
BUCKET_NAME=\\\$(curl -s \"http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name\" -H \"Metadata-Flavor: Google\")

if [ -z \"\\\$BUCKET_NAME\" ]; then
    error \"Could not retrieve bucket name from metadata\"
    exit 1
fi

MOUNT_POINT=\"\\\$HOME/iso-artifacts\"

log \"Mounting bucket: gs://\\\${BUCKET_NAME}\"
log \"Mount point: \\\$MOUNT_POINT\"

# Create mount point
mkdir -p \"\\\$MOUNT_POINT\"

# Check if already mounted
if mountpoint -q \"\\\$MOUNT_POINT\"; then
    log \"Bucket already mounted at \\\$MOUNT_POINT\"
    exit 0
fi

# Mount the bucket
log \"Mounting bucket with gcsfuse...\"
gcsfuse --implicit-dirs \"\\\$BUCKET_NAME\" \"\\\$MOUNT_POINT\"

success \"✓ Bucket mounted successfully\"
log \"Access your files at: \\\$MOUNT_POINT\"

# Verify mount
if [ -d \"\\\$MOUNT_POINT\" ]; then
    log \"Contents:\"
    ls -lh \"\\\$MOUNT_POINT\" 2>/dev/null || log \"(empty)\"
fi
SCRIPT_EOF
chmod +x ~/mount-bucket.sh"

    success "✓ Created mount-bucket.sh on VM"

    log "Creating unmount-bucket.sh on VM..."

    gcloud compute ssh "\$VM_NAME" \\
        --project="\$PROJECT_ID" \\
        --zone="\$ZONE" \\
        --command="cat > ~/unmount-bucket.sh << 'SCRIPT_EOF'
#!/bin/bash

# Unmount Google Cloud Storage Bucket

set -e

GREEN='\\033[0;32m'
RED='\\033[0;31m'
NC='\\033[0m'

log() { echo -e \"\\\${GREEN}[INFO]\\\${NC} \\\$1\"; }
error() { echo -e \"\\\${RED}[ERROR]\\\${NC} \\\$1\"; }
success() { echo -e \"\\\${GREEN}[SUCCESS]\\\${NC} \\\$1\"; }

MOUNT_POINT=\"\\\$HOME/iso-artifacts\"

if ! mountpoint -q \"\\\$MOUNT_POINT\"; then
    log \"Bucket not mounted at \\\$MOUNT_POINT\"
    exit 0
fi

log \"Unmounting: \\\$MOUNT_POINT\"
fusermount -u \"\\\$MOUNT_POINT\"

success \"✓ Bucket unmounted\"
SCRIPT_EOF
chmod +x ~/unmount-bucket.sh"

    success "✓ Created unmount-bucket.sh on VM"
    log "You can now run: ssh to VM and execute ~/mount-bucket.sh"
}

cmd_resize_disk() {
    header "Resize Boot Disk"
    if [ -z "\$1" ]; then
        error "Usage: \$0 resize-disk <new-size-gb>"
        error "Example: \$0 resize-disk 1000"
        exit 1
    fi

    NEW_SIZE="\$1"
    DISK_NAME="\$VM_NAME"

    log "Resizing boot disk to \${NEW_SIZE}GB..."
    log "Note: Disk can only be increased, not decreased"
    echo ""
    read -p "Resize disk '\$DISK_NAME' to \${NEW_SIZE}GB? (y/N): " -n 1 -r
    echo
    if [[ \$REPLY =~ ^[Yy]$ ]]; then
        gcloud compute disks resize "\$DISK_NAME" \\
            --project="\$PROJECT_ID" \\
            --zone="\$ZONE" \\
            --size="\${NEW_SIZE}GB"
        success "✓ Disk resized to \${NEW_SIZE}GB"
        log "Run this on the VM to expand the filesystem:"
        echo "  sudo resize2fs /dev/sda1"
    else
        log "Cancelled"
    fi
}

cmd_change_machine() {
    header "Change Machine Type"
    if [ -z "\$1" ]; then
        error "Usage: \$0 change-machine <machine-type>"
        error "Examples:"
        error "  \$0 change-machine n2-standard-8    (8 vCPU, 32GB)"
        error "  \$0 change-machine n2-standard-16   (16 vCPU, 64GB)"
        error "  \$0 change-machine n2-standard-32   (32 vCPU, 128GB)"
        error "  \$0 change-machine n2-highmem-16    (16 vCPU, 128GB)"
        exit 1
    fi

    NEW_MACHINE_TYPE="\$1"

    log "Changing machine type to \$NEW_MACHINE_TYPE..."
    log "Note: VM must be stopped first"
    echo ""

    # Check if VM is running
    VM_STATUS=\$(gcloud compute instances describe "\$VM_NAME" \\
        --project="\$PROJECT_ID" \\
        --zone="\$ZONE" \\
        --format="value(status)")

    if [ "\$VM_STATUS" = "RUNNING" ]; then
        log "VM is running, stopping it first..."
        gcloud compute instances stop "\$VM_NAME" \\
            --project="\$PROJECT_ID" \\
            --zone="\$ZONE"
        log "Waiting for VM to stop..."
        sleep 10
    fi

    log "Changing machine type..."
    gcloud compute instances set-machine-type "\$VM_NAME" \\
        --project="\$PROJECT_ID" \\
        --zone="\$ZONE" \\
        --machine-type="\$NEW_MACHINE_TYPE"

    success "✓ Machine type changed to \$NEW_MACHINE_TYPE"
    log "Start the VM with: \$0 start"
}

cmd_delete() {
    header "Delete VM"
    log "WARNING: This will delete the VM instance"
    log "The storage bucket will NOT be deleted"
    echo ""
    read -p "Are you sure you want to delete VM '\$VM_NAME'? (y/N): " -n 1 -r
    echo
    if [[ \$REPLY =~ ^[Yy]$ ]]; then
        gcloud compute instances delete "\$VM_NAME" \\
            --project="\$PROJECT_ID" \\
            --zone="\$ZONE" \\
            --quiet
        success "✓ VM deleted"
    else
        log "Cancelled"
    fi
}

cmd_info() {
    header "Configuration"
    echo "Project:     \$PROJECT_ID"
    echo "VM Name:     \$VM_NAME"
    echo "Zone:        \$ZONE"
    echo "Bucket:      gs://\${BUCKET_NAME}"
    echo ""
    log "Useful commands:"
    echo ""
    echo "VM Management:"
    echo "  \$0 status            - Show VM status"
    echo "  \$0 start             - Start the VM"
    echo "  \$0 stop              - Stop the VM"
    echo "  \$0 ssh               - SSH into VM"
    echo "  \$0 delete            - Delete the VM"
    echo ""
    echo "Elastic Scaling:"
    echo "  \$0 resize-disk <gb>       - Increase boot disk size (e.g., 1000)"
    echo "  \$0 change-machine <type>  - Change CPU/memory (e.g., n2-standard-32)"
    echo ""
    echo "Storage:"
    echo "  \$0 setup-scripts    - Create mount scripts on VM"
    echo "  \$0 bucket           - Show bucket contents"
    echo "  \$0 upload <path>    - Upload files to bucket"
    echo "  \$0 download <path>  - Download files from bucket"
    echo ""
    echo "Examples:"
    echo "  \$0 resize-disk 1000              # Increase disk to 1TB"
    echo "  \$0 change-machine n2-standard-32 # Scale to 32 vCPU, 128GB RAM"
}

# Command dispatcher
case "\${1:-info}" in
    status)         cmd_status ;;
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    ssh)            cmd_ssh ;;
    setup-scripts)  cmd_setup_scripts ;;
    upload)         cmd_upload "\$2" ;;
    download)       cmd_download "\$2" ;;
    bucket)         cmd_bucket ;;
    resize-disk)    cmd_resize_disk "\$2" ;;
    change-machine) cmd_change_machine "\$2" ;;
    delete)         cmd_delete ;;
    info)           cmd_info ;;
    *)
        error "Unknown command: \$1"
        cmd_info
        exit 1
        ;;
esac

VMSCRIPT

chmod +x gcloud-iso-vm.sh

success "✓ Created VM management script: ./gcloud-iso-vm.sh"

# Wait for VM to be ready
header "Step 5: Waiting for VM Initialization"

log "VM is initializing... This takes 5-10 minutes"
log "The startup script is installing Docker, Cubic, and desktop environment"
echo ""

log "Waiting for SSH to be ready..."
for i in {1..10}; do
    if gcloud compute ssh "$VM_NAME" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --command="echo 'SSH connection successful'" 2>/dev/null; then
        success "✓ SSH is ready"
        break
    else
        if [ $i -eq 10 ]; then
            warning "SSH not ready after 10 attempts, continuing anyway..."
        else
            log "Attempt $i/10: SSH not ready, waiting 10 seconds..."
            sleep 10
        fi
    fi
done

# Copy helper scripts to VM with retries
log "Copying helper scripts to VM..."

# Copy mount-bucket.sh
for i in {1..3}; do
    if gcloud compute scp /tmp/mount-bucket.sh "${VM_NAME}:~/" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" 2>/dev/null; then
        success "✓ Copied mount-bucket.sh"
        break
    else
        if [ $i -eq 3 ]; then
            warning "Failed to copy mount-bucket.sh after 3 attempts"
        else
            log "Retry $i/3: Failed to copy mount-bucket.sh, waiting..."
            sleep 5
        fi
    fi
done

# Copy unmount-bucket.sh
for i in {1..3}; do
    if gcloud compute scp /tmp/unmount-bucket.sh "${VM_NAME}:~/" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" 2>/dev/null; then
        success "✓ Copied unmount-bucket.sh"
        break
    else
        if [ $i -eq 3 ]; then
            warning "Failed to copy unmount-bucket.sh after 3 attempts"
        else
            log "Retry $i/3: Failed to copy unmount-bucket.sh, waiting..."
            sleep 5
        fi
    fi
done

# Set permissions
log "Setting script permissions..."
gcloud compute ssh "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --command="chmod +x ~/mount-bucket.sh ~/unmount-bucket.sh 2>/dev/null || echo 'Scripts may not exist yet'"

# Verify scripts were copied
log "Verifying scripts..."
if gcloud compute ssh "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --command="test -f ~/mount-bucket.sh && test -f ~/unmount-bucket.sh && echo 'Scripts verified'" 2>/dev/null | grep -q "Scripts verified"; then
    success "✓ Helper scripts successfully installed"
else
    warning "Scripts may not have been copied successfully"
    log "You can manually create them later using the management script"
fi

# Summary
header "Setup Complete!"

success "✓ VM created and configured"
echo ""
echo "VM Details:"
echo "  Name:    $VM_NAME"
echo "  Zone:    $ZONE"
echo "  Bucket:  gs://${BUCKET_NAME}"
echo ""

log "VM is still initializing in the background (5-10 minutes)"
log "You can monitor progress with: gcloud compute ssh $VM_NAME -- tail -f /var/log/iso-setup.log"
echo ""

log "Next steps:"
echo ""
echo "1. Wait for initialization to complete (5-10 minutes)"
echo "   Monitor: gcloud compute ssh $VM_NAME -- tail -f /var/log/iso-setup.log"
echo ""
echo "2. Connect to the VM:"
echo "   ./gcloud-iso-vm.sh ssh"
echo ""
echo "3. Mount the storage bucket (on VM):"
echo "   ~/mount-bucket.sh"
echo ""
echo "4. Clone this repository (on VM):"
echo "   cd ~/iso-artifacts"
echo "   git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git"
echo "   cd Homelab-Install-Script"
echo ""
echo "5. Download dependencies (on VM):"
echo "   ./iso-prepare.sh"
echo ""
echo "6. Build the custom ISO (on VM):"
echo "   ./create-custom-iso.sh"
echo ""
echo "Management commands:"
echo "  ./gcloud-iso-vm.sh status              - Show VM status"
echo "  ./gcloud-iso-vm.sh start               - Start the VM"
echo "  ./gcloud-iso-vm.sh stop                - Stop the VM (saves costs!)"
echo "  ./gcloud-iso-vm.sh ssh                 - SSH into VM"
echo "  ./gcloud-iso-vm.sh bucket              - Show bucket contents"
echo "  ./gcloud-iso-vm.sh info                - Show all commands"
echo ""
echo "Elastic scaling (increase resources during build):"
echo "  ./gcloud-iso-vm.sh resize-disk 1000           - Increase disk to 1TB"
echo "  ./gcloud-iso-vm.sh change-machine n2-standard-32  - Scale to 32 vCPU"
echo ""

warning "IMPORTANT: Remember to stop the VM when not in use to save costs!"
echo "  ./gcloud-iso-vm.sh stop"
echo ""
if [ "$LOCAL_SSD_COUNT" -gt 0 ]; then
    success "Local SSD available at /mnt/disks/ssd for fast ISO builds"
    log "Use /mnt/disks/ssd/iso-build for temporary build files"
fi

