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
            this.addLog('Submitting build request...', 'progress');

            // Start build
            const response = await window.api.startBuild(buildConfig);
            this.buildId = response.build_id;
            this.buildStartTime = Date.now();

            // Update UI with build info
            document.getElementById('build-id').textContent = this.buildId;
            this.addLog(`Build ID: ${this.buildId}`, 'info');
            this.addLog(`Status: ${response.status}`, 'success');

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

    async showDownloadOption() {
        // Hide option cards
        document.querySelector('.option-cards').style.display = 'none';

        // Show download details
        document.getElementById('download-details').style.display = 'block';
    }

    async showFlashOption() {
        // Hide option cards
        document.querySelector('.option-cards').style.display = 'none';

        // Get download URL and update the flasher command
        try {
            const response = await window.api.getDownloadURL(this.buildId);
            const downloadUrl = response.download_url || response.redirect_url;

            if (downloadUrl) {
                const urlPlaceholder = document.getElementById('iso-url-placeholder');
                if (urlPlaceholder) {
                    urlPlaceholder.textContent = downloadUrl;
                }
            }
        } catch (error) {
            console.error('Failed to get download URL:', error);
        }

        // Show flash details
        document.getElementById('flash-details').style.display = 'block';
    }

    hideOptionDetails() {
        // Hide both option details
        document.getElementById('download-details').style.display = 'none';
        document.getElementById('flash-details').style.display = 'none';

        // Show option cards again
        document.querySelector('.option-cards').style.display = 'grid';
    }

    async copyFlasherCommand() {
        const command = document.getElementById('flasher-command').textContent;

        try {
            await navigator.clipboard.writeText(command);

            // Visual feedback
            const btn = event.target;
            const originalText = btn.textContent;
            btn.textContent = '✓';
            setTimeout(() => {
                btn.textContent = originalText;
            }, 2000);
        } catch (error) {
            console.error('Failed to copy command:', error);
            alert('Failed to copy command to clipboard. Please copy it manually.');
        }
    }

    updateProgress(percentage, stage) {
        // Update overall progress
        const overallProgress = document.getElementById('overall-progress');
        if (overallProgress) {
            overallProgress.textContent = `${percentage}%`;
        }

        // Update pipeline stage based on percentage and stage name
        this.updatePipelineStage(percentage, stage);

        // Update checklist based on stage
        this.updateChecklist(stage, percentage);
    }

    updatePipelineStage(percentage, stageName) {
        // Map stages to pipeline stages
        const stageMapping = {
            'queued': 0,
            'creating': 10,
            'downloading': 20,
            'building': 40,
            'uploading': 80,
            'complete': 100
        };

        // Determine which pipeline stage to highlight
        let currentStage = 'queued';
        if (percentage >= 80) currentStage = 'uploading';
        else if (percentage >= 40) currentStage = 'building';
        else if (percentage >= 20) currentStage = 'downloading';
        else if (percentage >= 10) currentStage = 'creating-vm';

        if (percentage === 100) currentStage = 'complete';

        // Update pipeline stages
        const stages = document.querySelectorAll('.pipeline-stage');
        stages.forEach(stage => {
            const stageData = stage.getAttribute('data-stage');
            const statusEl = stage.querySelector('.stage-status');

            // Determine status based on progress
            if (stageData === currentStage) {
                stage.classList.add('active');
                stage.classList.remove('completed');
                statusEl.textContent = 'in progress';
            } else if (this.isStageCompleted(stageData, currentStage)) {
                stage.classList.remove('active');
                stage.classList.add('completed');
                statusEl.textContent = 'completed';
            } else {
                stage.classList.remove('active', 'completed');
                statusEl.textContent = 'pending';
            }
        });

        // Update connectors
        const connectors = document.querySelectorAll('.pipeline-connector');
        connectors.forEach((connector, index) => {
            if (index < this.getStageIndex(currentStage)) {
                connector.classList.add('completed');
            } else {
                connector.classList.remove('completed');
            }
        });
    }

    isStageCompleted(stage, currentStage) {
        const stageOrder = ['queued', 'creating-vm', 'downloading', 'building', 'uploading', 'complete'];
        return stageOrder.indexOf(stage) < stageOrder.indexOf(currentStage);
    }

    getStageIndex(stageName) {
        const stageOrder = ['queued', 'creating-vm', 'downloading', 'building', 'uploading', 'complete'];
        return stageOrder.indexOf(stageName);
    }

    updateChecklist(stageName, percentage) {
        // Map stage names and messages to checklist tasks
        const taskMapping = {
            'vm': 'vm-creation',
            'creating': 'vm-creation',
            'cache': 'cache-check',
            'docker': 'docker-images',
            'image': 'docker-images',
            'ollama': 'ollama-models',
            'model': 'ollama-models',
            'building': 'iso-build',
            'uploading': 'iso-upload',
            'populating': 'cache-populate'
        };

        const lowerStage = stageName.toLowerCase();

        // Determine which task is active
        for (const [key, taskId] of Object.entries(taskMapping)) {
            if (lowerStage.includes(key)) {
                this.updateChecklistItem(taskId, 'in-progress', percentage);

                // Mark previous tasks as complete
                this.markPreviousTasksComplete(taskId);
                break;
            }
        }
    }

    updateChecklistItem(taskId, status, percentage = null) {
        const item = document.querySelector(`.checklist-item[data-task="${taskId}"]`);
        if (!item) return;

        const checkbox = item.querySelector('.task-checkbox');
        const progressEl = item.querySelector('.task-progress');

        item.classList.remove('pending', 'in-progress', 'completed');

        if (status === 'completed') {
            item.classList.add('completed');
            checkbox.textContent = '☑';
            progressEl.textContent = '';
        } else if (status === 'in-progress') {
            item.classList.add('in-progress');
            checkbox.textContent = '⏳';
            if (percentage !== null) {
                // Calculate sub-task percentage (within the stage range)
                const taskPercentage = this.calculateTaskPercentage(taskId, percentage);
                progressEl.textContent = `${taskPercentage}%`;
            }
        } else {
            item.classList.add('pending');
            checkbox.textContent = '☐';
            progressEl.textContent = '';
        }
    }

    calculateTaskPercentage(taskId, overallPercentage) {
        // Map tasks to their percentage ranges
        const taskRanges = {
            'vm-creation': [0, 10],
            'cache-check': [10, 20],
            'docker-images': [20, 40],
            'ollama-models': [40, 60],
            'iso-build': [60, 80],
            'iso-upload': [80, 95],
            'cache-populate': [95, 100]
        };

        const range = taskRanges[taskId] || [0, 100];
        const [start, end] = range;

        if (overallPercentage < start) return 0;
        if (overallPercentage > end) return 100;

        // Calculate percentage within this task's range
        const taskProgress = ((overallPercentage - start) / (end - start)) * 100;
        return Math.round(taskProgress);
    }

    markPreviousTasksComplete(currentTaskId) {
        const taskOrder = ['vm-creation', 'cache-check', 'docker-images', 'ollama-models', 'iso-build', 'iso-upload', 'cache-populate'];
        const currentIndex = taskOrder.indexOf(currentTaskId);

        for (let i = 0; i < currentIndex; i++) {
            this.updateChecklistItem(taskOrder[i], 'completed');
        }
    }

    detectLogType(message) {
        const lowerMessage = message.toLowerCase();

        // Error patterns
        if (lowerMessage.includes('error') || lowerMessage.includes('failed') ||
            lowerMessage.includes('failure') || lowerMessage.startsWith('✗')) {
            return 'error';
        }

        // Success patterns
        if (lowerMessage.includes('success') || lowerMessage.includes('completed') ||
            lowerMessage.includes('ready') || lowerMessage.startsWith('✓') ||
            lowerMessage.includes('uploaded successfully')) {
            return 'success';
        }

        // Warning patterns
        if (lowerMessage.includes('warning') || lowerMessage.includes('retry') ||
            lowerMessage.includes('⚠')) {
            return 'warning';
        }

        // Progress patterns
        if (lowerMessage.includes('downloading') || lowerMessage.includes('building') ||
            lowerMessage.includes('uploading') || lowerMessage.includes('creating') ||
            lowerMessage.includes('installing') || lowerMessage.includes('progress') ||
            lowerMessage.includes('%')) {
            return 'progress';
        }

        return 'info';
    }

    addLog(message, type = null) {
        // Auto-detect type if not specified
        if (!type) {
            type = this.detectLogType(message);
        }

        const logContainer = document.getElementById('log-container');
        const logEntry = document.createElement('div');
        logEntry.className = `log-entry log-${type}`;

        // Format timestamp with milliseconds for precision
        const now = new Date();
        const timestamp = now.toLocaleTimeString('en-US', {
            hour12: false,
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit'
        }) + '.' + String(now.getMilliseconds()).padStart(3, '0');

        // Format log entry with type indicator
        const typeIndicator = {
            'info': 'ℹ️',
            'success': '✅',
            'warning': '⚠️',
            'error': '❌',
            'progress': '⏳'
        }[type] || 'ℹ️';

        logEntry.textContent = `[${timestamp}] ${typeIndicator} ${message}`;
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

    async copyLogs() {
        const logContainer = document.getElementById('log-container');
        const logs = Array.from(logContainer.children);
        const logText = logs.map(log => log.textContent).join('\n');

        try {
            await navigator.clipboard.writeText(logText);

            // Visual feedback
            const copyBtn = document.getElementById('copy-logs-btn');
            const originalText = copyBtn.textContent;
            copyBtn.textContent = '✅ Copied!';
            copyBtn.disabled = true;

            setTimeout(() => {
                copyBtn.textContent = originalText;
                copyBtn.disabled = false;
            }, 2000);
        } catch (err) {
            console.error('Failed to copy logs:', err);
            alert('Failed to copy logs to clipboard. Please select and copy manually.');
        }
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
