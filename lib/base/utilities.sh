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

# Generate a secure random value appropriate for the variable type
generate_secure_value() {
    local key="$1"

    # Different lengths based on variable type
    case "$key" in
        *_PASSWORD)
            # Passwords: 16 characters, URL-safe
            openssl rand -base64 16 | tr -d '/+=' | head -c 16
            ;;
        N8N_ENCRYPTION_KEY)
            # N8N requires minimum 32 characters
            openssl rand -base64 48 | tr -d '/+=' | head -c 48
            ;;
        *_SECRET*|*_KEY)
            # API keys and secrets: 32 characters
            openssl rand -base64 32 | tr -d '/+='
            ;;
        *)
            # Default: 32 characters
            openssl rand -base64 32 | tr -d '/+='
            ;;
    esac
}

# Update .env file with a new variable value
update_env_file() {
    local key="$1"
    local value="$2"
    local env_file=".env"

    # Check if key already exists in file (even if empty)
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        # Update existing key (handles empty values like KEY=)
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        # Append new key
        echo "${key}=${value}" >> "$env_file"
    fi
}

# Validate API keys and critical environment variables
validate_environment() {
    log "Validating environment configuration..."

    # Check if .env file exists
    if [ ! -f .env ]; then
        log ".env file not found, creating from template..."
        if [ -f .env.example ]; then
            cp .env.example .env
            log "Created .env from .env.example"
        else
            error ".env.example not found"
            error "Please create .env file manually"
            return 1
        fi
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
        invalid_keys+=("N8N_ENCRYPTION_KEY")
    fi

    # Combine missing and invalid keys for auto-generation
    local keys_to_generate=("${missing_keys[@]}" "${invalid_keys[@]}")

    # Offer to auto-generate missing/invalid values
    if [ ${#keys_to_generate[@]} -gt 0 ]; then
        echo ""
        warning "The following environment variables need values:"
        for key in "${keys_to_generate[@]}"; do
            local current_value="${!key}"
            if [ -z "$current_value" ]; then
                echo "  - $key (empty)"
            else
                echo "  - $key (invalid: '$current_value')"
            fi
        done
        echo ""

        read -p "Would you like to auto-generate secure values for these variables? (Y/n): " generate_choice
        generate_choice="${generate_choice:-Y}"

        if [[ "$generate_choice" =~ ^[Yy]$ ]]; then
            log "Generating secure values..."
            echo ""

            for key in "${keys_to_generate[@]}"; do
                local new_value=$(generate_secure_value "$key")
                update_env_file "$key" "$new_value"
                echo "  ✓ $key = ${new_value:0:8}..." # Show first 8 chars only

                # Export to current environment
                export "$key=$new_value"
            done

            echo ""
            success "Generated and saved ${#keys_to_generate[@]} environment variable(s)"
            log "Values saved to .env file"

            # Reload environment to pick up changes
            set -a
            source .env
            set +a
        else
            error "Cannot proceed without required environment variables"
            error "Please edit .env manually and set values for:"
            for key in "${keys_to_generate[@]}"; do
                echo "  - $key"
            done
            error "Generate secure values with: openssl rand -base64 32"
            return 1
        fi
    fi

    debug "Validating email format for optional variables"

    # Validate email if N8N_ADMIN_EMAIL is set
    if [ -n "${N8N_ADMIN_EMAIL}" ]; then
        if ! [[ "${N8N_ADMIN_EMAIL}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            warning "N8N_ADMIN_EMAIL has invalid format: ${N8N_ADMIN_EMAIL}"
            warning "Email notifications may not work correctly"
        fi
    fi

    success "Environment variables validated successfully"
    return 0
}
