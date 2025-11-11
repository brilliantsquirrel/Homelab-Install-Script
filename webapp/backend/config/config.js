// Configuration for Homelab ISO Builder Backend

require('dotenv').config();

module.exports = {
    // Server configuration
    port: process.env.PORT || 8080,
    env: process.env.NODE_ENV || 'development',

    // Google Cloud Platform
    gcp: {
        projectId: process.env.GCP_PROJECT_ID || '',
        zone: process.env.GCP_ZONE || 'us-west1-a',
        region: process.env.GCP_REGION || 'us-west1',
    },

    // Google Cloud Storage
    gcs: {
        artifactsBucket: process.env.GCS_ARTIFACTS_BUCKET || 'homelab-iso-artifacts',
        downloadsBucket: process.env.GCS_DOWNLOADS_BUCKET || 'homelab-iso-downloads',
        signedUrlExpiration: parseInt(process.env.GCS_SIGNED_URL_EXPIRATION) || 3600, // 1 hour
        isoRetentionDays: parseInt(process.env.ISO_RETENTION_DAYS) || 7,
    },

    // VM configuration for ISO builds
    vm: {
        namePrefix: 'iso-build',
        machineType: process.env.VM_MACHINE_TYPE || 'n2-standard-16',
        bootDiskSize: process.env.VM_BOOT_DISK_SIZE || '500',
        localSsdCount: parseInt(process.env.VM_LOCAL_SSD_COUNT) || 2,
        imageFamily: 'ubuntu-2204-lts',
        imageProject: 'ubuntu-os-cloud',
        maxConcurrentBuilds: parseInt(process.env.MAX_CONCURRENT_BUILDS) || 3,
        buildTimeout: parseInt(process.env.BUILD_TIMEOUT_HOURS) || 4,
        autoCleanup: process.env.VM_AUTO_CLEANUP !== 'false',
    },

    // Build configuration
    build: {
        maxServicesPerBuild: parseInt(process.env.MAX_SERVICES_PER_BUILD) || 50,
        maxModelsPerBuild: parseInt(process.env.MAX_MODELS_PER_BUILD) || 10,
        maxISOSizeGB: parseInt(process.env.MAX_ISO_SIZE_GB) || 150,
        pollIntervalMs: parseInt(process.env.POLL_INTERVAL_MS) || 10000,
    },

    // Rate limiting
    rateLimit: {
        enabled: process.env.RATE_LIMIT_ENABLED !== 'false', // Can disable with RATE_LIMIT_ENABLED=false
        windowMs: 15 * 60 * 1000, // 15 minutes
        max: (() => {
            // Use environment variable if set
            if (process.env.RATE_LIMIT_MAX) {
                return parseInt(process.env.RATE_LIMIT_MAX);
            }
            // Otherwise, use very permissive defaults to avoid blocking users
            // These can be tightened once the app is stable
            return process.env.NODE_ENV === 'production' ? 500 : 1000;
        })(),
        buildsPerUserPerDay: parseInt(process.env.BUILDS_PER_USER_PER_DAY) || 10,
    },

    // Security
    security: {
        apiSecretKey: (() => {
            const key = process.env.API_SECRET_KEY;
            if (!key || key === 'change-me-in-production') {
                throw new Error(
                    'SECURITY ERROR: API_SECRET_KEY environment variable must be set to a secure random value. ' +
                    'Generate one with: openssl rand -hex 32'
                );
            }
            if (key.length < 32) {
                throw new Error(
                    'SECURITY ERROR: API_SECRET_KEY must be at least 32 characters long. ' +
                    'Generate one with: openssl rand -hex 32'
                );
            }
            return key;
        })(),
        corsOrigins: (() => {
            const origins = process.env.CORS_ORIGINS ? process.env.CORS_ORIGINS.split(',') : null;

            // For Cloud Run/App Engine, if CORS_ORIGINS is not set, allow all origins
            // This is safe because the frontend is served from the same origin as the API
            if (!origins && process.env.K_SERVICE) {
                return ['*']; // Cloud Run - frontend served from same origin
            }

            if (!origins || origins.includes('*')) {
                if (process.env.NODE_ENV === 'production') {
                    throw new Error(
                        'SECURITY ERROR: CORS_ORIGINS must be explicitly set in production (no wildcards). ' +
                        'Example: CORS_ORIGINS=https://example.com,https://app.example.com'
                    );
                }
                // Allow wildcard in development only
                return ['*'];
            }
            return origins;
        })(),
    },

    // Email notifications (optional)
    email: {
        enabled: process.env.EMAIL_ENABLED === 'true',
        from: process.env.EMAIL_FROM || 'noreply@homelab-iso-builder.com',
        sendgridApiKey: process.env.SENDGRID_API_KEY || '',
    },

    // Logging
    logging: {
        level: process.env.LOG_LEVEL || 'info',
        format: process.env.LOG_FORMAT || 'json',
    },

    // Available services (from docker-compose.yml)
    services: {
        // AI & Machine Learning
        'ollama': {
            display: 'Ollama (LLM Runtime)',
            description: 'Local LLM runtime with GPU support',
            category: 'ai',
            size_mb: 2048,
            dependencies: [],
            required: false,
        },
        'openwebui': {
            display: 'OpenWebUI',
            description: 'Web interface for Ollama',
            category: 'ai',
            size_mb: 512,
            dependencies: ['ollama'],
            required: false,
        },
        'langflow': {
            display: 'LangFlow',
            description: 'Visual AI workflow builder',
            category: 'ai',
            size_mb: 1536,
            dependencies: ['ollama'],
            required: false,
        },
        'langgraph': {
            display: 'LangGraph',
            description: 'Stateful agent workflow engine',
            category: 'ai',
            size_mb: 819,
            dependencies: ['ollama', 'langgraph-redis', 'langgraph-db'],
            required: false,
        },
        'langgraph-redis': {
            display: 'LangGraph Redis',
            description: 'Redis for LangGraph',
            category: 'infrastructure',
            size_mb: 51,
            dependencies: [],
            required: false,
            hidden: true,
        },
        'langgraph-db': {
            display: 'LangGraph Database',
            description: 'PostgreSQL for LangGraph',
            category: 'infrastructure',
            size_mb: 102,
            dependencies: [],
            required: false,
            hidden: true,
        },
        'qdrant': {
            display: 'Qdrant',
            description: 'Vector database for embeddings',
            category: 'ai',
            size_mb: 307,
            dependencies: [],
            required: false,
        },
        'n8n': {
            display: 'n8n',
            description: 'Workflow automation platform',
            category: 'ai',
            size_mb: 614,
            dependencies: ['ollama'],
            required: false,
        },
        // Homelab Services
        'nextcloud': {
            display: 'Nextcloud',
            description: 'File storage & collaboration',
            category: 'homelab',
            size_mb: 1229,
            dependencies: ['nextcloud-db', 'nextcloud-redis'],
            required: false,
        },
        'nextcloud-db': {
            display: 'Nextcloud Database',
            description: 'PostgreSQL for Nextcloud',
            category: 'infrastructure',
            size_mb: 102,
            dependencies: [],
            required: false,
            hidden: true,
        },
        'nextcloud-redis': {
            display: 'Nextcloud Redis',
            description: 'Redis for Nextcloud',
            category: 'infrastructure',
            size_mb: 51,
            dependencies: [],
            required: false,
            hidden: true,
        },
        'plex': {
            display: 'Plex',
            description: 'Media server with transcoding',
            category: 'homelab',
            size_mb: 819,
            dependencies: [],
            required: false,
        },
        'pihole': {
            display: 'Pi-hole',
            description: 'Network-wide ad blocking',
            category: 'homelab',
            size_mb: 205,
            dependencies: [],
            required: false,
        },
        'homarr': {
            display: 'Homarr',
            description: 'Homelab dashboard',
            category: 'homelab',
            size_mb: 154,
            dependencies: [],
            required: false,
        },
        'hoarder': {
            display: 'Hoarder',
            description: 'Bookmark manager',
            category: 'homelab',
            size_mb: 102,
            dependencies: [],
            required: false,
        },
        // Infrastructure (required)
        'nginx': {
            display: 'Nginx (Required)',
            description: 'Reverse proxy with SSL',
            category: 'infrastructure',
            size_mb: 51,
            dependencies: [],
            required: true,
        },
        'portainer': {
            display: 'Portainer',
            description: 'Container management UI',
            category: 'infrastructure',
            size_mb: 307,
            dependencies: ['docker-socket-proxy'],
            required: false,
        },
        'docker-socket-proxy': {
            display: 'Docker Socket Proxy',
            description: 'Security layer for Docker API',
            category: 'infrastructure',
            size_mb: 51,
            dependencies: [],
            required: false,
            hidden: true,
        },
    },

    // Available Ollama models
    models: {
        'qwen3:8b': {
            display: 'Qwen3 8B',
            description: 'Fast general-purpose model (8B parameters)',
            size_gb: 4.7,
        },
        'qwen3-coder:30b': {
            display: 'Qwen3 Coder 30B',
            description: 'Code-specialized model (30B parameters)',
            size_gb: 17.0,
        },
        'qwen3-vl:8b': {
            display: 'Qwen3 VL 8B',
            description: 'Vision-language multimodal model',
            size_gb: 5.5,
        },
        'gpt-oss:20b': {
            display: 'GPT-OSS 20B',
            description: 'Open-source GPT-style model (20B parameters)',
            size_gb: 12.0,
        },
    },
};
