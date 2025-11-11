// Build Management API Routes

const express = require('express');
const router = express.Router();
const logger = require('../lib/logger');
const buildOrchestrator = require('../lib/build-orchestrator');
const gcsManager = require('../lib/gcs-manager');

/**
 * POST /api/build
 * Start a new ISO build
 */
router.post('/', async (req, res) => {
    try {
        const buildConfig = {
            services: req.body.services || [],
            models: req.body.models || [],
            gpu_enabled: req.body.gpu_enabled || false,
            email: req.body.email,
            iso_name: req.body.iso_name || 'ubuntu-24.04.3-homelab-custom',
        };

        logger.info('New build request:', buildConfig);

        const result = await buildOrchestrator.startBuild(buildConfig);

        res.status(202).json(result);
    } catch (error) {
        logger.error('Error starting build:', error);
        res.status(400).json({ error: error.message });
    }
});

/**
 * GET /api/build/:buildId/status
 * Get build status
 */
router.get('/:buildId/status', (req, res) => {
    try {
        const { buildId } = req.params;

        const status = buildOrchestrator.getBuildStatus(buildId);

        if (!status) {
            return res.status(404).json({ error: 'Build not found' });
        }

        res.json(status);
    } catch (error) {
        logger.error('Error getting build status:', error);
        res.status(500).json({ error: 'Failed to get build status' });
    }
});

/**
 * GET /api/build/:buildId/download
 * Get download URL for completed ISO
 */
router.get('/:buildId/download', async (req, res) => {
    try {
        const { buildId } = req.params;

        const status = buildOrchestrator.getBuildStatus(buildId);

        if (!status) {
            return res.status(404).json({ error: 'Build not found' });
        }

        if (status.status !== 'complete') {
            return res.status(400).json({
                error: 'Build not complete',
                status: status.status,
            });
        }

        if (!status.iso_filename) {
            return res.status(500).json({ error: 'ISO filename not found' });
        }

        // Check if ISO exists
        const exists = await gcsManager.isoExists(status.iso_filename);
        if (!exists) {
            return res.status(404).json({ error: 'ISO file not found in storage' });
        }

        // Generate signed download URL
        const downloadUrl = await gcsManager.getSignedDownloadURL(status.iso_filename);

        // Get ISO metadata
        const metadata = await gcsManager.getISOMetadata(status.iso_filename);

        res.json({
            build_id: buildId,
            download_url: downloadUrl,
            iso_filename: status.iso_filename,
            iso_size: metadata.size,
            expires_in_seconds: 3600,
        });
    } catch (error) {
        logger.error('Error generating download URL:', error);
        res.status(500).json({ error: 'Failed to generate download URL' });
    }
});

/**
 * DELETE /api/build/:buildId
 * Cancel a running build
 */
router.delete('/:buildId', async (req, res) => {
    try {
        const { buildId } = req.params;

        const status = buildOrchestrator.getBuildStatus(buildId);

        if (!status) {
            return res.status(404).json({ error: 'Build not found' });
        }

        if (status.status === 'complete' || status.status === 'failed') {
            return res.status(400).json({
                error: 'Build already finished',
                status: status.status,
            });
        }

        // TODO: Implement build cancellation
        // This would involve stopping the VM and updating build status

        res.json({
            message: 'Build cancellation requested',
            build_id: buildId,
        });
    } catch (error) {
        logger.error('Error cancelling build:', error);
        res.status(500).json({ error: 'Failed to cancel build' });
    }
});

module.exports = router;
