#!/bin/bash

# Utilities Module - Utility packages and system validation
# Usage: source lib/base/utilities.sh
# Provides: install_utilities, cleanup_system, validate_environment

# ========================================
# Utility Packages
# ========================================

# Install useful system utilities
install_utilities() {
    log "Installing utility packages..."

    sudo apt-get install -y \
        git \
        vim \
        htop \
        tree \
        unzip \
        build-essential \
        net-tools \
        jq || return 1

    success "Utility packages installed"
}

# ========================================
# System Cleanup
# ========================================

# Clean up unnecessary packages and cache
cleanup_system() {
    log "Cleaning up system packages..."

    sudo apt-get autoremove -y || return 1
    sudo apt-get autoclean || return 1

    success "System cleanup completed"
}

# ========================================
# Environment Validation
# ========================================

# Validate API keys and critical environment variables
validate_environment() {
    log "Validating environment configuration..."

    # Check if .env file exists
    if [ ! -f .env ]; then
        error ".env file not found"
        error "Please copy .env.example to .env and set all required values:"
        error "  cp .env.example .env"
        error "  nano .env"
        return 1
    fi

    debug "Loading environment variables from .env"

    # Load environment variables
    set -a
    source .env
    set +a

    local missing_keys=()
    local invalid_keys=()

    # Check for required API keys (must not be empty or placeholder values)
    # These must match all ${VAR:?error} variables in docker-compose.yml
    local required_keys=(
        # AI Services
        "OLLAMA_API_KEY"
        "WEBUI_SECRET_KEY"
        "QDRANT_API_KEY"
        "N8N_ENCRYPTION_KEY"
        "LANGCHAIN_API_KEY"
        "LANGGRAPH_API_KEY"
        "LANGGRAPH_DB_PASSWORD"
        "LANGFLOW_API_KEY"
        # Infrastructure
        "NGINX_AUTH_PASSWORD"
        # Homelab Services
        "HOARDER_SECRET_KEY"
        "NEXTAUTH_SECRET"
        "NEXTCLOUD_DB_PASSWORD"
        "PIHOLE_PASSWORD"
        "CODE_SERVER_PASSWORD"
    )

    debug "Validating required environment variables"

    for key in "${required_keys[@]}"; do
        local value="${!key}"

        # Check if key is empty
        if [ -z "$value" ]; then
            missing_keys+=("$key")
            continue
        fi

        # Check if still using placeholder values
        if [[ "$value" == "changeme"* ]] || [[ "$value" == "your-"* ]]; then
            invalid_keys+=("$key")
            continue
        fi
    done

    # Check N8N_ENCRYPTION_KEY minimum length
    if [ -n "${N8N_ENCRYPTION_KEY}" ] && [ ${#N8N_ENCRYPTION_KEY} -lt 32 ]; then
        invalid_keys+=("N8N_ENCRYPTION_KEY (less than 32 characters)")
    fi

    debug "Validating email format for optional variables"

    # Validate email if N8N_ADMIN_EMAIL is set
    if [ -n "${N8N_ADMIN_EMAIL}" ]; then
        if ! [[ "${N8N_ADMIN_EMAIL}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            invalid_keys+=("N8N_ADMIN_EMAIL (invalid format)")
        fi
    fi

    # Report missing keys
    if [ ${#missing_keys[@]} -gt 0 ]; then
        error "Missing required environment variables:"
        for key in "${missing_keys[@]}"; do
            echo "  - $key (not set, cannot be empty)"
        done
        return 1
    fi

    # Report invalid keys
    if [ ${#invalid_keys[@]} -gt 0 ]; then
        error "Invalid or placeholder environment variables:"
        for key in "${invalid_keys[@]}"; do
            echo "  - $key (must be set to a real value)"
        done
        error "Generate secure values with: openssl rand -base64 32"
        return 1
    fi

    success "Environment variables validated successfully"
    return 0
}
