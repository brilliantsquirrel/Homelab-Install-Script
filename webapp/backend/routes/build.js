// Build Management API Routes

const express = require('express');
const router = express.Router();
const rateLimit = require('express-rate-limit');
const logger = require('../lib/logger');
const buildOrchestrator = require('../lib/build-orchestrator');
const gcsManager = require('../lib/gcs-manager');

// SECURITY: Strict rate limiting for build creation to prevent financial DoS
// Each build costs ~$8 (VM + compute + storage + egress)
// Without rate limiting, an attacker could create 40 builds/hour = $320/hour
const buildRateLimiter = rateLimit({
    windowMs: 60 * 60 * 1000,  // 1 hour window
    max: 3,                     // Maximum 3 builds per hour per IP
    skipSuccessfulRequests: false,
    skipFailedRequests: false,  // Count failed attempts to prevent enumeration
    message: {
        error: 'Build rate limit exceeded. Maximum 3 builds per hour.',
        retryAfter: '1 hour'
    },
    standardHeaders: true,      // Return rate limit info in RateLimit-* headers
    legacyHeaders: false,       // Disable X-RateLimit-* headers
    keyGenerator: (req) => {
        // Use IP address as key (can be enhanced with user authentication later)
        return req.ip || req.connection.remoteAddress;
    },
    handler: (req, res) => {
        logger.warn('Build rate limit exceeded', {
            ip: req.ip,
            path: req.path,
            headers: {
                'user-agent': req.get('user-agent'),
                'x-forwarded-for': req.get('x-forwarded-for')
            }
        });

        res.status(429).json({
            error: 'Build rate limit exceeded. Maximum 3 builds per hour per IP address.',
            retryAfter: 3600,  // seconds
            currentTime: new Date().toISOString()
        });
    }
});

// In-memory tracker for per-IP 24-hour build limits (additional layer)
// This prevents circumventing hourly limits by spacing builds exactly 1 hour apart
const dailyBuildTracker = new Map();

// Cleanup old entries every hour to prevent memory leaks
setInterval(() => {
    const oneDayAgo = Date.now() - (24 * 60 * 60 * 1000);
    for (const [ip, builds] of dailyBuildTracker.entries()) {
        const recentBuilds = builds.filter(timestamp => timestamp > oneDayAgo);
        if (recentBuilds.length === 0) {
            dailyBuildTracker.delete(ip);
        } else {
            dailyBuildTracker.set(ip, recentBuilds);
        }
    }
}, 60 * 60 * 1000);  // Run every hour

const dailyBuildLimiter = (req, res, next) => {
    const ip = req.ip || req.connection.remoteAddress;
    const now = Date.now();
    const oneDayAgo = now - (24 * 60 * 60 * 1000);

    // Get builds for this IP in the last 24 hours
    const builds = dailyBuildTracker.get(ip) || [];
    const recentBuilds = builds.filter(timestamp => timestamp > oneDayAgo);

    // Enforce daily limit: 5 builds per 24 hours
    if (recentBuilds.length >= 5) {
        const oldestBuild = Math.min(...recentBuilds);
        const retryAfter = Math.ceil((oldestBuild + (24 * 60 * 60 * 1000) - now) / 1000);

        logger.warn('Daily build limit exceeded', {
            ip,
            buildsLast24Hours: recentBuilds.length,
            path: req.path
        });

        return res.status(429).json({
            error: 'Daily build limit exceeded. Maximum 5 builds per 24 hours.',
            retryAfter,
            buildsRemaining: 0,
            resetTime: new Date(oldestBuild + (24 * 60 * 60 * 1000)).toISOString()
        });
    }

    // Track this build attempt
    recentBuilds.push(now);
    dailyBuildTracker.set(ip, recentBuilds);

    // Add remaining builds info to response headers
    res.set('X-Builds-Remaining-24h', String(5 - recentBuilds.length));

    next();
};

/**
 * POST /api/build
 * Start a new ISO build
 *
 * Rate Limits:
 * - 3 builds per hour per IP
 * - 5 builds per 24 hours per IP
 */
router.post('/', buildRateLimiter, dailyBuildLimiter, async (req, res) => {
    try {
        // Validate input types before processing
        if (req.body.services !== undefined && !Array.isArray(req.body.services)) {
            return res.status(400).json({ error: 'services must be an array' });
        }

        if (req.body.models !== undefined && !Array.isArray(req.body.models)) {
            return res.status(400).json({ error: 'models must be an array' });
        }

        if (req.body.gpu_enabled !== undefined && typeof req.body.gpu_enabled !== 'boolean') {
            return res.status(400).json({ error: 'gpu_enabled must be a boolean' });
        }

        if (req.body.iso_name !== undefined && typeof req.body.iso_name !== 'string') {
            return res.status(400).json({ error: 'iso_name must be a string' });
        }

        if (req.body.email !== undefined && typeof req.body.email !== 'string') {
            return res.status(400).json({ error: 'email must be a string' });
        }

        // Security: Validate email if provided
        if (req.body.email !== undefined && req.body.email.trim() !== '') {
            const email = req.body.email.trim();

            // Security: Length validation (RFC 5321: max 254 chars)
            if (email.length > 254) {
                return res.status(400).json({ error: 'email too long. Maximum 254 characters allowed' });
            }

            // Security: Check for header injection patterns (newlines, carriage returns)
            if (/[\r\n]/.test(email)) {
                return res.status(400).json({ error: 'email contains prohibited characters' });
            }

            // Security: Check for dangerous characters
            if (/[;|&$`\\]/.test(email)) {
                return res.status(400).json({ error: 'email contains prohibited characters' });
            }

            // Security: Validate email format (RFC 5322 compliant)
            if (!/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(email)) {
                return res.status(400).json({ error: 'invalid email format' });
            }

            // Security: Validate local part and domain lengths (RFC 5321)
            const [localPart, domainPart] = email.split('@');
            if (localPart.length > 64 || domainPart.length > 253) {
                return res.status(400).json({ error: 'email local part (max 64 chars) or domain (max 253 chars) too long' });
            }
        }

        // Validate array elements are strings
        const services = req.body.services || [];
        const models = req.body.models || [];

        if (services.some(s => typeof s !== 'string' || s.trim() === '')) {
            return res.status(400).json({ error: 'All services must be non-empty strings' });
        }

        if (models.some(m => typeof m !== 'string' || m.trim() === '')) {
            return res.status(400).json({ error: 'All models must be non-empty strings' });
        }

        // Sanitize strings (trim whitespace)
        const buildConfig = {
            services: services.map(s => s.trim()),
            models: models.map(m => m.trim()),
            gpu_enabled: req.body.gpu_enabled || false,
            email: req.body.email ? req.body.email.trim() : undefined,
            iso_name: req.body.iso_name ? req.body.iso_name.trim() : 'ubuntu-24.04.3-homelab-custom',
        };

        // Sanitized config for logging (safe to log now)
        const sanitizedConfig = {
            ...buildConfig,
            email: buildConfig.email ? '***@***' : undefined,
        };
        logger.info('New build request:', sanitizedConfig);

        const result = await buildOrchestrator.startBuild(buildConfig);

        res.status(202).json(result);
    } catch (error) {
        logger.error('Error starting build:', error);
        res.status(400).json({ error: error.message });
    }
});

/**
 * GET /api/build/completed
 * List recent completed builds
 * NOTE: This must come BEFORE /:buildId routes to avoid route conflicts
 */
router.get('/completed', async (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 10;

        // List all ISOs from GCS downloads bucket
        const isos = await gcsManager.listISOs();

        // Extract build IDs from ISO filenames
        // Format: ubuntu-24.04.3-homelab-custom-{buildId}.iso
        const builds = [];

        for (const iso of isos.slice(0, limit)) {
            const match = iso.name.match(/ubuntu-.*-homelab-custom-([a-f0-9]+)\.iso$/);
            if (match) {
                const buildId = match[1];

                // Try to get build status from GCS
                const status = await buildOrchestrator.getBuildStatus(buildId);

                builds.push({
                    build_id: buildId,
                    iso_filename: iso.name,
                    iso_size: iso.size,
                    created: iso.created,
                    status: status ? status.status : 'complete',
                });
            }
        }

        res.json({
            builds: builds,
            total: builds.length,
        });
    } catch (error) {
        logger.error('Error listing completed builds:', error);
        res.status(500).json({ error: 'Failed to list completed builds' });
    }
});

/**
 * GET /api/build/:buildId/status
 * Get build status
 */
router.get('/:buildId/status', async (req, res) => {
    try {
        const { buildId } = req.params;

        const status = await buildOrchestrator.getBuildStatus(buildId);

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

        const status = await buildOrchestrator.getBuildStatus(buildId);

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
            expires_in_seconds: 18000, // 5 hours
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
