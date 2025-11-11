// Request logging middleware with performance tracking

const logger = require('../lib/logger');

/**
 * Middleware to log all HTTP requests with context and performance metrics
 */
const requestLogger = (req, res, next) => {
    // Generate unique request ID
    const requestId = logger.requestId();
    req.requestId = requestId;

    // Create request-scoped logger
    req.logger = logger.withContext({ requestId });

    // Track start time
    const startTime = Date.now();

    // Log incoming request
    req.logger.info('Incoming request', {
        method: req.method,
        path: req.path,
        query: req.query,
        ip: req.ip,
        userAgent: req.get('user-agent')
    });

    // Capture the original res.json to log responses
    const originalJson = res.json.bind(res);
    res.json = function(body) {
        const duration = Date.now() - startTime;

        // Log response
        req.logger.info('Response sent', {
            method: req.method,
            path: req.path,
            statusCode: res.statusCode,
            duration: `${duration}ms`
        });

        // Log performance if slow
        if (duration > 1000) {
            req.logger.warn('Slow request detected', {
                method: req.method,
                path: req.path,
                duration: `${duration}ms`
            });
        }

        return originalJson(body);
    };

    // Log when response finishes
    res.on('finish', () => {
        const duration = Date.now() - startTime;

        if (res.statusCode >= 400) {
            req.logger.error('Request failed', {
                method: req.method,
                path: req.path,
                statusCode: res.statusCode,
                duration: `${duration}ms`
            });
        }
    });

    next();
};

module.exports = requestLogger;
