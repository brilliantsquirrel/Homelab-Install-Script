// Winston logger configuration with enhanced context tracking

const winston = require('winston');
const config = require('../config/config');
const { v4: uuidv4 } = require('uuid');

// Custom format for better readability
const customFormat = winston.format.printf(({ timestamp, level, message, requestId, buildId, component, ...meta }) => {
    let msg = `${timestamp} [${level}]`;

    // Add context identifiers (with bounds checking)
    if (requestId) msg += ` [req:${requestId.length >= 8 ? requestId.substring(0, 8) : requestId}]`;
    if (buildId) msg += ` [build:${buildId.length >= 8 ? buildId.substring(0, 8) : buildId}]`;
    if (component) msg += ` [${component}]`;

    msg += `: ${message}`;

    // Add metadata if present
    const metaKeys = Object.keys(meta).filter(k => k !== 'service' && k !== 'timestamp');
    if (metaKeys.length > 0) {
        const cleanMeta = {};
        metaKeys.forEach(k => cleanMeta[k] = meta[k]);
        msg += ` ${JSON.stringify(cleanMeta)}`;
    }

    return msg;
});

const logger = winston.createLogger({
    level: config.logging.level,
    format: winston.format.combine(
        winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss.SSS' }),
        winston.format.errors({ stack: true }),
        config.logging.format === 'json'
            ? winston.format.json()
            : customFormat
    ),
    defaultMeta: { service: 'homelab-iso-builder' },
    transports: [
        // Console output
        new winston.transports.Console({
            format: winston.format.combine(
                winston.format.colorize(),
                winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss.SSS' }),
                customFormat
            ),
        }),
    ],
});

// If in production, also log to file
if (config.env === 'production') {
    logger.add(new winston.transports.File({
        filename: 'logs/error.log',
        level: 'error',
        maxsize: 10485760, // 10MB
        maxFiles: 5,
    }));
    logger.add(new winston.transports.File({
        filename: 'logs/combined.log',
        maxsize: 10485760, // 10MB
        maxFiles: 10,
    }));
}

// Create child logger with context
logger.withContext = (context) => {
    return logger.child(context);
};

// Request logger - generates unique request ID
logger.requestId = () => {
    return uuidv4();
};

// Performance logging helper
logger.logPerformance = (operation, duration, metadata = {}) => {
    logger.info(`Performance: ${operation} took ${duration}ms`, {
        operation,
        duration,
        ...metadata
    });
};

// Error with context helper
logger.errorWithContext = (message, error, context = {}) => {
    logger.error(message, {
        error: error.message,
        stack: error.stack,
        ...context
    });
};

module.exports = logger;
