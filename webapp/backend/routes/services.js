// Services and Models API Routes

const express = require('express');
const router = express.Router();
const config = require('../config/config');
const logger = require('../lib/logger');

/**
 * GET /api/services
 * Get available Docker services
 */
router.get('/services', (req, res) => {
    try {
        const services = Object.entries(config.services)
            .filter(([name, service]) => !service.hidden)
            .map(([name, service]) => ({
                name,
                display: service.display,
                description: service.description,
                category: service.category,
                size_mb: service.size_mb,
                dependencies: service.dependencies,
                required: service.required,
            }));

        res.json({
            services,
            categories: {
                ai: 'AI & Machine Learning',
                homelab: 'Homelab Services',
                infrastructure: 'Infrastructure',
            },
        });
    } catch (error) {
        logger.error('Error fetching services:', error);
        res.status(500).json({ error: 'Failed to fetch services' });
    }
});

/**
 * GET /api/models
 * Get available Ollama models
 */
router.get('/models', (req, res) => {
    try {
        const models = Object.entries(config.models).map(([name, model]) => ({
            name,
            display: model.display,
            description: model.description,
            size_gb: model.size_gb,
            size: `${model.size_gb}GB`,
        }));

        res.json({
            models,
        });
    } catch (error) {
        logger.error('Error fetching models:', error);
        res.status(500).json({ error: 'Failed to fetch models' });
    }
});

/**
 * GET /api/config
 * Get public configuration
 */
router.get('/config', (req, res) => {
    try {
        res.json({
            max_concurrent_builds: config.vm.maxConcurrentBuilds,
            max_services_per_build: config.build.maxServicesPerBuild,
            max_models_per_build: config.build.maxModelsPerBuild,
            max_iso_size_gb: config.build.maxISOSizeGB,
            iso_retention_days: config.gcs.isoRetentionDays,
            build_timeout_hours: config.vm.buildTimeout,
        });
    } catch (error) {
        logger.error('Error fetching config:', error);
        res.status(500).json({ error: 'Failed to fetch configuration' });
    }
});

module.exports = router;
