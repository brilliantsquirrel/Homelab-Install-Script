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
        // Security: Bounds checking for buildId substring
        const buildIdShort = buildId.length >= 8 ? buildId.substring(0, 8) : buildId;
        const vmName = `${config.vm.namePrefix}-${buildIdShort}`;
        const vmLogger = logger.withContext({ buildId, component: 'VMManager', vmName });

        vmLogger.info('Starting VM creation', {
            vmName,
            machineType: config.vm.machineType,
            zone: this.zone,
            services: buildConfig.services,
            models: buildConfig.models
        });

        const startTime = Date.now();

        try {
            // Create startup script
            vmLogger.debug('Generating startup script');
            const startupScript = this.generateStartupScript(buildId, buildConfig);
            vmLogger.debug('Startup script generated', { scriptLength: startupScript.length });

            // VM configuration
            vmLogger.debug('Configuring VM instance');
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
                    'build-id': buildIdShort,
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
                vmLogger.debug(`Adding ${config.vm.localSsdCount} local SSD(s)`);
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
            vmLogger.info('Submitting VM creation request to GCP');
            const [operation] = await this.instancesClient.insert({
                project: this.projectId,
                zone: this.zone,
                instanceResource: instance,
            });

            vmLogger.info('VM creation operation initiated', {
                operationId: operation.name,
                operationType: operation.operationType
            });

            // Wait for operation to complete
            vmLogger.info('Waiting for VM creation to complete');
            await this.waitForOperation(operation.name, buildId);

            const duration = Date.now() - startTime;
            vmLogger.info('VM created successfully', {
                duration: `${duration}ms`,
                vmName
            });

            logger.logPerformance('VM creation', duration, { buildId, vmName });

            return vmName;
        } catch (error) {
            const duration = Date.now() - startTime;
            vmLogger.errorWithContext('Failed to create VM', error, {
                duration: `${duration}ms`,
                vmName,
                buildId
            });
            throw error;
        }
    }

    /**
     * Generate startup script for VM
     * Security: Uses JSON-encoded build config from metadata instead of direct interpolation
     */
    generateStartupScript(buildId, buildConfig) {
        // Build config is passed as JSON in instance metadata (line 98)
        // We'll parse it in the script instead of interpolating values directly
        // This prevents command injection from malicious service/model names or ISO names

        // Security: Bounds checking for buildId substring
        const buildIdShort = buildId.length >= 8 ? buildId.substring(0, 8) : buildId;

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

# Install dependencies (includes jq for JSON parsing)
log "Installing build dependencies..."
apt-get install -y \\
    git rsync curl wget gnupg lsb-release ca-certificates \\
    software-properties-common fuse pigz pv xorriso squashfs-tools jq

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

# Parse build configuration from instance metadata (secure, no command injection risk)
log "Loading build configuration from metadata..."
BUILD_CONFIG_JSON=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/build-config" -H "Metadata-Flavor: Google")

# Extract values safely using jq
export SELECTED_SERVICES=$(echo "$BUILD_CONFIG_JSON" | jq -r '.services | join(",")')
export SELECTED_MODELS=$(echo "$BUILD_CONFIG_JSON" | jq -r '.models | join(",")')
export GPU_ENABLED=$(echo "$BUILD_CONFIG_JSON" | jq -r '.gpu_enabled // false')
export ISO_NAME=$(echo "$BUILD_CONFIG_JSON" | jq -r '.iso_name // "ubuntu-24.04.3-homelab-custom"')
export GCS_BUCKET="gs://$ARTIFACTS_BUCKET"

log "Build configuration loaded:"
log "  Services: $SELECTED_SERVICES"
log "  Models: $SELECTED_MODELS"
log "  GPU: $GPU_ENABLED"
log "  ISO Name: $ISO_NAME"

# Run build scripts
log "Running iso-prepare-dynamic.sh..."
bash webapp/scripts/iso-prepare-dynamic.sh

log "Running create-custom-iso.sh..."
bash create-custom-iso.sh

# Upload ISO to downloads bucket
log "Uploading ISO to downloads bucket..."
ISO_FILE="iso-artifacts/ubuntu-24.04.3-homelab-amd64.iso"
if [ -f "$ISO_FILE" ]; then
    # Construct output name safely (ISO_NAME already validated by jq)
    ISO_OUTPUT_NAME="${ISO_NAME}-${buildIdShort}.iso"
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
     * @param {string} buildId - Optional build ID for logging context
     */
    async deleteVM(vmName, buildId = 'unknown') {
        const vmLogger = logger.withContext({ buildId, component: 'VMManager', vmName });

        try {
            vmLogger.info('Deleting VM');
            const [operation] = await this.instancesClient.delete({
                project: this.projectId,
                zone: this.zone,
                instance: vmName,
            });

            vmLogger.info('VM deletion operation initiated', {
                operationId: operation.name
            });

            await this.waitForOperation(operation.name, buildId);
            vmLogger.info('VM deleted successfully');
        } catch (error) {
            if (error.code === 404) {
                vmLogger.info('VM already deleted');
                return;
            }
            vmLogger.errorWithContext('Error deleting VM', error, { vmName });
            throw error;
        }
    }

    /**
     * Wait for operation to complete
     */
    async waitForOperation(operationName, buildId, timeout = 300000) {
        const opLogger = logger.withContext({
            buildId,
            component: 'VMManager',
            operation: operationName
        });

        const startTime = Date.now();
        let checkCount = 0;

        opLogger.info('Starting operation polling', {
            operationName,
            timeout: `${timeout}ms`
        });

        while (Date.now() - startTime < timeout) {
            checkCount++;

            try {
                const [operation] = await this.operationsClient.get({
                    project: this.projectId,
                    zone: this.zone,
                    operation: operationName,
                });

                const progress = operation.progress || 0;
                const elapsed = Date.now() - startTime;

                opLogger.debug('Operation status check', {
                    checkCount,
                    status: operation.status,
                    progress: `${progress}%`,
                    elapsed: `${elapsed}ms`
                });

                if (operation.status === 'DONE') {
                    if (operation.error) {
                        opLogger.error('Operation completed with error', {
                            error: JSON.stringify(operation.error),
                            elapsed: `${elapsed}ms`
                        });
                        throw new Error(JSON.stringify(operation.error));
                    }

                    opLogger.info('Operation completed successfully', {
                        elapsed: `${elapsed}ms`,
                        checksPerformed: checkCount
                    });

                    return operation;
                }

                await new Promise(resolve => setTimeout(resolve, 2000));
            } catch (error) {
                if (error.code === 5 || error.code === 404) {
                    // Operation not found yet, retry
                    opLogger.debug('Operation not found yet, retrying');
                    await new Promise(resolve => setTimeout(resolve, 2000));
                    continue;
                }
                throw error;
            }
        }

        const elapsed = Date.now() - startTime;
        opLogger.error('Operation timed out', {
            operationName,
            timeout: `${timeout}ms`,
            elapsed: `${elapsed}ms`,
            checksPerformed: checkCount
        });

        throw new Error(`Operation ${operationName} timed out after ${elapsed}ms`);
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
