// Homelab ISO Builder Backend Server

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const compression = require('compression');
const path = require('path');
const rateLimit = require('express-rate-limit');

const config = require('./config/config');
const logger = require('./lib/logger');
const requestLogger = require('./middleware/request-logger');

// Import routes
const buildRoutes = require('./routes/build');
const servicesRoutes = require('./routes/services');
const usbRoutes = require('./routes/usb');

// Initialize Express app
const app = express();

// Trust proxy (for Cloud Run / App Engine)
app.set('trust proxy', true);

// Middleware - SECURITY: Enable Content Security Policy
app.use(helmet({
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            scriptSrc: [
                "'self'",
                // Allow inline scripts for the frontend (needed for app.js)
                // In production, consider using nonces or hashes instead
                "'unsafe-inline'"
            ],
            styleSrc: [
                "'self'",
                "'unsafe-inline'"  // Allow inline styles for UI components
            ],
            imgSrc: [
                "'self'",
                "data:",  // Allow data: URIs for inline images
                "https:"  // Allow HTTPS images (for icons, logos)
            ],
            connectSrc: ["'self'"],  // Only allow API calls to same origin
            fontSrc: ["'self'"],
            objectSrc: ["'none'"],  // Disable plugins (Flash, etc.)
            mediaSrc: ["'self'"],
            frameSrc: ["'none'"],  // Prevent embedding in iframes
            formAction: ["'self'"],  // Forms can only submit to same origin
            frameAncestors: ["'none'"],  // Prevent clickjacking (X-Frame-Options)
            baseUri: ["'self'"],  // Prevent base tag hijacking
            upgradeInsecureRequests: [],  // Upgrade HTTP to HTTPS
        },
    },
    hsts: {
        maxAge: 31536000,  // 1 year
        includeSubDomains: true,
        preload: true,
    },
    noSniff: true,  // Prevent MIME type sniffing
    xssFilter: true,  // Enable XSS filter
    referrerPolicy: { policy: 'strict-origin-when-cross-origin' },
}));

app.use(cors({
    origin: config.security.corsOrigins,
    credentials: true,
}));

app.use(compression());

// Security: Add request size limits to prevent memory exhaustion attacks
// Build configs are small (<100KB), so 1MB is generous
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

// Request logging with context tracking
app.use(requestLogger);

// Logging
if (config.env === 'development') {
    app.use(morgan('dev'));
} else {
    app.use(morgan('combined', {
        stream: {
            write: (message) => logger.info(message.trim()),
        },
    }));
}

// Rate limiting
if (config.rateLimit.enabled) {
    logger.info('Rate limiting enabled', {
        max: config.rateLimit.max,
        windowMinutes: config.rateLimit.windowMs / 60000
    });

    const limiter = rateLimit({
        windowMs: config.rateLimit.windowMs,
        max: config.rateLimit.max,
        standardHeaders: true,
        legacyHeaders: false,
        // Trust proxy for Cloud Run/App Engine - disable validation warning
        validate: { trustProxy: false },
        // Skip rate limiting for health checks and in development if bypass header is present
        skip: (req) => {
            // Always skip health checks
            if (req.path === '/health') {
                return true;
            }

            // In development, allow bypassing rate limit with special header
            if (config.env === 'development' && req.headers['x-bypass-rate-limit'] === 'true') {
                logger.debug('Rate limit bypassed in development', { ip: req.ip, path: req.path });
                return true;
            }

            return false;
        },
        // Key generator to ensure proper IP tracking
        keyGenerator: (req) => {
            // Use X-Forwarded-For header if trust proxy is enabled, otherwise use req.ip
            const ip = req.ip || req.connection.remoteAddress;
            logger.debug('Rate limit key generated', {
                ip,
                path: req.path,
                headers: {
                    'x-forwarded-for': req.headers['x-forwarded-for'],
                    'x-real-ip': req.headers['x-real-ip']
                }
            });
            return ip;
        },
        handler: (req, res) => {
            const retryAfter = Math.ceil(config.rateLimit.windowMs / 1000);
            logger.warn('Rate limit exceeded', {
                ip: req.ip,
                path: req.path,
                requestId: req.requestId,
                maxRequests: config.rateLimit.max,
                windowMinutes: config.rateLimit.windowMs / 60000,
                retryAfterSeconds: retryAfter
            });
            res.status(429).json({
                error: 'Too many requests from this IP, please try again later.',
                retryAfter, // seconds
                maxRequests: config.rateLimit.max,
                windowMinutes: Math.ceil(config.rateLimit.windowMs / 60000)
            });
        },
    });

    app.use('/api/', limiter);
} else {
    logger.warn('Rate limiting is DISABLED - not recommended for production');
}

// Security: Rate limiting for static files (more lenient than API)
// Allows normal browsing while preventing abuse
if (config.rateLimit.enabled) {
    const staticLimiter = rateLimit({
        windowMs: config.rateLimit.windowMs, // Same window as API (15 minutes)
        max: config.rateLimit.max * 2, // Double the API limit for static files
        standardHeaders: true,
        legacyHeaders: false,
        // Trust proxy for Cloud Run/App Engine - disable validation warning
        validate: { trustProxy: false },
        handler: (req, res) => {
            logger.warn('Static file rate limit exceeded', {
                ip: req.ip,
                path: req.path,
                requestId: req.requestId
            });
            res.status(429).json({
                error: 'Too many requests from this IP, please try again later.',
                retryAfter: Math.ceil(config.rateLimit.windowMs / 1000), // seconds
            });
        },
    });

    // Apply static limiter before serving files
    app.use(staticLimiter);
}

// CSRF Protection for state-changing operations
// Security: Require custom header for POST/PUT/DELETE to prevent CSRF attacks
// Browsers cannot set custom headers from simple forms/links, only via JavaScript
const csrfProtection = (req, res, next) => {
    const stateChangingMethods = ['POST', 'PUT', 'DELETE', 'PATCH'];

    if (stateChangingMethods.includes(req.method)) {
        const csrfHeader = req.get('X-Requested-With');

        if (!csrfHeader || csrfHeader !== 'XMLHttpRequest') {
            logger.warn('CSRF protection triggered - missing or invalid X-Requested-With header', {
                ip: req.ip,
                method: req.method,
                path: req.path,
                requestId: req.requestId
            });
            return res.status(403).json({
                error: 'Forbidden: Missing required header for state-changing operations',
            });
        }
    }

    next();
};

app.use('/api/', csrfProtection);

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        environment: config.env,
    });
});

// API routes
app.use('/api/build', buildRoutes);
app.use('/api/usb', usbRoutes);
app.use('/api', servicesRoutes);

// Serve static frontend files (rate limiting applied earlier if enabled)
app.use(express.static(path.join(__dirname, '../frontend')));

// Catch-all route for SPA (redirect to index.html)
app.get('*', (req, res) => {
    if (!req.path.startsWith('/api/')) {
        res.sendFile(path.join(__dirname, '../frontend/index.html'));
    } else {
        res.status(404).json({ error: 'API endpoint not found' });
    }
});

// Error handling middleware
app.use((err, req, res, next) => {
    // Security: Always log full error details internally (including stack trace)
    logger.error('Unhandled error:', err);

    const statusCode = err.statusCode || 500;

    // Security: In production, sanitize error messages to prevent information disclosure
    let message;
    if (config.env === 'production') {
        // For 5xx errors, use generic message to avoid leaking internal details
        if (statusCode >= 500) {
            message = 'Internal server error';
        } else {
            // For 4xx errors, show the actual message (usually safe validation errors)
            message = err.message || 'Bad request';
        }
    } else {
        // In development, show full error details
        message = err.message || 'Internal server error';
    }

    res.status(statusCode).json({
        error: message,
        // Security: Only include stack traces in development mode
        ...(config.env === 'development' && { stack: err.stack }),
    });
});

// Start server
const PORT = config.port;

const server = app.listen(PORT, () => {
    logger.info(`Homelab ISO Builder server started`);
    logger.info(`Environment: ${config.env}`);
    logger.info(`Port: ${PORT}`);
    logger.info(`GCP Project: ${config.gcp.projectId || 'Not configured'}`);
    logger.info(`Artifacts Bucket: ${config.gcs.artifactsBucket}`);
    logger.info(`Downloads Bucket: ${config.gcs.downloadsBucket}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
    logger.info('SIGTERM signal received: closing HTTP server');
    server.close(() => {
        logger.info('HTTP server closed');
        process.exit(0);
    });
});

process.on('SIGINT', () => {
    logger.info('SIGINT signal received: closing HTTP server');
    server.close(() => {
        logger.info('HTTP server closed');
        process.exit(0);
    });
});

module.exports = app;
