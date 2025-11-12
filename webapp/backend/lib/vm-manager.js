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
     * Retry wrapper for Google Compute Engine API calls with exponential backoff
     * Handles transient network errors like socket hang up, timeouts, etc.
     * @param {Function} apiCall - Async function to execute (API call)
     * @param {Object} context - Logging context
     * @param {number} maxRetries - Maximum retry attempts (default: 4)
     * @returns {Promise} Result of the API call
     */
    async retryApiCall(apiCall, context = {}, maxRetries = 4) {
        const delays = [2000, 4000, 8000, 16000]; // Exponential backoff: 2s, 4s, 8s, 16s
        let lastError;

        for (let attempt = 0; attempt <= maxRetries; attempt++) {
            try {
                const result = await apiCall();

                if (attempt > 0) {
                    // Log successful retry
                    logger.info('API call succeeded after retry', {
                        ...context,
                        attempt: attempt + 1,
                        totalAttempts: maxRetries + 1
                    });
                }

                return result;
            } catch (error) {
                lastError = error;

                // Check if error is retryable
                const isRetryable = this.isRetryableError(error);
                const isLastAttempt = attempt === maxRetries;

                if (!isRetryable || isLastAttempt) {
                    // Don't retry - either not retryable or out of retries
                    if (isRetryable && isLastAttempt) {
                        logger.error('API call failed after max retries', {
                            ...context,
                            attempt: attempt + 1,
                            totalAttempts: maxRetries + 1,
                            error: error.message,
                            errorCode: error.code
                        });
                    }
                    throw error;
                }

                // Retryable error - wait and try again
                const delay = delays[attempt];
                logger.warn('API call failed, retrying', {
                    ...context,
                    attempt: attempt + 1,
                    totalAttempts: maxRetries + 1,
                    error: error.message,
                    errorCode: error.code,
                    retryInMs: delay
                });

                await new Promise(resolve => setTimeout(resolve, delay));
            }
        }

        // This should never be reached due to throw in loop, but just in case
        throw lastError;
    }

    /**
     * Check if an error is retryable (transient network/API error)
     * @param {Error} error - Error object
     * @returns {boolean} True if error should be retried
     */
    isRetryableError(error) {
        // Network errors
        const networkErrors = [
            'ECONNRESET',      // Connection reset
            'ETIMEDOUT',       // Connection timeout
            'ECONNREFUSED',    // Connection refused
            'EHOSTUNREACH',    // Host unreachable
            'ENETUNREACH',     // Network unreachable
            'EAI_AGAIN',       // DNS lookup timeout
        ];

        if (error.code && networkErrors.includes(error.code)) {
            return true;
        }

        // Socket hang up error
        if (error.message && error.message.toLowerCase().includes('socket hang up')) {
            return true;
        }

        // HTTP 503 Service Unavailable (GCP overload)
        if (error.code === 503) {
            return true;
        }

        // HTTP 429 Too Many Requests
        if (error.code === 429) {
            return true;
        }

        // Transient GCP errors
        if (error.message && (
            error.message.includes('The service is currently unavailable') ||
            error.message.includes('backend unavailable') ||
            error.message.includes('temporarily unavailable')
        )) {
            return true;
        }

        return false;
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

            // Create the VM with retry logic
            vmLogger.info('Submitting VM creation request to GCP');
            const [operation] = await this.retryApiCall(
                async () => await this.instancesClient.insert({
                    project: this.projectId,
                    zone: this.zone,
                    instanceResource: instance,
                }),
                { buildId, vmName, operation: 'createVM' }
            );

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
STATUS_FILE="gs://$DOWNLOADS_BUCKET/build-status-${buildIdShort}.json"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to write build status to GCS for real-time progress tracking
write_status() {
    local stage="$1"
    local progress="$2"
    local message="$3"

    cat > /tmp/build-status.json <<EOF
{
  "stage": "$stage",
  "progress": $progress,
  "message": "$message",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Upload status file (retry up to 3 times)
    for i in {1..3}; do
        if gsutil cp /tmp/build-status.json "$STATUS_FILE" 2>/dev/null; then
            break
        fi
        sleep 2
    done
}

log "Starting ISO build for build ID: $BUILD_ID"
write_status "initializing" 20 "Starting VM initialization"

# Update system
log "Updating system packages..."
write_status "initializing" 24 "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install dependencies (includes jq for JSON parsing)
log "Installing build dependencies..."
write_status "initializing" 28 "Installing build dependencies"
apt-get install -y \\
    git rsync curl wget gnupg lsb-release ca-certificates \\
    software-properties-common fuse pigz pv xorriso squashfs-tools jq bc

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

write_status "cloning" 33 "Cloning repository"

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
write_status "downloading" 37 "Downloading dependencies"
log "Running iso-prepare-dynamic.sh..."
bash webapp/scripts/iso-prepare-dynamic.sh

write_status "building" 66 "Building custom ISO"
log "Running create-custom-iso.sh..."
bash create-custom-iso.sh

# Upload ISO to downloads bucket with verification
write_status "uploading" 87 "Uploading ISO to storage"
log "Uploading ISO to downloads bucket..."
ISO_FILE="iso-artifacts/ubuntu-24.04.3-homelab-amd64.iso"

if [ ! -f "$ISO_FILE" ]; then
    log "ERROR: ISO file not found!"
    write_status "failed" 0 "ISO file not found after build"
    echo "failed" > /tmp/build-status
    echo "ISO file not found" > /tmp/build-error
    exit 1
fi

# Get ISO size for verification
ISO_SIZE=$(stat -c%s "$ISO_FILE")
log "ISO file size: $ISO_SIZE bytes ($(echo "scale=2; $ISO_SIZE / 1024 / 1024 / 1024" | bc) GB)"

# Construct output name safely (ISO_NAME already validated by jq)
ISO_OUTPUT_NAME="\${ISO_NAME}-${buildIdShort}.iso"
UPLOAD_TARGET="gs://$DOWNLOADS_BUCKET/$ISO_OUTPUT_NAME"

# Upload with retry logic (up to 3 attempts)
UPLOAD_SUCCESS=false
for attempt in {1..3}; do
    log "Upload attempt $attempt/3..."
    write_status "uploading" $((87 + attempt * 3)) "Uploading ISO (attempt $attempt/3)"

    if gsutil -m -o "GSUtil:parallel_process_count=4" cp "$ISO_FILE" "$UPLOAD_TARGET" 2>&1 | tee -a "$LOG_FILE"; then
        log "Upload command completed, verifying..."

        # Verify upload by checking file size in GCS
        UPLOADED_SIZE=$(gsutil stat "$UPLOAD_TARGET" | grep "Content-Length:" | awk '{print $2}' || echo "0")

        if [ "$UPLOADED_SIZE" = "$ISO_SIZE" ]; then
            log "Upload verification successful! Sizes match: $ISO_SIZE bytes"
            UPLOAD_SUCCESS=true
            break
        else
            log "Upload verification failed: Local=$ISO_SIZE, Remote=$UPLOADED_SIZE"
            if [ $attempt -lt 3 ]; then
                log "Retrying upload in 30 seconds..."
                sleep 30
            fi
        fi
    else
        log "Upload command failed"
        if [ $attempt -lt 3 ]; then
            log "Retrying upload in 30 seconds..."
            sleep 30
        fi
    fi
done

if [ "$UPLOAD_SUCCESS" = true ]; then
    log "ISO uploaded and verified successfully: $ISO_OUTPUT_NAME"
    write_status "complete" 100 "ISO build completed successfully"

    # Write build completion marker
    echo "complete" > /tmp/build-status
    echo "$ISO_OUTPUT_NAME" > /tmp/iso-filename

    log "Build process completed successfully"
else
    log "ERROR: Failed to upload ISO after 3 attempts"
    write_status "failed" 0 "Failed to upload ISO after 3 attempts"
    echo "failed" > /tmp/build-status
    echo "Failed to upload ISO" > /tmp/build-error
    exit 1
fi

# Wait for GCS sync to complete before shutting down
log "Syncing all files to GCS..."
sync
sleep 5

# Shutdown VM if auto-cleanup is enabled
${config.vm.autoCleanup ? 'log "Auto-cleanup enabled, shutting down VM in 10 seconds..."\nsleep 10\nsudo shutdown -h now' : 'log "Auto-cleanup disabled, VM will remain running"'}
`;
    }

    /**
     * Get VM status
     * @param {string} vmName - VM name
     * @returns {Object} VM status
     */
    async getVMStatus(vmName) {
        try {
            const [instance] = await this.retryApiCall(
                async () => await this.instancesClient.get({
                    project: this.projectId,
                    zone: this.zone,
                    instance: vmName,
                }),
                { vmName, operation: 'getVMStatus' }
            );

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
            const [operation] = await this.retryApiCall(
                async () => await this.instancesClient.delete({
                    project: this.projectId,
                    zone: this.zone,
                    instance: vmName,
                }),
                { buildId, vmName, operation: 'deleteVM' }
            );

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
                // Wrap API call with retry logic for transient errors
                const [operation] = await this.retryApiCall(
                    async () => await this.operationsClient.get({
                        project: this.projectId,
                        zone: this.zone,
                        operation: operationName,
                    }),
                    { buildId, operation: 'waitForOperation', operationName },
                    2 // Fewer retries for polling (2 attempts = 1 retry)
                );

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
