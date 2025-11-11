// Main Application Logic for Homelab ISO Builder

class HomeLabISOBuilder {
    constructor() {
        this.currentStep = 1;
        this.selectedServices = new Set();
        this.selectedModels = new Set();
        this.buildId = null;
        this.buildStartTime = null;
        this.pollingInterval = null;

        // Service dependencies map
        this.serviceDependencies = {
            'openwebui': ['ollama'],
            'langflow': ['ollama'],
            'langgraph': ['ollama', 'langgraph-redis', 'langgraph-db'],
            'n8n': ['ollama'],
            'nextcloud': ['nextcloud-db', 'nextcloud-redis'],
            'portainer': ['docker-socket-proxy'],
        };

        // Service sizes (in GB)
        this.serviceSizes = {
            'ollama': 2.0,
            'openwebui': 0.5,
            'langflow': 1.5,
            'langgraph': 0.8,
            'langgraph-redis': 0.05,
            'langgraph-db': 0.1,
            'qdrant': 0.3,
            'n8n': 0.6,
            'nextcloud': 1.2,
            'nextcloud-db': 0.1,
            'nextcloud-redis': 0.05,
            'plex': 0.8,
            'pihole': 0.2,
            'homarr': 0.15,
            'hoarder': 0.1,
            'portainer': 0.3,
            'docker-socket-proxy': 0.05,
            'nginx': 0.05,
        };

        this.init();
    }

    init() {
        // Initialize event listeners
        this.setupServiceListeners();
        this.setupModelListeners();
        this.updateSummary();

        // Check for Ollama selection to enable/disable models
        this.checkOllamaSelected();
    }

    setupServiceListeners() {
        const serviceCheckboxes = document.querySelectorAll('input[name="service"]');
        serviceCheckboxes.forEach(checkbox => {
            checkbox.addEventListener('change', (e) => {
                const serviceName = e.target.value;

                if (e.target.checked) {
                    this.selectedServices.add(serviceName);
                    // Auto-select dependencies
                    this.selectDependencies(serviceName);
                } else {
                    this.selectedServices.delete(serviceName);
                    // Check if any other service depends on this one
                    this.checkDependents(serviceName);
                }

                this.updateSummary();
                this.checkOllamaSelected();
            });
        });
    }

    setupModelListeners() {
        const modelCheckboxes = document.querySelectorAll('input[name="model"]');
        modelCheckboxes.forEach(checkbox => {
            checkbox.addEventListener('change', (e) => {
                const modelName = e.target.value;

                if (e.target.checked) {
                    this.selectedModels.add(modelName);
                } else {
                    this.selectedModels.delete(modelName);
                }

                this.updateSummary();
            });
        });
    }

    selectDependencies(serviceName) {
        const deps = this.serviceDependencies[serviceName] || [];
        deps.forEach(dep => {
            this.selectedServices.add(dep);
            // Check the checkbox
            const checkbox = document.querySelector(`input[name="service"][value="${dep}"]`);
            if (checkbox) {
                checkbox.checked = true;
            }
        });
    }

    checkDependents(serviceName) {
        // Check if any selected service depends on this service
        let hasDependent = false;
        for (const [service, deps] of Object.entries(this.serviceDependencies)) {
            if (deps.includes(serviceName) && this.selectedServices.has(service)) {
                hasDependent = true;
                break;
            }
        }

        // If this service is a dependency and still needed, keep it selected
        if (hasDependent) {
            const checkbox = document.querySelector(`input[name="service"][value="${serviceName}"]`);
            if (checkbox) {
                checkbox.checked = true;
                this.selectedServices.add(serviceName);
            }
        }
    }

    checkOllamaSelected() {
        const ollamaSelected = this.selectedServices.has('ollama');
        const modelCheckboxes = document.querySelectorAll('input[name="model"]');
        const modelsNotice = document.getElementById('models-disabled-notice');

        modelCheckboxes.forEach(checkbox => {
            checkbox.disabled = !ollamaSelected;
            if (!ollamaSelected) {
                checkbox.checked = false;
                this.selectedModels.delete(checkbox.value);
            }
        });

        if (modelsNotice) {
            modelsNotice.style.display = ollamaSelected ? 'none' : 'block';
        }
    }

    updateSummary() {
        // Update service count
        const serviceCount = this.selectedServices.size;
        document.getElementById('summary-services').textContent =
            `${serviceCount} service${serviceCount !== 1 ? 's' : ''}`;

        // Update model count
        const modelCount = this.selectedModels.size;
        document.getElementById('summary-models').textContent =
            `${modelCount} model${modelCount !== 1 ? 's' : ''}`;

        // Calculate total service size
        let serviceSizeGB = 0;
        this.selectedServices.forEach(service => {
            serviceSizeGB += this.serviceSizes[service] || 0;
        });

        // Calculate total model size
        let modelSizeGB = 0;
        this.selectedModels.forEach(modelName => {
            const checkbox = document.querySelector(`input[name="model"][value="${modelName}"]`);
            if (checkbox) {
                const sizeStr = checkbox.dataset.size;
                modelSizeGB += parseFloat(sizeStr) || 0;
            }
        });

        // Calculate estimated ISO size
        const totalSize = window.api.estimateISOSize(serviceCount, serviceSizeGB, modelSizeGB);
        document.getElementById('summary-size').textContent = `~${totalSize}GB`;

        // Calculate estimated build time
        const buildTime = window.api.estimateBuildTime(serviceCount, modelCount, modelSizeGB);
        document.getElementById('summary-time').textContent = `~${buildTime} minutes`;
    }

    nextStep() {
        const currentSection = document.querySelector('.step.active');
        currentSection.classList.remove('active');

        this.currentStep++;
        const nextSection = document.getElementById(this.getStepId(this.currentStep));
        nextSection.classList.add('active');

        // Scroll to top
        window.scrollTo(0, 0);
    }

    prevStep() {
        const currentSection = document.querySelector('.step.active');
        currentSection.classList.remove('active');

        this.currentStep--;
        const prevSection = document.getElementById(this.getStepId(this.currentStep));
        prevSection.classList.add('active');

        // Scroll to top
        window.scrollTo(0, 0);
    }

    getStepId(step) {
        const steps = ['step-services', 'step-models', 'step-config', 'step-progress', 'step-complete'];
        return steps[step - 1];
    }

    async startBuild() {
        // Validate selections
        if (this.selectedServices.size === 0) {
            alert('Please select at least one service.');
            return;
        }

        // Get configuration
        const gpuEnabled = document.getElementById('gpu-enabled').checked;
        const email = document.getElementById('email').value;
        const isoName = document.getElementById('iso-name').value || 'ubuntu-24.04.3-homelab-custom';

        // Prepare build request
        const buildConfig = {
            services: Array.from(this.selectedServices),
            models: Array.from(this.selectedModels),
            gpu_enabled: gpuEnabled,
            email: email || undefined,
            iso_name: isoName,
        };

        try {
            // Show progress step
            this.nextStep();

            // Reset progress
            this.updateProgress(0, 'Initializing build...');
            document.getElementById('build-id').textContent = 'Pending...';
            document.getElementById('vm-name').textContent = 'Creating...';
            document.getElementById('estimated-completion').textContent = 'Calculating...';
            this.clearLogs();
            this.addLog('Submitting build request...');

            // Start build
            const response = await window.api.startBuild(buildConfig);
            this.buildId = response.build_id;
            this.buildStartTime = Date.now();

            // Update UI with build info
            document.getElementById('build-id').textContent = this.buildId;
            this.addLog(`Build ID: ${this.buildId}`);
            this.addLog(`Status: ${response.status}`);

            if (response.estimated_time_minutes) {
                const estimatedCompletion = new Date(Date.now() + response.estimated_time_minutes * 60000);
                document.getElementById('estimated-completion').textContent =
                    estimatedCompletion.toLocaleTimeString();
            }

            // Start polling for status
            this.startStatusPolling();

        } catch (error) {
            console.error('Build failed to start:', error);
            this.showError('Failed to start build', error.message);
        }
    }

    startStatusPolling() {
        // Poll every 5 seconds
        this.pollingInterval = setInterval(async () => {
            try {
                const status = await window.api.getBuildStatus(this.buildId);
                this.handleStatusUpdate(status);
            } catch (error) {
                console.error('Failed to get build status:', error);
                this.stopStatusPolling();
                this.showError('Failed to get build status', error.message);
            }
        }, 5000);
    }

    stopStatusPolling() {
        if (this.pollingInterval) {
            clearInterval(this.pollingInterval);
            this.pollingInterval = null;
        }
    }

    handleStatusUpdate(status) {
        // Update progress
        this.updateProgress(status.progress || 0, status.stage || 'Building...');

        // Update VM name
        if (status.vm_name) {
            document.getElementById('vm-name').textContent = status.vm_name;
        }

        // Update logs
        if (status.logs && Array.isArray(status.logs)) {
            status.logs.forEach(log => {
                if (!this.hasLog(log)) {
                    this.addLog(log);
                }
            });
        }

        // Check if complete
        if (status.status === 'complete') {
            this.stopStatusPolling();
            this.handleBuildComplete(status);
        } else if (status.status === 'failed' || status.status === 'error') {
            this.stopStatusPolling();
            this.showError('Build failed', status.error || 'Unknown error');
        }
    }

    handleBuildComplete(status) {
        const buildDuration = Math.floor((Date.now() - this.buildStartTime) / 1000);

        // Show completion step
        const currentSection = document.querySelector('.step.active');
        currentSection.classList.remove('active');
        document.getElementById('step-complete').classList.add('active');

        // Update completion info
        document.getElementById('complete-build-id').textContent = this.buildId;
        document.getElementById('complete-size').textContent =
            status.iso_size ? window.api.formatBytes(status.iso_size) : 'Unknown';
        document.getElementById('complete-time').textContent =
            window.api.formatDuration(buildDuration);

        // Scroll to top
        window.scrollTo(0, 0);
    }

    async downloadISO() {
        try {
            const response = await window.api.getDownloadURL(this.buildId);

            if (response.download_url) {
                // Redirect to download URL
                window.location.href = response.download_url;
            } else if (response.redirect_url) {
                // Open in new tab (for signed URLs)
                window.open(response.redirect_url, '_blank');
            } else {
                throw new Error('No download URL provided');
            }
        } catch (error) {
            console.error('Download failed:', error);
            alert(`Failed to download ISO: ${error.message}`);
        }
    }

    updateProgress(percentage, stage) {
        const progressFill = document.getElementById('progress-fill');
        const progressPercentage = document.getElementById('progress-percentage');
        const progressStage = document.getElementById('progress-stage');

        progressFill.style.width = `${percentage}%`;
        progressPercentage.textContent = `${percentage}%`;
        progressStage.textContent = stage;
    }

    addLog(message) {
        const logContainer = document.getElementById('log-container');
        const logEntry = document.createElement('div');
        logEntry.className = 'log-entry';
        logEntry.textContent = `[${new Date().toLocaleTimeString()}] ${message}`;
        logContainer.appendChild(logEntry);

        // Auto-scroll to bottom
        logContainer.scrollTop = logContainer.scrollHeight;
    }

    hasLog(message) {
        const logContainer = document.getElementById('log-container');
        const logs = Array.from(logContainer.children);
        return logs.some(log => log.textContent.includes(message));
    }

    clearLogs() {
        const logContainer = document.getElementById('log-container');
        logContainer.innerHTML = '';
    }

    showError(title, message) {
        const currentSection = document.querySelector('.step.active');
        currentSection.classList.remove('active');
        document.getElementById('step-error').classList.add('active');

        document.getElementById('error-text').textContent = title;
        document.getElementById('error-details').textContent = message;

        // Scroll to top
        window.scrollTo(0, 0);
    }

    reset() {
        // Reset state
        this.currentStep = 1;
        this.selectedServices.clear();
        this.selectedModels.clear();
        this.buildId = null;
        this.buildStartTime = null;
        this.stopStatusPolling();

        // Reset UI
        document.querySelectorAll('input[type="checkbox"]').forEach(cb => {
            if (!cb.disabled) {
                cb.checked = false;
            }
        });

        document.getElementById('email').value = '';
        document.getElementById('iso-name').value = 'ubuntu-24.04.3-homelab-custom';
        document.getElementById('gpu-enabled').checked = false;

        this.updateSummary();

        // Show first step
        document.querySelectorAll('.step').forEach(step => step.classList.remove('active'));
        document.getElementById('step-services').classList.add('active');

        // Scroll to top
        window.scrollTo(0, 0);
    }
}

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    window.app = new HomeLabISOBuilder();
});
