// Build Orchestrator - Coordinates ISO build process

const { v4: uuidv4 } = require('uuid');
const config = require('../config/config');
const logger = require('./logger');
const vmManager = require('./vm-manager');
const gcsManager = require('./gcs-manager');

class BuildOrchestrator {
    constructor() {
        // In-memory build state (in production, use Redis or database)
        this.builds = new Map();
        this.activeBuildCount = 0;

        // Security: Maximum number of builds to keep in memory
        // Prevents unbounded memory growth from accumulating build history
        this.MAX_BUILDS_IN_MEMORY = 1000;

        // Start periodic cleanup
        this.startPeriodicCleanup();
    }

    /**
     * Start a new ISO build
     * @param {Object} buildConfig - Build configuration
     * @returns {Object} Build info
     */
    async startBuild(buildConfig) {
        // Validate configuration
        this.validateBuildConfig(buildConfig);

        // Security: Atomic check-and-increment to prevent race condition
        // Count active builds (not queued/complete/failed)
        let activeCount = 0;
        for (const build of this.builds.values()) {
            if (build.status !== 'complete' && build.status !== 'failed') {
                activeCount++;
            }
        }

        if (activeCount >= config.vm.maxConcurrentBuilds) {
            throw new Error(`Maximum concurrent builds (${config.vm.maxConcurrentBuilds}) reached. Please try again later.`);
        }

        // Generate build ID
        const buildId = uuidv4();

        // Initialize build state
        const build = {
            id: buildId,
            config: buildConfig,
            status: 'queued',
            progress: 0,
            stage: 'queued',
            vmName: null,
            isoFilename: null,
            vmLogsPath: null,
            logs: [],
            created: new Date().toISOString(),
            updated: new Date().toISOString(),
            estimatedCompletion: this.estimateCompletion(buildConfig),
        };

        this.builds.set(buildId, build);
        this.activeBuildCount++;

        // Security: Enforce memory bounds - remove oldest completed/failed builds if limit exceeded
        if (this.builds.size > this.MAX_BUILDS_IN_MEMORY) {
            this.enforceMemoryBounds();
        }

        logger.info(`Build ${buildId} queued`, { config: buildConfig });

        // Start build asynchronously
        this.executeBuild(buildId).catch(error => {
            logger.error(`Build ${buildId} failed:`, error);
            this.updateBuildStatus(buildId, {
                status: 'failed',
                error: error.message,
            });
        });

        return {
            build_id: buildId,
            status: build.status,
            estimated_time_minutes: this.estimateTimestampMinutes(buildConfig),
        };
    }

    /**
     * Execute the build process
     */
    async executeBuild(buildId) {
        const build = this.builds.get(buildId);
        if (!build) {
            throw new Error(`Build ${buildId} not found`);
        }

        try {
            // Update status: Creating VM
            this.updateBuildStatus(buildId, {
                status: 'creating_vm',
                progress: 10,
                stage: 'Creating VM instance...',
            });

            // Create VM
            const vmName = await vmManager.createBuildVM(buildId, build.config);
            this.updateBuildStatus(buildId, {
                vmName,
                logs: [...build.logs, `VM created: ${vmName}`],
            });

            // Update status: Building
            this.updateBuildStatus(buildId, {
                status: 'building',
                progress: 20,
                stage: 'Downloading dependencies...',
                logs: [...build.logs, 'VM initialization in progress...'],
            });

            // Poll VM for build completion
            await this.pollBuildCompletion(buildId, vmName);

        } catch (error) {
            logger.error(`Build ${buildId} execution failed:`, error);
            this.updateBuildStatus(buildId, {
                status: 'failed',
                error: error.message,
                logs: [...build.logs, `ERROR: ${error.message}`],
            });

            // Cleanup VM on failure (with log export)
            if (build.vmName) {
                try {
                    const logPath = await vmManager.exportVMLogs(build.vmName, buildId);
                    if (logPath) {
                        this.updateBuildStatus(buildId, {
                            vmLogsPath: logPath,
                            logs: [...build.logs, `VM logs exported to: ${logPath}`],
                        });
                    }
                    await vmManager.deleteVM(build.vmName, buildId, false); // Logs already exported
                } catch (cleanupError) {
                    logger.error(`Failed to cleanup VM ${build.vmName}:`, cleanupError);
                }
            }

            this.activeBuildCount--;
        }
    }

    /**
     * Poll VM for build completion
     */
    async pollBuildCompletion(buildId, vmName) {
        const build = this.builds.get(buildId);
        const startTime = Date.now();
        const timeoutMs = config.vm.buildTimeout * 60 * 60 * 1000; // hours to ms
        const buildIdShort = buildId.length >= 8 ? buildId.substring(0, 8) : buildId;
        const statusFile = `build-status-${buildIdShort}.json`;
        let lastLoggedProgress = -1; // Track last logged progress to avoid spam
        let lastProgressUpdateTime = Date.now(); // Track when progress last changed
        let lastProgress = 0; // Track last progress value

        while (Date.now() - startTime < timeoutMs) {
            // Check VM status
            const vmStatus = await vmManager.getVMStatus(vmName);
            if (!vmStatus) {
                throw new Error('VM no longer exists');
            }

            // Try to read real-time status from GCS
            let progress = 0;
            let stage = 'Initializing...';

            try {
                const statusExists = await gcsManager.isoExists(statusFile);
                if (statusExists) {
                    // Download and parse status file
                    const statusData = await gcsManager.downloadStatusFile(statusFile);
                    if (statusData) {
                        progress = statusData.progress || 0;
                        stage = statusData.message || statusData.stage || stage;

                        // Add status update to logs if it's a new message
                        const lastLog = build.logs[build.logs.length - 1] || '';
                        if (!lastLog.includes(stage)) {
                            this.updateBuildStatus(buildId, {
                                logs: [...build.logs, `[${statusData.stage}] ${statusData.message}`],
                            });
                        }

                        // Only log progress if it changed by 1% or more
                        if (Math.abs(progress - lastLoggedProgress) >= 1) {
                            logger.info(`[build:${buildIdShort}] Progress: ${progress}% - ${stage}`);
                            lastLoggedProgress = progress;
                        }
                    }
                }
            } catch (error) {
                logger.debug(`Could not read status file for build ${buildIdShort}: ${error.message}`);
                // Fall back to time-based estimation if status file not available yet
                const elapsedMinutes = (Date.now() - startTime) / 60000;
                const estimatedMinutes = this.estimateBuildMinutes(build.config);
                progress = Math.min(85, Math.floor((elapsedMinutes / estimatedMinutes) * 100));
                stage = this.getStageForProgress(progress);
            }

            // Check if build status indicates completion
            if (progress >= 100) {
                // Build marked as complete in status file
                const isoFilename = `${build.config.iso_name || 'ubuntu-24.04.3-homelab-custom'}-${buildIdShort}.iso`;
                const exists = await gcsManager.isoExists(isoFilename);

                if (exists) {
                    // Build successful
                    this.updateBuildStatus(buildId, {
                        status: 'complete',
                        progress: 100,
                        stage: 'Complete',
                        isoFilename,
                        logs: [...build.logs, 'ISO build completed and uploaded successfully!'],
                    });

                    // Cleanup VM (with log export)
                    if (config.vm.autoCleanup) {
                        try {
                            // Export logs before deletion (enabled by default)
                            const vmLogsPath = await vmManager.deleteVM(vmName, buildId, true);
                            logger.info(`Cleaned up VM ${vmName}`);

                            // Update build status with log path if exported
                            if (vmLogsPath) {
                                this.updateBuildStatus(buildId, {
                                    vmLogsPath,
                                    logs: [...build.logs, `VM logs saved to: ${vmLogsPath}`],
                                });
                            }
                        } catch (error) {
                            logger.warn(`Failed to cleanup VM ${vmName}: ${error.message}`);
                        }
                    }

                    // Cleanup status file
                    try {
                        await gcsManager.deleteFile(statusFile);
                    } catch (error) {
                        logger.debug(`Could not delete status file: ${error.message}`);
                    }

                    this.activeBuildCount--;
                    return;
                } else {
                    // Status says complete but ISO not found - wait a bit for sync
                    logger.warn(`Build ${buildIdShort} marked complete but ISO not found yet, waiting...`);
                    await new Promise(resolve => setTimeout(resolve, 5000));

                    // Check again
                    const existsNow = await gcsManager.isoExists(isoFilename);
                    if (existsNow) {
                        this.updateBuildStatus(buildId, {
                            status: 'complete',
                            progress: 100,
                            stage: 'Complete',
                            isoFilename,
                            logs: [...build.logs, 'ISO build completed and uploaded successfully!'],
                        });

                        if (config.vm.autoCleanup) {
                            const vmLogsPath = await vmManager.deleteVM(vmName, buildId, true);
                            if (vmLogsPath) {
                                this.updateBuildStatus(buildId, {
                                    vmLogsPath,
                                    logs: [...build.logs, `VM logs saved to: ${vmLogsPath}`],
                                });
                            }
                        }

                        try {
                            await gcsManager.deleteFile(statusFile);
                        } catch (error) {
                            logger.debug(`Could not delete status file: ${error.message}`);
                        }

                        this.activeBuildCount--;
                        return;
                    } else {
                        throw new Error('Build marked complete but ISO not found in downloads bucket');
                    }
                }
            }

            // Check if VM has shut down unexpectedly (before status showed complete)
            if (vmStatus.status === 'TERMINATED' || vmStatus.status === 'STOPPED') {
                // VM stopped - check if build actually completed
                const isoFilename = `${build.config.iso_name || 'ubuntu-24.04.3-homelab-custom'}-${buildIdShort}.iso`;
                const exists = await gcsManager.isoExists(isoFilename);

                if (exists) {
                    // Build successful (VM shut down after completion)
                    this.updateBuildStatus(buildId, {
                        status: 'complete',
                        progress: 100,
                        stage: 'Complete',
                        isoFilename,
                        logs: [...build.logs, 'ISO build completed successfully!'],
                    });

                    // Export logs even though VM is stopped
                    if (config.vm.autoCleanup) {
                        try {
                            const vmLogsPath = await vmManager.exportVMLogs(vmName, buildId);
                            if (vmLogsPath) {
                                this.updateBuildStatus(buildId, {
                                    vmLogsPath,
                                    logs: [...build.logs, `VM logs saved to: ${vmLogsPath}`],
                                });
                            }
                        } catch (error) {
                            logger.warn(`Failed to export VM logs: ${error.message}`);
                        }
                    }

                    try {
                        await gcsManager.deleteFile(statusFile);
                    } catch (error) {
                        logger.debug(`Could not delete status file: ${error.message}`);
                    }

                    this.activeBuildCount--;
                    return;
                } else {
                    throw new Error('VM stopped but ISO not found in downloads bucket - build may have failed');
                }
            }

            // Update progress only if it changed by 1% or more
            // Always update stage in case there are stage changes without progress changes
            const progressChanged = Math.abs(progress - build.progress) >= 1;
            const stageChanged = stage !== build.stage;

            if (progressChanged || stageChanged) {
                this.updateBuildStatus(buildId, {
                    progress,
                    stage,
                });
            }

            // Check for stalled progress - if progress hasn't changed in stalledProgressMinutes
            if (progress !== lastProgress) {
                lastProgress = progress;
                lastProgressUpdateTime = Date.now();
            } else {
                const stalledMinutes = (Date.now() - lastProgressUpdateTime) / 60000;
                const stalledThreshold = config.vm.stalledProgressMinutes || 30;

                if (stalledMinutes > stalledThreshold && progress < 95) {
                    logger.error(`Build ${buildIdShort} stalled: no progress for ${Math.floor(stalledMinutes)} minutes at ${progress}%`);
                    throw new Error(`Build stalled: no progress for ${Math.floor(stalledMinutes)} minutes at ${progress}%. Last stage: ${stage}`);
                }
            }

            // Wait before next poll
            await new Promise(resolve => setTimeout(resolve, config.build.pollIntervalMs));
        }

        throw new Error(`Build timeout exceeded (${config.vm.buildTimeout} hours)`);
    }

    /**
     * Get build status
     * @param {string} buildId - Build ID
     * @returns {Object} Build status (or Promise if checking GCS)
     */
    getBuildStatus(buildId) {
        const build = this.builds.get(buildId);
        if (!build) {
            // Not in memory - check GCS for build status file
            return this.getBuildStatusFromGCS(buildId);
        }

        return {
            build_id: build.id,
            status: build.status,
            progress: build.progress,
            stage: build.stage,
            vm_name: build.vmName,
            iso_filename: build.isoFilename,
            vm_logs_path: build.vmLogsPath,
            logs: build.logs,
            created: build.created,
            updated: build.updated,
            estimated_completion: build.estimatedCompletion,
            error: build.error,
        };
    }

    /**
     * Get build status from GCS (for builds from previous container instances)
     * @param {string} buildId - Build ID
     * @returns {Promise<Object>} Build status
     */
    async getBuildStatusFromGCS(buildId) {
        const statusFile = `build-status-${buildId}.json`;

        try {
            // Check if status file exists in downloads bucket
            const statusData = await gcsManager.downloadStatusFile(statusFile);

            if (!statusData) {
                return null;
            }

            // Reconstruct basic build info from GCS status
            const isoFilename = `ubuntu-24.04.3-homelab-custom-${buildId}.iso`;

            return {
                build_id: buildId,
                status: statusData.stage === 'complete' ? 'complete' :
                        statusData.stage === 'failed' ? 'failed' : 'building',
                progress: statusData.progress || 0,
                stage: statusData.stage || 'unknown',
                vm_name: `iso-build-${buildId}`,
                iso_filename: statusData.stage === 'complete' ? isoFilename : null,
                logs: [statusData.message || 'Build status recovered from GCS'],
                created: statusData.timestamp || null,
                updated: statusData.timestamp || null,
                estimated_completion: null,
                error: statusData.stage === 'failed' ? statusData.message : null,
            };
        } catch (error) {
            logger.error(`Failed to get build status from GCS for ${buildId}:`, error);
            return null;
        }
    }

    /**
     * Update build status
     */
    updateBuildStatus(buildId, updates) {
        const build = this.builds.get(buildId);
        if (!build) {
            return;
        }

        Object.assign(build, {
            ...updates,
            updated: new Date().toISOString(),
        });

        this.builds.set(buildId, build);
        logger.debug(`Build ${buildId} status updated:`, updates);
    }

    /**
     * Validate build configuration
     * SECURITY: Comprehensive validation with path traversal and injection prevention
     */
    validateBuildConfig(buildConfig) {
        const { services, models, iso_name } = buildConfig;

        // SECURITY: Validate services array
        if (!services || !Array.isArray(services)) {
            throw new Error('services must be an array');
        }

        if (services.length === 0) {
            throw new Error('At least one service must be selected');
        }

        // SECURITY: Check array length BEFORE iterating (DoS protection)
        if (services.length > config.build.maxServicesPerBuild) {
            throw new Error(`Maximum ${config.build.maxServicesPerBuild} services allowed`);
        }

        // SECURITY: Validate each service is a string with safe format
        services.forEach((service, index) => {
            // Type check
            if (typeof service !== 'string') {
                throw new Error(`Service at index ${index} must be a string, got ${typeof service}`);
            }

            // Length check (prevent memory exhaustion)
            if (service.length > 100) {
                throw new Error(`Service name too long at index ${index}: maximum 100 characters`);
            }

            // Format check: only lowercase alphanumeric and hyphens
            if (!/^[a-z0-9-]+$/.test(service)) {
                throw new Error(`Invalid service name format: ${service}. Use only lowercase letters, numbers, and hyphens.`);
            }

            // Whitelist check
            if (!config.services[service]) {
                throw new Error(`Unknown service: ${service}`);
            }
        });

        // SECURITY: Validate models array (if provided)
        if (models) {
            if (!Array.isArray(models)) {
                throw new Error('models must be an array');
            }

            // Length check (DoS protection)
            if (models.length > config.build.maxModelsPerBuild) {
                throw new Error(`Maximum ${config.build.maxModelsPerBuild} models allowed`);
            }

            models.forEach((model, index) => {
                // Type check
                if (typeof model !== 'string') {
                    throw new Error(`Model at index ${index} must be a string, got ${typeof model}`);
                }

                // Length check
                if (model.length > 100) {
                    throw new Error(`Model name too long at index ${index}: maximum 100 characters`);
                }

                // Format check: name:tag pattern
                if (!/^[a-z0-9-]+:[a-z0-9.-]+$/.test(model)) {
                    throw new Error(`Invalid model format: ${model}. Expected format: modelname:tag`);
                }

                // Whitelist check
                if (!config.models[model]) {
                    throw new Error(`Unknown model: ${model}`);
                }
            });
        }

        // SECURITY: Validate ISO name with comprehensive path traversal prevention
        if (iso_name) {
            // Type check
            if (typeof iso_name !== 'string') {
                throw new Error('iso_name must be a string');
            }

            // Decode to check for encoded path traversal attempts
            let decoded;
            try {
                decoded = decodeURIComponent(iso_name);
            } catch (e) {
                throw new Error('Invalid ISO name: contains malformed URL encoding');
            }

            // SECURITY: Comprehensive path traversal checks (both encoded and decoded)
            const pathTraversalPatterns = [
                /\.\./,                  // Dot-dot
                /[\/\\]/,               // Slashes (forward or back)
                /%2[eE]%2[eE]/i,        // URL-encoded .. (%2e%2e)
                /%2[fF]/i,              // URL-encoded / (%2f)
                /%5[cC]/i,              // URL-encoded \ (%5c)
                /\x00/,                 // Null bytes
                /[^\x20-\x7E]/,         // Non-printable ASCII
                /^[A-Z]:/i,             // Windows drive letters (C:)
                /^\\\\/,                // UNC paths (\\)
                /\u002e\u002e/,         // Unicode encoded dots
                /\uff0e\uff0e/,         // Full-width Unicode dots
            ];

            for (const pattern of pathTraversalPatterns) {
                if (pattern.test(iso_name) || pattern.test(decoded)) {
                    throw new Error('Invalid ISO name: prohibited pattern detected (possible path traversal attempt)');
                }
            }

            // SECURITY: Strict whitelist - only safe filename characters
            if (!/^[a-zA-Z0-9._-]+$/.test(iso_name)) {
                throw new Error('Invalid ISO name. Use only: a-z A-Z 0-9 . - _');
            }

            // Length check (filesystem limit is 255, use 200 for safety margin)
            if (iso_name.length > 200) {
                throw new Error('Invalid ISO name. Maximum length is 200 characters.');
            }

            // Minimum length (prevent single-char names that could be special)
            if (iso_name.length < 3) {
                throw new Error('Invalid ISO name. Minimum length is 3 characters.');
            }

            // Check for leading/trailing periods or hyphens (filesystem edge cases)
            if (/^[.-]|[.-]$/.test(iso_name)) {
                throw new Error('Invalid ISO name. Cannot start or end with period or hyphen.');
            }

            // Check for consecutive special characters (could indicate obfuscation)
            if (/[._-]{3,}/.test(iso_name)) {
                throw new Error('Invalid ISO name. Cannot contain 3+ consecutive special characters.');
            }

            // Reserved names check (Windows reserved names, just in case)
            const reservedNames = ['CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4',
                                   'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2',
                                   'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'];
            if (reservedNames.includes(iso_name.toUpperCase())) {
                throw new Error('Invalid ISO name. Name is reserved by the system.');
            }
        }
    }

    /**
     * Estimate build completion time
     */
    estimateCompletion(buildConfig) {
        const minutes = this.estimateBuildMinutes(buildConfig);
        const completion = new Date(Date.now() + minutes * 60000);
        return completion.toISOString();
    }

    /**
     * Estimate build time in minutes
     */
    estimateBuildMinutes(buildConfig) {
        const { services, models } = buildConfig;

        let minutes = 30; // Base time
        minutes += services.length * 2; // 2 min per service

        if (models && models.length > 0) {
            minutes += models.length * 5; // 5 min per model
            const totalModelSize = models.reduce((sum, model) => {
                return sum + (config.models[model]?.size_gb || 0);
            }, 0);
            minutes += totalModelSize; // 1 min per GB
        }

        minutes += 15; // ISO creation

        return Math.ceil(minutes);
    }

    /**
     * Get stage description for progress percentage
     */
    getStageForProgress(progress) {
        if (progress < 20) return 'Creating VM and initializing...';
        if (progress < 40) return 'Downloading dependencies...';
        if (progress < 60) return 'Downloading Docker images...';
        if (progress < 80) return 'Downloading AI models...';
        if (progress < 90) return 'Building custom ISO...';
        if (progress < 95) return 'Uploading ISO to storage...';
        return 'Finalizing...';
    }

    /**
     * Get estimate in minutes (helper for API response)
     */
    estimateTimestampMinutes(buildConfig) {
        return this.estimateBuildMinutes(buildConfig);
    }

    /**
     * Enforce memory bounds by removing oldest completed/failed builds
     * Security: Prevents unbounded memory growth
     */
    enforceMemoryBounds() {
        // Get completed and failed builds sorted by creation time (oldest first)
        const finishedBuilds = Array.from(this.builds.entries())
            .filter(([_, build]) => build.status === 'complete' || build.status === 'failed')
            .sort((a, b) => new Date(a[1].created) - new Date(b[1].created));

        // Remove oldest builds until we're under the limit
        const buildsToRemove = this.builds.size - this.MAX_BUILDS_IN_MEMORY + 10; // Remove 10 extra for buffer
        if (buildsToRemove > 0) {
            logger.warn(`Memory bounds exceeded (${this.builds.size} builds), removing ${buildsToRemove} oldest builds`);

            for (let i = 0; i < Math.min(buildsToRemove, finishedBuilds.length); i++) {
                const [buildId] = finishedBuilds[i];
                this.builds.delete(buildId);
                logger.info(`Removed old build from memory: ${buildId}`);
            }
        }
    }

    /**
     * Cleanup old completed builds from memory
     */
    startPeriodicCleanup() {
        setInterval(() => {
            const now = Date.now();
            const maxAge = 24 * 60 * 60 * 1000; // 24 hours

            for (const [buildId, build] of this.builds.entries()) {
                const age = now - new Date(build.created).getTime();
                if (age > maxAge && (build.status === 'complete' || build.status === 'failed')) {
                    logger.info(`Cleaning up old build: ${buildId}`);
                    this.builds.delete(buildId);
                }
            }
        }, 60 * 60 * 1000); // Run every hour
    }
}

module.exports = new BuildOrchestrator();
