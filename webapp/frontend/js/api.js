// API Client for Homelab ISO Builder

class APIClient {
    constructor(baseURL = '') {
        this.baseURL = baseURL || window.location.origin;
        this.apiBase = `${this.baseURL}/api`;
    }

    /**
     * Generic HTTP request method
     */
    async request(endpoint, options = {}) {
        const url = `${this.apiBase}${endpoint}`;
        const defaultOptions = {
            headers: {
                'Content-Type': 'application/json',
            },
        };

        const config = { ...defaultOptions, ...options };

        try {
            const response = await fetch(url, config);

            // Check Content-Type to determine how to parse response
            const contentType = response.headers.get('content-type');
            let data;

            if (contentType && contentType.includes('application/json')) {
                data = await response.json();
            } else {
                // Handle plain text responses (like rate limit errors)
                const text = await response.text();
                data = { error: text, message: text };
            }

            if (!response.ok) {
                throw new Error(data.error || data.message || `HTTP ${response.status}: ${response.statusText}`);
            }

            return data;
        } catch (error) {
            // If error is from JSON parsing, provide better message
            if (error instanceof SyntaxError) {
                console.error('Failed to parse API response:', error);
                throw new Error('Invalid response from server. Please try again.');
            }
            console.error('API request failed:', error);
            throw error;
        }
    }

    /**
     * GET request
     */
    async get(endpoint) {
        return this.request(endpoint, { method: 'GET' });
    }

    /**
     * POST request
     */
    async post(endpoint, data) {
        return this.request(endpoint, {
            method: 'POST',
            body: JSON.stringify(data),
        });
    }

    /**
     * Get available services
     */
    async getServices() {
        return this.get('/services');
    }

    /**
     * Get available AI models
     */
    async getModels() {
        return this.get('/models');
    }

    /**
     * Start a new ISO build
     * @param {Object} config - Build configuration
     * @param {string[]} config.services - Selected service names
     * @param {string[]} config.models - Selected model names
     * @param {boolean} config.gpu_enabled - Enable GPU support
     * @param {string} config.email - Optional email for notifications
     * @param {string} config.iso_name - Custom ISO name
     */
    async startBuild(config) {
        return this.post('/build', config);
    }

    /**
     * Get build status
     * @param {string} buildId - Build ID
     */
    async getBuildStatus(buildId) {
        return this.get(`/build/${buildId}/status`);
    }

    /**
     * Get download URL for completed ISO
     * @param {string} buildId - Build ID
     */
    async getDownloadURL(buildId) {
        return this.get(`/build/${buildId}/download`);
    }

    /**
     * Poll build status until completion
     * @param {string} buildId - Build ID
     * @param {Function} onProgress - Callback for progress updates
     * @param {number} interval - Polling interval in milliseconds
     */
    async pollBuildStatus(buildId, onProgress, interval = 5000) {
        return new Promise((resolve, reject) => {
            const poll = async () => {
                try {
                    const status = await this.getBuildStatus(buildId);

                    // Call progress callback
                    if (onProgress) {
                        onProgress(status);
                    }

                    // Check if build is complete
                    if (status.status === 'complete') {
                        resolve(status);
                        return;
                    }

                    // Check if build failed
                    if (status.status === 'failed' || status.status === 'error') {
                        reject(new Error(status.error || 'Build failed'));
                        return;
                    }

                    // Continue polling
                    setTimeout(poll, interval);
                } catch (error) {
                    reject(error);
                }
            };

            // Start polling
            poll();
        });
    }

    /**
     * Calculate estimated build time based on selected components
     * @param {number} serviceCount - Number of services
     * @param {number} modelCount - Number of models
     * @param {number} modelSizeGB - Total model size in GB
     */
    estimateBuildTime(serviceCount, modelCount, modelSizeGB) {
        // Base time: 30 minutes for Ubuntu ISO and infrastructure
        let minutes = 30;

        // Add time per service (avg 2 minutes per service)
        minutes += serviceCount * 2;

        // Add time per model (5 minutes base + 1 minute per GB)
        if (modelCount > 0) {
            minutes += modelCount * 5;
            minutes += modelSizeGB * 1;
        }

        // ISO creation time: ~15 minutes
        minutes += 15;

        return Math.ceil(minutes);
    }

    /**
     * Calculate estimated ISO size
     * @param {number} serviceCount - Number of services
     * @param {number} serviceSizeGB - Total service size in GB
     * @param {number} modelSizeGB - Total model size in GB
     */
    estimateISOSize(serviceCount, serviceSizeGB, modelSizeGB) {
        // Base Ubuntu Server ISO: ~2.5 GB
        let sizeGB = 2.5;

        // Add service sizes
        sizeGB += serviceSizeGB;

        // Add model sizes
        sizeGB += modelSizeGB;

        // Add overhead (10%)
        sizeGB *= 1.1;

        return Math.ceil(sizeGB * 10) / 10; // Round to 1 decimal
    }

    /**
     * Format bytes to human-readable size
     */
    formatBytes(bytes) {
        if (bytes === 0) return '0 B';

        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));

        return `${(bytes / Math.pow(k, i)).toFixed(2)} ${sizes[i]}`;
    }

    /**
     * Format duration in seconds to human-readable time
     */
    formatDuration(seconds) {
        const hours = Math.floor(seconds / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);

        if (hours > 0) {
            return `${hours}h ${minutes}m`;
        }
        return `${minutes}m`;
    }

    /**
     * Parse model size string (e.g., "4.7GB") to bytes
     */
    parseModelSize(sizeString) {
        const match = sizeString.match(/^([\d.]+)\s*(GB|MB|KB)$/i);
        if (!match) return 0;

        const value = parseFloat(match[1]);
        const unit = match[2].toUpperCase();

        const multipliers = {
            'KB': 1024,
            'MB': 1024 * 1024,
            'GB': 1024 * 1024 * 1024,
        };

        return value * (multipliers[unit] || 0);
    }
}

// Export API client
window.api = new APIClient();
