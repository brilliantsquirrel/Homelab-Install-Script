#!/bin/bash

# Google Cloud VM Setup for Cubic ISO Creation
# This script creates a GCloud VM optimized for Cubic with cloud storage bucket integration
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
VM_NAME="cubic-builder"
ZONE="us-central1-a"
MACHINE_TYPE="n2-standard-8"  # 8 vCPU, 32GB RAM
BOOT_DISK_SIZE="100GB"
BUCKET_NAME=""
IMAGE_FAMILY="ubuntu-2404-lts"
IMAGE_PROJECT="ubuntu-os-cloud"

header "Google Cloud VM Setup for Cubic"

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

# Prompt for bucket name
echo ""
log "Storage bucket configuration:"
log "  Large files (70-110GB) will be stored in a cloud storage bucket"
log "  This bucket will be mounted to the VM using gcsfuse"
echo ""

read -p "Storage bucket name (e.g., ${PROJECT_ID}-cubic-artifacts): " BUCKET_NAME

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
echo "  Boot Disk:     $BOOT_DISK_SIZE"
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

cat > /tmp/cubic-vm-startup.sh << 'STARTUP_SCRIPT'
#!/bin/bash

# VM Startup Script - Installs Cubic dependencies on first boot

set -e

LOG_FILE="/var/log/cubic-setup.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if already initialized
if [ -f /var/lib/cubic-initialized ]; then
    log "VM already initialized, skipping setup"
    exit 0
fi

log "Starting Cubic VM initialization..."

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
    fuse

# Install gcsfuse for mounting cloud storage
log "Installing gcsfuse..."
export GCSFUSE_REPO=gcsfuse-$(lsb_release -c -s)
echo "deb https://packages.cloud.google.com/apt $GCSFUSE_REPO main" | tee /etc/apt/sources.list.d/gcsfuse.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
apt-get update
apt-get install -y gcsfuse

# Install Docker
log "Installing Docker..."
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# Install Cubic
log "Installing Cubic..."
apt-add-repository -y ppa:cubic-wizard/release
apt-get update
apt-get install -y --no-install-recommends cubic

# Install desktop environment (for Cubic GUI)
log "Installing desktop environment..."
apt-get install -y ubuntu-desktop-minimal

# Install VNC server for remote access
log "Installing VNC server..."
apt-get install -y tightvncserver xfce4 xfce4-goodies

# Mark as initialized
touch /var/lib/cubic-initialized

log "VM initialization complete!"
log "Next steps:"
log "  1. Connect via SSH with X11 forwarding: gcloud compute ssh $VM_NAME -- -X"
log "  2. Mount the storage bucket: ~/mount-bucket.sh"
log "  3. Run cubic-prepare.sh to download dependencies"
log "  4. Launch Cubic: cubic"

STARTUP_SCRIPT

success "✓ Created startup script"

# Create VM
header "Step 3: Creating VM Instance"

log "Creating VM: $VM_NAME"
log "This may take several minutes..."

gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
    --maintenance-policy=TERMINATE \
    --provisioning-model=STANDARD \
    --scopes=https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
    --create-disk=auto-delete=yes,boot=yes,device-name="$VM_NAME",image=projects/$IMAGE_PROJECT/global/images/family/$IMAGE_FAMILY,mode=rw,size=$BOOT_DISK_SIZE,type=pd-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=purpose=cubic-builder,environment=development \
    --metadata-from-file=startup-script=/tmp/cubic-vm-startup.sh \
    --metadata=bucket-name="$BUCKET_NAME"

success "✓ VM created: $VM_NAME"

# Create helper scripts on local machine
header "Step 4: Creating Helper Scripts"

# Create bucket mounting script (to be copied to VM)
cat > /tmp/mount-bucket.sh << 'MOUNT_SCRIPT'
#!/bin/bash

# Mount Google Cloud Storage Bucket
# This script mounts the cloud storage bucket to ~/cubic-artifacts

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

MOUNT_POINT="$HOME/cubic-artifacts"

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

MOUNT_POINT="$HOME/cubic-artifacts"

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
cat > "gcloud-cubic-vm.sh" << VMSCRIPT
#!/bin/bash

# GCloud Cubic VM Management Script
# Manages the Cubic builder VM (start, stop, ssh, status)

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
    echo "  \$0 status    - Show VM status"
    echo "  \$0 start     - Start the VM"
    echo "  \$0 stop      - Stop the VM"
    echo "  \$0 ssh       - SSH into VM"
    echo "  \$0 bucket    - Show bucket contents"
    echo "  \$0 upload    - Upload files to bucket"
    echo "  \$0 download  - Download files from bucket"
    echo "  \$0 delete    - Delete the VM"
}

# Command dispatcher
case "\${1:-info}" in
    status)   cmd_status ;;
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    ssh)      cmd_ssh ;;
    upload)   cmd_upload "\$2" ;;
    download) cmd_download "\$2" ;;
    bucket)   cmd_bucket ;;
    delete)   cmd_delete ;;
    info)     cmd_info ;;
    *)
        error "Unknown command: \$1"
        cmd_info
        exit 1
        ;;
esac

VMSCRIPT

chmod +x gcloud-cubic-vm.sh

success "✓ Created VM management script: ./gcloud-cubic-vm.sh"

# Wait for VM to be ready
header "Step 5: Waiting for VM Initialization"

log "VM is initializing... This takes 5-10 minutes"
log "The startup script is installing Docker, Cubic, and desktop environment"
echo ""

log "Waiting for SSH to be ready..."
gcloud compute ssh "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --command="echo 'SSH connection successful'" \
    || warning "SSH connection failed, VM may still be starting up"

# Copy helper scripts to VM
log "Copying helper scripts to VM..."
gcloud compute scp /tmp/mount-bucket.sh "${VM_NAME}:~/" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    || warning "Failed to copy mount-bucket.sh"

gcloud compute scp /tmp/unmount-bucket.sh "${VM_NAME}:~/" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    || warning "Failed to copy unmount-bucket.sh"

gcloud compute ssh "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --command="chmod +x ~/mount-bucket.sh ~/unmount-bucket.sh" \
    || warning "Failed to set permissions"

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
log "You can monitor progress with: gcloud compute ssh $VM_NAME -- tail -f /var/log/cubic-setup.log"
echo ""

log "Next steps:"
echo ""
echo "1. Wait for initialization to complete (5-10 minutes)"
echo "   Monitor: gcloud compute ssh $VM_NAME -- tail -f /var/log/cubic-setup.log"
echo ""
echo "2. Connect to the VM:"
echo "   ./gcloud-cubic-vm.sh ssh"
echo ""
echo "3. Mount the storage bucket (on VM):"
echo "   ~/mount-bucket.sh"
echo ""
echo "4. Clone this repository (on VM):"
echo "   cd ~/cubic-artifacts"
echo "   git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git"
echo "   cd Homelab-Install-Script"
echo ""
echo "5. Download dependencies (on VM):"
echo "   ./cubic-prepare.sh"
echo ""
echo "6. Launch Cubic (on VM):"
echo "   cubic"
echo "   # In Cubic GUI, set project directory to: ~/cubic-artifacts"
echo ""
echo "Management commands:"
echo "  ./gcloud-cubic-vm.sh status    - Show VM status"
echo "  ./gcloud-cubic-vm.sh start     - Start the VM"
echo "  ./gcloud-cubic-vm.sh stop      - Stop the VM (saves costs!)"
echo "  ./gcloud-cubic-vm.sh ssh       - SSH into VM"
echo "  ./gcloud-cubic-vm.sh bucket    - Show bucket contents"
echo "  ./gcloud-cubic-vm.sh info      - Show all commands"
echo ""

warning "IMPORTANT: Remember to stop the VM when not in use to save costs!"
echo "  ./gcloud-cubic-vm.sh stop"

