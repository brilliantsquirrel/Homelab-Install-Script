// Winston logger configuration

const winston = require('winston');
const config = require('../config/config');

const logger = winston.createLogger({
    level: config.logging.level,
    format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.errors({ stack: true }),
        config.logging.format === 'json'
            ? winston.format.json()
            : winston.format.simple()
    ),
    defaultMeta: { service: 'homelab-iso-builder' },
    transports: [
        // Console output
        new winston.transports.Console({
            format: winston.format.combine(
                winston.format.colorize(),
                winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
                winston.format.printf(({ timestamp, level, message, ...meta }) => {
                    let msg = `${timestamp} [${level}]: ${message}`;
                    if (Object.keys(meta).length > 0) {
                        msg += ` ${JSON.stringify(meta)}`;
                    }
                    return msg;
                })
            ),
        }),
    ],
});

// If in production, also log to file
if (config.env === 'production') {
    logger.add(new winston.transports.File({
        filename: 'error.log',
        level: 'error',
    }));
    logger.add(new winston.transports.File({
        filename: 'combined.log',
    }));
}

module.exports = logger;
