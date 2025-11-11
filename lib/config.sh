#!/bin/bash

# Configuration Module - Central configuration for Homelab installation
# Usage: source lib/config.sh
# Provides: Configuration variables used across all installation scripts

# ========================================
# System Configuration
# ========================================

# SSH Configuration
: ${SSH_CONFIG:="/etc/ssh/sshd_config"}
: ${SSH_BACKUP_TIMESTAMP:="true"}  # Use unique timestamp for backups

# Docker Configuration
: ${DOCKER_STARTUP_WAIT:=10}  # Seconds to wait for Docker to be ready
: ${DOCKER_SOCKET_PROXY_IMAGE:="tecnativa/docker-socket-proxy:latest"}

# GPU Configuration
: ${GPU_TIMEOUT:=300}  # Timeout for GPU detection

# ========================================
# Installation Timeouts
# ========================================

# Model pull timeout (2 hours)
: ${MODEL_PULL_TIMEOUT:=7200}

# Service startup timeout
: ${SERVICE_STARTUP_TIMEOUT:=30}

# Database migration timeout
: ${DB_MIGRATION_TIMEOUT:=60}

# ========================================
# Ollama Configuration
# ========================================

# Models to pull during installation
declare -a OLLAMA_MODELS=(
    "gpt-oss:20b"
    "qwen3-vl:8b"
    "qwen3-coder:30b"
    "qwen3:8b"
)

# ========================================
# Database Configuration
# ========================================

# SQLite database directory (relative to user home)
: ${DATABASE_DIR:="$HOME/.local/share/homelab/databases"}

# SQLite backup directory
: ${BACKUP_DIR:="$HOME/.local/share/homelab/backups"}

# Database file permissions (restrictive)
: ${DB_DIR_PERMS:="700"}
: ${DB_FILE_PERMS:="600"}

# ========================================
# Docker Compose Configuration
# ========================================

# Docker compose file location
: ${DOCKER_COMPOSE_FILE:="docker-compose.yml"}

# Docker network name
: ${DOCKER_NETWORK:="homelab_network"}

# ========================================
# File Paths and Permissions
# ========================================

# .env file permissions (restrictive)
: ${ENV_FILE_PERMS:="600"}

# nginx auth file permissions
: ${NGINX_AUTH_PERMS:="600"}

# SSH config file permissions
: ${SSH_CONFIG_PERMS:="600"}

# ========================================
# Container Images (Versions)
# ========================================

# Pin specific image versions for reproducibility
# Note: Ollama 0.12.9 required for qwen3-vl:8b support (Nov 2025)
declare -A CONTAINER_IMAGES=(
    [portainer]="portainer/portainer-ce:2.20.0"
    [ollama]="ollama/ollama:0.12.9"
    [openwebui]="ghcr.io/open-webui/open-webui:v0.3.0"
    [langchain]="langchain/langchain:0.1.0"
    [langgraph]="langchain/langgraph-api:0.1.0"
    [langflow]="langflowai/langflow:1.0.0"
    [n8n]="n8nio/n8n:1.95.0"
    [qdrant]="qdrant/qdrant:v1.13.0"
    [nginx]="nginx:alpine"
    [docker_socket_proxy]="tecnativa/docker-socket-proxy:latest"
)

# ========================================
# Node.js Configuration
# ========================================

# Node.js version to install from apt
: ${NODEJS_VERSION:="latest"}

# Claude Code package name
: ${CLAUDE_CODE_PACKAGE:="@anthropic-ai/claude-code"}

# ========================================
# Git Configuration
# ========================================

# Git default branch
: ${GIT_DEFAULT_BRANCH:="main"}

# Git configuration file
: ${GIT_CONFIG:="$HOME/.gitconfig"}

# ========================================
# Script Behavior
# ========================================

# Enable/disable rollback on failure
: ${ENABLE_ROLLBACK:="true"}

# Enable/disable logging to file
: ${ENABLE_FILE_LOGGING:="true"}

# Log file location
: ${LOG_FILE:=".homelab-setup.log"}

# Log level (debug, info, warn, error)
: ${LOG_LEVEL:="info"}

# ========================================
# Feature Flags
# ========================================

# Enable GPU support detection and installation
: ${ENABLE_GPU_SUPPORT:="true"}

# Enable automatic model pulling
: ${ENABLE_AUTO_MODEL_PULL:="true"}

# Enable backup of configuration files
: ${ENABLE_BACKUPS:="true"}

# ========================================
# Helper Function: Get Container Image
# ========================================

# Get full image path for a service
# Usage: get_container_image ollama
get_container_image() {
    local service="$1"
    echo "${CONTAINER_IMAGES[$service]:-unknown}"
}

# ========================================
# Helper Function: Validate Configuration
# ========================================

# Validate all required configuration is set
validate_config() {
    local errors=0

    # Check critical directories are set
    if [ -z "$DATABASE_DIR" ]; then
        error "DATABASE_DIR not set"
        ((errors++))
    fi

    if [ -z "$BACKUP_DIR" ]; then
        error "BACKUP_DIR not set"
        ((errors++))
    fi

    # Check timeouts are numeric
    if ! [[ "$MODEL_PULL_TIMEOUT" =~ ^[0-9]+$ ]]; then
        error "MODEL_PULL_TIMEOUT must be numeric"
        ((errors++))
    fi

    if [ $errors -gt 0 ]; then
        return 1
    fi

    debug "Configuration validation passed"
    return 0
}

# ========================================
# Helper Function: Print Configuration
# ========================================

# Print current configuration (useful for debugging)
print_config() {
    info "Current Configuration:"
    info "  SSH_CONFIG: $SSH_CONFIG"
    info "  DATABASE_DIR: $DATABASE_DIR"
    info "  BACKUP_DIR: $BACKUP_DIR"
    info "  DOCKER_NETWORK: $DOCKER_NETWORK"
    info "  MODEL_PULL_TIMEOUT: $MODEL_PULL_TIMEOUT seconds"
    info "  LOG_LEVEL: $LOG_LEVEL"
    info "  LOG_FILE: $LOG_FILE"
}

# ========================================
# Helper Function: Get Ollama Models
# ========================================

# Get array of Ollama models to pull
get_ollama_models() {
    printf '%s\n' "${OLLAMA_MODELS[@]}"
}

# Get count of Ollama models
get_ollama_models_count() {
    echo ${#OLLAMA_MODELS[@]}
}
