# Dockerfile for Homelab ISO Builder
# Deploy to Cloud Run or containerized environment

# Use Node.js 18 LTS
FROM node:18-slim

# Install Python for yaml parsing in iso-prepare-dynamic.sh
RUN apt-get update && apt-get install -y \
    python3 \
    python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy package files
COPY backend/package*.json ./

# Install dependencies
RUN npm ci --only=production

# Copy application code
COPY backend/ ./backend/
COPY frontend/ ./frontend/
COPY webapp/scripts/ ./webapp/scripts/

# Set environment variables
ENV NODE_ENV=production
ENV PORT=8080

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD node -e "require('http').get('http://localhost:8080/health', (res) => process.exit(res.statusCode === 200 ? 0 : 1))"

# Start server
CMD ["node", "backend/server.js"]
