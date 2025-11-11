// Google Compute Engine VM Manager

const { InstancesClient, ZoneOperationsClient } = require('@google-cloud/compute').v1;
const config = require('../config/config');
const logger = require('./logger');

class VMManager {
    constructor() {
        this.instancesClient = new InstancesClient();
        this.operationsClient = new ZoneOperationsClient();
        this.projectId = config.gcp.projectId;
        this.zone = config.gcp.zone;
    }

    /**
     * Create a VM for ISO building
     * @param {string} buildId - Unique build ID
     * @param {Object} buildConfig - Build configuration
     * @returns {string} VM name
     */
    async createBuildVM(buildId, buildConfig) {
        const vmName = `${config.vm.namePrefix}-${buildId.substring(0, 8)}`;

        logger.info(`Creating VM for build ${buildId}: ${vmName}`);

        try {
            // Create startup script
            const startupScript = this.generateStartupScript(buildId, buildConfig);

            // VM configuration
            const instance = {
                name: vmName,
                machineType: `zones/${this.zone}/machineTypes/${config.vm.machineType}`,
                disks: [
                    {
                        boot: true,
                        autoDelete: true,
                        initializeParams: {
                            sourceImage: `projects/${config.vm.imageProject}/global/images/family/${config.vm.imageFamily}`,
                            diskType: `zones/${this.zone}/diskTypes/pd-ssd`,
                            diskSizeGb: config.vm.bootDiskSize,
                        },
                    },
                ],
                networkInterfaces: [
                    {
                        network: 'global/networks/default',
                        accessConfigs: [
                            {
                                type: 'ONE_TO_ONE_NAT',
                                name: 'External NAT',
                            },
                        ],
                    },
                ],
                serviceAccounts: [
                    {
                        email: 'default',
                        scopes: [
                            'https://www.googleapis.com/auth/devstorage.read_write',
                            'https://www.googleapis.com/auth/logging.write',
                            'https://www.googleapis.com/auth/monitoring.write',
                        ],
                    },
                ],
                metadata: {
                    items: [
                        {
                            key: 'startup-script',
                            value: startupScript,
                        },
                        {
                            key: 'bucket-name',
                            value: config.gcs.artifactsBucket,
                        },
                        {
                            key: 'downloads-bucket',
                            value: config.gcs.downloadsBucket,
                        },
                        {
                            key: 'build-id',
                            value: buildId,
                        },
                        {
                            key: 'build-config',
                            value: JSON.stringify(buildConfig),
                        },
                    ],
                },
                labels: {
                    'purpose': 'iso-builder',
                    'build-id': buildId.substring(0, 8),
                    'environment': config.env,
                },
                shieldedInstanceConfig: {
                    enableSecureBoot: false,
                    enableVtpm: true,
                    enableIntegrityMonitoring: true,
                },
            };

            // Add local SSDs if configured
            if (config.vm.localSsdCount > 0) {
                for (let i = 0; i < config.vm.localSsdCount; i++) {
                    instance.disks.push({
                        type: 'SCRATCH',
                        autoDelete: true,
                        interface: 'SCSI',
                        initializeParams: {
                            diskType: `zones/${this.zone}/diskTypes/local-ssd`,
                        },
                    });
                }
            }

            // Create the VM
            const [operation] = await this.instancesClient.insert({
                project: this.projectId,
                zone: this.zone,
                instanceResource: instance,
            });

            logger.info(`VM creation initiated for ${vmName}, operation: ${operation.name}`);

            // Wait for operation to complete
            await this.waitForOperation(operation.name);

            logger.info(`VM ${vmName} created successfully`);
            return vmName;
        } catch (error) {
            logger.error(`Error creating VM ${vmName}:`, error);
            throw error;
        }
    }

    /**
     * Generate startup script for VM
     */
    generateStartupScript(buildId, buildConfig) {
        const { services, models, gpu_enabled, iso_name } = buildConfig;

        return `#!/bin/bash
# Startup script for ISO build VM
set -e

LOG_FILE="/var/log/iso-build.log"
BUILD_ID="${buildId}"
ARTIFACTS_BUCKET="${config.gcs.artifactsBucket}"
DOWNLOADS_BUCKET="${config.gcs.downloadsBucket}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting ISO build for build ID: $BUILD_ID"

# Update system
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install dependencies
log "Installing build dependencies..."
apt-get install -y \\
    git rsync curl wget gnupg lsb-release ca-certificates \\
    software-properties-common fuse pigz pv xorriso squashfs-tools

# Install gcsfuse
log "Installing gcsfuse..."
export GCSFUSE_REPO=gcsfuse-$(lsb_release -c -s)
echo "deb https://packages.cloud.google.com/apt $GCSFUSE_REPO main" | tee /etc/apt/sources.list.d/gcsfuse.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
apt-get update
apt-get install -y gcsfuse

# Install Docker
log "Installing Docker..."
curl -fsSL https://get.docker.com | sh

# Mount local SSDs if available
if ls /dev/disk/by-id/google-local-ssd-* &> /dev/null; then
    log "Setting up local SSD..."
    mkdir -p /mnt/disks/ssd
    mkfs.ext4 -F /dev/disk/by-id/google-local-ssd-0
    mount -o discard,defaults /dev/disk/by-id/google-local-ssd-0 /mnt/disks/ssd
    chmod a+w /mnt/disks/ssd
    mkdir -p /mnt/disks/ssd/iso-build
fi

# Mount GCS buckets
log "Mounting GCS buckets..."
mkdir -p /mnt/artifacts
mkdir -p /mnt/downloads
gcsfuse --implicit-dirs "$ARTIFACTS_BUCKET" /mnt/artifacts
gcsfuse --implicit-dirs "$DOWNLOADS_BUCKET" /mnt/downloads

# Clone repository
log "Cloning Homelab repository..."
cd /root
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script

# Set build configuration
export SELECTED_SERVICES="${services.join(',')}"
export SELECTED_MODELS="${models.join(',')}"
export GPU_ENABLED="${gpu_enabled ? 'true' : 'false'}"
export ISO_NAME="${iso_name || 'ubuntu-24.04.3-homelab-custom'}"
export GCS_BUCKET="gs://$ARTIFACTS_BUCKET"

# Run build scripts
log "Running iso-prepare-dynamic.sh..."
bash webapp/scripts/iso-prepare-dynamic.sh

log "Running create-custom-iso.sh..."
bash create-custom-iso.sh

# Upload ISO to downloads bucket
log "Uploading ISO to downloads bucket..."
ISO_FILE="iso-artifacts/ubuntu-24.04.3-homelab-amd64.iso"
if [ -f "$ISO_FILE" ]; then
    ISO_OUTPUT_NAME="${iso_name || 'ubuntu-24.04.3-homelab-custom'}-${buildId.substring(0, 8)}.iso"
    gsutil -m cp "$ISO_FILE" "gs://$DOWNLOADS_BUCKET/$ISO_OUTPUT_NAME"
    log "ISO uploaded successfully: $ISO_OUTPUT_NAME"

    # Write build completion marker
    echo "complete" > /tmp/build-status
    echo "$ISO_OUTPUT_NAME" > /tmp/iso-filename
else
    log "ERROR: ISO file not found!"
    echo "failed" > /tmp/build-status
    echo "ISO file not found" > /tmp/build-error
fi

log "Build process completed"

# Shutdown VM if auto-cleanup is enabled
${config.vm.autoCleanup ? 'log "Auto-cleanup enabled, shutting down VM..."\nsudo shutdown -h now' : 'log "Auto-cleanup disabled, VM will remain running"'}
`;
    }

    /**
     * Get VM status
     * @param {string} vmName - VM name
     * @returns {Object} VM status
     */
    async getVMStatus(vmName) {
        try {
            const [instance] = await this.instancesClient.get({
                project: this.projectId,
                zone: this.zone,
                instance: vmName,
            });

            return {
                name: instance.name,
                status: instance.status,
                created: instance.creationTimestamp,
                machineType: instance.machineType,
                internalIP: instance.networkInterfaces?.[0]?.networkIP,
                externalIP: instance.networkInterfaces?.[0]?.accessConfigs?.[0]?.natIP,
            };
        } catch (error) {
            if (error.code === 404) {
                return null;
            }
            logger.error(`Error getting VM status for ${vmName}:`, error);
            throw error;
        }
    }

    /**
     * Delete VM
     * @param {string} vmName - VM name
     */
    async deleteVM(vmName) {
        try {
            logger.info(`Deleting VM: ${vmName}`);
            const [operation] = await this.instancesClient.delete({
                project: this.projectId,
                zone: this.zone,
                instance: vmName,
            });

            await this.waitForOperation(operation.name);
            logger.info(`VM ${vmName} deleted successfully`);
        } catch (error) {
            if (error.code === 404) {
                logger.info(`VM ${vmName} already deleted`);
                return;
            }
            logger.error(`Error deleting VM ${vmName}:`, error);
            throw error;
        }
    }

    /**
     * Wait for operation to complete
     */
    async waitForOperation(operationName, timeout = 300000) {
        const startTime = Date.now();

        while (Date.now() - startTime < timeout) {
            const [operation] = await this.operationsClient.get({
                project: this.projectId,
                zone: this.zone,
                operation: operationName,
            });

            if (operation.status === 'DONE') {
                if (operation.error) {
                    throw new Error(JSON.stringify(operation.error));
                }
                return operation;
            }

            await new Promise(resolve => setTimeout(resolve, 2000));
        }

        throw new Error(`Operation ${operationName} timed out`);
    }

    /**
     * Execute command on VM (via gcloud ssh)
     */
    async executeCommand(vmName, command) {
        // This would require gcloud CLI or SSH library
        // Placeholder for now
        logger.info(`Executing command on ${vmName}: ${command}`);
    }

    /**
     * Get build logs from VM
     */
    async getBuildLogs(vmName) {
        try {
            // In a real implementation, this would SSH into the VM and fetch logs
            // For now, return placeholder
            return [
                'VM created successfully',
                'Installing dependencies...',
                'Building ISO...',
            ];
        } catch (error) {
            logger.error(`Error getting logs from ${vmName}:`, error);
            return [];
        }
    }
}

module.exports = new VMManager();
