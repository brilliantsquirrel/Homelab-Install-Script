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

        // Check concurrent build limit
        if (this.activeBuildCount >= config.vm.maxConcurrentBuilds) {
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
            logs: [],
            created: new Date().toISOString(),
            updated: new Date().toISOString(),
            estimatedCompletion: this.estimateCompletion(buildConfig),
        };

        this.builds.set(buildId, build);
        this.activeBuildCount++;

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

            // Cleanup VM on failure
            if (build.vmName) {
                try {
                    await vmManager.deleteVM(build.vmName);
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

        while (Date.now() - startTime < timeoutMs) {
            // Check VM status
            const vmStatus = await vmManager.getVMStatus(vmName);
            if (!vmStatus) {
                throw new Error('VM no longer exists');
            }

            // In a real implementation, we would check build status file on VM
            // For now, simulate progress based on time elapsed
            const elapsedMinutes = (Date.now() - startTime) / 60000;
            const estimatedMinutes = this.estimateBuildMinutes(build.config);

            let progress = Math.min(95, Math.floor((elapsedMinutes / estimatedMinutes) * 100));
            let stage = this.getStageForProgress(progress);

            // Check if VM has shut down (indicates completion)
            if (vmStatus.status === 'TERMINATED' || vmStatus.status === 'STOPPED') {
                // Build completed, check for ISO
                const isoFilename = `${build.config.iso_name || 'ubuntu-24.04.3-homelab-custom'}-${buildId.substring(0, 8)}.iso`;
                const exists = await gcsManager.isoExists(isoFilename);

                if (exists) {
                    // Build successful
                    this.updateBuildStatus(buildId, {
                        status: 'complete',
                        progress: 100,
                        stage: 'Complete',
                        isoFilename,
                        logs: [...build.logs, 'ISO build completed successfully!'],
                    });

                    // Cleanup VM
                    if (config.vm.autoCleanup) {
                        await vmManager.deleteVM(vmName);
                        logger.info(`Cleaned up VM ${vmName}`);
                    }

                    this.activeBuildCount--;
                    return;
                } else {
                    throw new Error('Build completed but ISO not found in downloads bucket');
                }
            }

            // Update progress
            this.updateBuildStatus(buildId, {
                progress,
                stage,
            });

            // Wait before next poll
            await new Promise(resolve => setTimeout(resolve, config.build.pollIntervalMs));
        }

        throw new Error('Build timeout exceeded');
    }

    /**
     * Get build status
     * @param {string} buildId - Build ID
     * @returns {Object} Build status
     */
    getBuildStatus(buildId) {
        const build = this.builds.get(buildId);
        if (!build) {
            return null;
        }

        return {
            build_id: build.id,
            status: build.status,
            progress: build.progress,
            stage: build.stage,
            vm_name: build.vmName,
            iso_filename: build.isoFilename,
            logs: build.logs,
            created: build.created,
            updated: build.updated,
            estimated_completion: build.estimatedCompletion,
            error: build.error,
        };
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
     */
    validateBuildConfig(buildConfig) {
        const { services, models, iso_name } = buildConfig;

        if (!services || !Array.isArray(services) || services.length === 0) {
            throw new Error('At least one service must be selected');
        }

        if (services.length > config.build.maxServicesPerBuild) {
            throw new Error(`Maximum ${config.build.maxServicesPerBuild} services allowed`);
        }

        if (models && models.length > config.build.maxModelsPerBuild) {
            throw new Error(`Maximum ${config.build.maxModelsPerBuild} models allowed`);
        }

        // Validate service names
        services.forEach(service => {
            if (!config.services[service]) {
                throw new Error(`Invalid service: ${service}`);
            }
        });

        // Validate model names
        if (models) {
            models.forEach(model => {
                if (!config.models[model]) {
                    throw new Error(`Invalid model: ${model}`);
                }
            });
        }

        // Validate ISO name (alphanumeric, periods, hyphens, underscores only)
        if (iso_name) {
            // Check character whitelist
            if (!/^[a-zA-Z0-9._-]+$/.test(iso_name)) {
                throw new Error('Invalid ISO name. Use only alphanumeric characters, periods, hyphens, and underscores.');
            }

            // Check for path traversal patterns
            if (iso_name.includes('..') || iso_name.includes('/') || iso_name.includes('\\')) {
                throw new Error('Invalid ISO name. Path traversal patterns not allowed.');
            }

            // Check length (max 255 characters for filesystem compatibility)
            if (iso_name.length > 255) {
                throw new Error('Invalid ISO name. Maximum length is 255 characters.');
            }

            // Check for leading/trailing periods or hyphens (filesystem edge cases)
            if (/^[.-]|[.-]$/.test(iso_name)) {
                throw new Error('Invalid ISO name. Cannot start or end with period or hyphen.');
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
