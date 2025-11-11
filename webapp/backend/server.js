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

// Initialize Express app
const app = express();

// Trust proxy (for Cloud Run / App Engine)
app.set('trust proxy', true);

// Middleware
app.use(helmet({
    contentSecurityPolicy: false, // Allow inline scripts for frontend
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
const limiter = rateLimit({
    windowMs: config.rateLimit.windowMs,
    max: config.rateLimit.max,
    standardHeaders: true,
    legacyHeaders: false,
    handler: (req, res) => {
        logger.warn('Rate limit exceeded', {
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

app.use('/api/', limiter);

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
app.use('/api', servicesRoutes);

// Serve static frontend files
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
    logger.error('Unhandled error:', err);

    const statusCode = err.statusCode || 500;
    const message = err.message || 'Internal server error';

    res.status(statusCode).json({
        error: message,
        ...(config.env === 'development' && { stack: err.stack }),
    });
});

// Start server
const PORT = config.port;

app.listen(PORT, () => {
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
    app.close(() => {
        logger.info('HTTP server closed');
        process.exit(0);
    });
});

process.on('SIGINT', () => {
    logger.info('SIGINT signal received: closing HTTP server');
    process.exit(0);
});

module.exports = app;
