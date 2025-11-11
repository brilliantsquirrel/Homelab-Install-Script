#!/bin/bash

# Homelab Install Script for Ubuntu Server
# Automates setup of homelab with Docker containers and AI/ML workflows
#
# SETUP:
#   1. Fresh Ubuntu Server 20.04, 22.04, or 24.04 installation
#   2. Log in as regular user with sudo privileges
#   3. Clone repo: git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
#   4. Run: cd Homelab-Install-Script && ./post-install.sh
#
# Usage:
#   ./post-install.sh              # Interactive setup (will generate .env if needed)
#   SKIP_ENV_SETUP=1 ./post-install.sh   # Skip environment setup, use existing .env
#
# Error Handling Strategy:
# ======================
# This script uses explicit error handling rather than 'set -e' for more control:
#
# Critical operations (must not fail):
#   - Use: command || return 1
#   - Example: sudo apt-get update || return 1
#   - Effect: Function fails and installation stops
#
# Optional operations (nice to have, failure is acceptable):
#   - Use: command || true
#   - Example: sudo usermod -aG docker $USER || true
#   - Effect: Failure is logged but doesn't stop installation
#
# Expected failures (suppress noise):
#   - Use: command 2>/dev/null || true
#   - Example: command -v oldcmd 2>/dev/null || true
#   - Effect: No error message, silent failure is acceptable
#
# Run steps are wrapped in run_step() which tracks success/failure.

# ========================================
# Module Loading
# ========================================

# Get script directory for module imports
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source all required modules in order
source "$SCRIPT_DIR/lib/logger.sh" || {
    echo "FATAL: Failed to source lib/logger.sh"
    exit 1
}

source "$SCRIPT_DIR/lib/error-handling.sh" || {
    error "FATAL: Failed to source lib/error-handling.sh"
    exit 1
}

source "$SCRIPT_DIR/lib/config.sh" || {
    error "FATAL: Failed to source lib/config.sh"
    exit 1
}

source "$SCRIPT_DIR/lib/base/system.sh" || {
    error "FATAL: Failed to source lib/base/system.sh"
    exit 1
}

source "$SCRIPT_DIR/lib/base/docker.sh" || {
    error "FATAL: Failed to source lib/base/docker.sh"
    exit 1
}

source "$SCRIPT_DIR/lib/base/storage.sh" || {
    error "FATAL: Failed to source lib/base/storage.sh"
    exit 1
}

source "$SCRIPT_DIR/lib/base/development.sh" || {
    error "FATAL: Failed to source lib/base/development.sh"
    exit 1
}

source "$SCRIPT_DIR/lib/base/utilities.sh" || {
    error "FATAL: Failed to source lib/base/utilities.sh"
    exit 1
}

# Initialize logger
init_logger

# Validate configuration
if ! validate_config; then
    error "Configuration validation failed"
    exit 1
fi

debug "All modules loaded successfully"

# ========================================
# Pre-Installation Checks
# ========================================

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   error "This script should not be run as root. Run as regular user with sudo privileges."
   exit 1
fi

# ========================================
# Environment Setup (generate .env if needed)
# ========================================

setup_environment() {
    log "Setting up environment configuration..."

    # Check if .env exists
    if [ -f ".env" ]; then
        debug ".env file already exists"
        return 0
    fi

    # Check if .env.example exists
    if [ ! -f ".env.example" ]; then
        error ".env.example not found"
        error "Make sure you're in the Homelab Install Script directory"
        return 1
    fi

    info "No .env file found. Creating one with auto-generated API keys..."
    echo ""

    # Generate all required API keys
    debug "Generating secure API keys..."
    local OLLAMA_API_KEY=$(openssl rand -base64 32)
    local WEBUI_SECRET_KEY=$(openssl rand -base64 32)
    local QDRANT_API_KEY=$(openssl rand -base64 32)
    local N8N_ENCRYPTION_KEY=$(openssl rand -base64 32)
    local LANGCHAIN_API_KEY=$(openssl rand -base64 32)
    local LANGGRAPH_API_KEY=$(openssl rand -base64 32)
    local LANGGRAPH_DB_PASSWORD=$(openssl rand -base64 32)
    local LANGFLOW_API_KEY=$(openssl rand -base64 32)
    local NGINX_AUTH_PASSWORD=$(openssl rand -base64 32)
    local HOARDER_SECRET_KEY=$(openssl rand -base64 32)
    local NEXTAUTH_SECRET=$(openssl rand -base64 32)
    local NEXTCLOUD_DB_PASSWORD=$(openssl rand -base64 32)
    local PIHOLE_PASSWORD=$(openssl rand -base64 32)

    log "Generated 13 secure API keys and passwords"
    echo ""

    # Set restrictive umask before creating file (prevents race condition)
    # This ensures .env is created with 600 permissions from the start
    local old_umask=$(umask)
    umask 077

    # Copy template (will inherit restrictive permissions from umask)
    cp .env.example .env
    debug "Copied .env from .env.example with secure permissions (600)"

    # Replace values in .env
    sed -i "s|^OLLAMA_API_KEY=.*|OLLAMA_API_KEY=$OLLAMA_API_KEY|" .env
    sed -i "s|^WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY|" .env
    sed -i "s|^QDRANT_API_KEY=.*|QDRANT_API_KEY=$QDRANT_API_KEY|" .env
    sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY|" .env
    sed -i "s|^LANGCHAIN_API_KEY=.*|LANGCHAIN_API_KEY=$LANGCHAIN_API_KEY|" .env
    sed -i "s|^LANGGRAPH_API_KEY=.*|LANGGRAPH_API_KEY=$LANGGRAPH_API_KEY|" .env
    sed -i "s|^LANGGRAPH_DB_PASSWORD=.*|LANGGRAPH_DB_PASSWORD=$LANGGRAPH_DB_PASSWORD|" .env
    sed -i "s|^LANGFLOW_API_KEY=.*|LANGFLOW_API_KEY=$LANGFLOW_API_KEY|" .env
    sed -i "s|^NGINX_AUTH_PASSWORD=.*|NGINX_AUTH_PASSWORD=$NGINX_AUTH_PASSWORD|" .env
    sed -i "s|^HOARDER_SECRET_KEY=.*|HOARDER_SECRET_KEY=$HOARDER_SECRET_KEY|" .env
    sed -i "s|^NEXTAUTH_SECRET=.*|NEXTAUTH_SECRET=$NEXTAUTH_SECRET|" .env
    sed -i "s|^NEXTCLOUD_DB_PASSWORD=.*|NEXTCLOUD_DB_PASSWORD=$NEXTCLOUD_DB_PASSWORD|" .env
    sed -i "s|^PIHOLE_PASSWORD=.*|PIHOLE_PASSWORD=$PIHOLE_PASSWORD|" .env

    debug "Replaced all API keys and passwords in .env"

    # Restore original umask
    umask "$old_umask"

    # Verify permissions (defense in depth)
    chmod 600 .env
    log ".env file created with auto-generated keys (permissions: 600)"

    # Prompt for N8N_ADMIN_EMAIL
    echo ""
    echo -e "${YELLOW}REQUIRED: N8N Admin Email${NC}"
    echo "This is the email for your n8n workflow automation admin account"
    echo ""
    local n8n_email=""
    while [ -z "$n8n_email" ]; do
        read -p "Enter your email address (e.g., admin@example.com): " n8n_email

        # Trim whitespace
        n8n_email=$(echo "$n8n_email" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Security: Length validation (RFC 5321: max 254 chars for email)
        if [ ${#n8n_email} -gt 254 ]; then
            error "Email too long. Maximum 254 characters allowed."
            n8n_email=""
            continue
        fi

        # Security: Check for header injection patterns (newlines, carriage returns)
        if [[ "$n8n_email" =~ [$'\n\r'] ]]; then
            error "Invalid email: contains prohibited characters."
            n8n_email=""
            continue
        fi

        # Security: Check for dangerous shell metacharacters
        if [[ "$n8n_email" =~ [\;\|\&\$\`\\] ]]; then
            error "Invalid email: contains prohibited characters."
            n8n_email=""
            continue
        fi

        # Security: Check for path traversal patterns
        if [[ "$n8n_email" == *".."* ]]; then
            error "Invalid email: contains prohibited patterns."
            n8n_email=""
            continue
        fi

        # Validate email format (stricter regex)
        if ! [[ "$n8n_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            error "Invalid email format. Please try again."
            n8n_email=""
            continue
        fi

        # Security: Validate local part and domain lengths (RFC 5321)
        local local_part="${n8n_email%%@*}"
        local domain_part="${n8n_email#*@}"
        if [ ${#local_part} -gt 64 ] || [ ${#domain_part} -gt 253 ]; then
            error "Invalid email: local part (max 64 chars) or domain (max 253 chars) too long."
            n8n_email=""
            continue
        fi
    done

    # Security: Update N8N_ADMIN_EMAIL safely (escape special sed characters)
    # Use a different delimiter (|) and escape any | characters in the email
    local escaped_email="${n8n_email//|/\\|}"
    sed -i "s|^N8N_ADMIN_EMAIL=.*|N8N_ADMIN_EMAIL=$escaped_email|" .env
    log "N8N_ADMIN_EMAIL configured"

    echo ""
    success "Environment configuration complete!"
    echo ""
}

# ========================================
# Run environment setup unless skipped
# ========================================

if [ "${SKIP_ENV_SETUP}" != "1" ]; then
    if ! setup_environment; then
        error "Environment setup failed"
        exit 1
    fi
fi

# ========================================
# Confirm before proceeding with installation
# ========================================

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Homelab Server Install Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
info "This script will install and configure:"
echo "  - System updates"
echo "  - SSH server (hardened)"
echo "  - SQLite (local database)"
echo "  - Docker Engine with GPU support"
echo "  - Cockpit (web-based server management)"
echo ""
echo "  Container Services:"
echo "  - Portainer (container management)"
echo "  - Ollama (LLM runtime)"
echo "  - OpenWebUI (Ollama web interface)"
echo "  - LangChain, LangGraph, LangFlow (AI frameworks)"
echo "  - n8n (workflow automation)"
echo "  - Qdrant (vector database)"
echo ""
echo "  Homelab Services:"
echo "  - Homarr (homelab dashboard)"
echo "  - Hoarder (bookmark manager)"
echo "  - Plex (media server)"
echo "  - Nextcloud (file storage & collaboration)"
echo "  - Pi-Hole (DNS-based ad blocker)"
echo ""
echo "  Additional Setup:"
echo "  - AI Models (gpt-oss:20b, qwen3-vl:8b, qwen3-coder:30b, qwen3:8b)"
echo "  - Git (with user configuration)"
echo "  - Claude Code (with project configuration)"
echo "  - Custom storage paths (for optimal performance)"
echo ""
echo -e "${YELLOW}This installation will take 30-60 minutes depending on your system.${NC}"
echo -e "${YELLOW}Ollama model pulling may take 1-2 hours additional.${NC}"
echo ""

read -p "Do you want to continue with installation? (y/N): " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Installation cancelled by user."
    exit 0
fi

log "Starting homelab setup..."

# First, validate environment variables before proceeding
# This is a critical step - fail fast if configuration is missing
if ! validate_environment; then
    error "Environment validation failed. Cannot proceed with installation."
    error "Please fix the errors above and try again."
    exit 1
fi

# ========================================
# Installation Steps
# ========================================

log "Configuration validated, proceeding with installation"
echo ""

run_step "System Updates" install_system_updates true
run_step "SSH Server" install_ssh false
run_step "SQLite" install_sqlite false
run_step "Cockpit" install_cockpit false
run_step "Storage Configuration" configure_storage_tiers false
run_step "Docker Engine" install_docker false
run_step "Docker Storage" configure_docker_storage false
run_step "NVIDIA GPU Support" install_nvidia_gpu_support false
run_step "Pi-Hole DNS Configuration" configure_pihole_dns false
run_step "Storage Paths" update_docker_compose_storage false
run_step "SQLite Storage" configure_sqlite_storage false
run_step "Docker Containers" install_docker_containers false
run_step "Ollama Models" pull_ollama_models false
run_step "Git Configuration" configure_git false
run_step "Claude Code Installation" install_claude_code false
run_step "Claude Project Setup" setup_claude_project false
run_step "Utility Packages" install_utilities false
run_step "System Cleanup" cleanup_system false

# ========================================
# Installation Summary
# ========================================

echo ""
echo "========================================"
log "Homelab setup completed!"
echo "========================================"
echo ""

if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    success "All steps completed successfully!"
else
    warning "Some steps failed:"
    for step in "${FAILED_STEPS[@]}"; do
        echo -e "  ${RED}✗${NC} $step"
    done
    echo ""

    # Offer rollback if any installations were made
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ] || [ ${#ADDED_REPOS[@]} -gt 0 ]; then
        rollback
    fi
fi

# ========================================
# Post-Installation Information
# ========================================

echo ""
echo -e "${YELLOW}Service Access (all via nginx with authentication):${NC}"
echo "  - Homarr Dashboard: https://<server-ip>/ (redirects to /homarr)"
echo "  - Cockpit Server Management: https://<server-ip>:9090 (no proxy, direct access)"
echo ""
echo "  Homelab Services:"
echo "  - Homarr (Dashboard): https://<server-ip>/homarr"
echo "  - Hoarder (Bookmarks): https://<server-ip>/hoarder"
echo "  - Plex (Media): https://<server-ip>/plex"
echo "  - Nextcloud (Files): https://<server-ip>/nextcloud"
echo "  - Pi-Hole (Ad Blocker): https://<server-ip>/pihole"
echo ""
echo "  AI Services:"
echo "  - OpenWebUI (Ollama Interface): https://<server-ip>/openwebui"
echo "  - Ollama API: https://<server-ip>/ollama"
echo "  - LangChain: https://<server-ip>/langchain"
echo "  - LangGraph: https://<server-ip>/langgraph"
echo "  - LangFlow: https://<server-ip>/langflow"
echo "  - n8n (Workflow Automation): https://<server-ip>/n8n"
echo ""
echo "  Management:"
echo "  - Portainer (Container Management): https://<server-ip>/portainer"
echo "  - Qdrant (Vector Database): https://<server-ip>/qdrant"
echo ""

echo -e "${YELLOW}AI Database Stack:${NC}"
echo "  - SQLite databases: ~/.local/share/homelab/databases/"
echo "  - Qdrant vector database: https://<server-ip>/qdrant/"
echo ""
echo "  Initialize AI databases with: ./sqlite-ai-init.sh"
echo "  - Creates: conversations.db, rag.db, workflows.db, model_performance.db"
echo "  - Optimized for AI/ML workloads (RAG, chat history, workflow tracking)"
echo "  - See ai-stack-examples.md for integration examples"
echo ""

echo -e "${YELLOW}Important Notes:${NC}"
echo "  - All services require nginx basic authentication (user: admin)"
echo "  - Cockpit uses system credentials and runs on separate port 9090"
echo "  - Pi-Hole is DNS server on port 53 (UDP/TCP)"
echo "  - Log out and back in for Docker group changes to take effect"
echo "  - SSH is hardened for security (key-based auth only, no root login)"
echo "  - Find your server IP with: hostname -I"
echo "  - Ollama models are being pulled in the background (may take 1-2 hours)"
echo ""

echo -e "${YELLOW}GPU Support:${NC}"
echo "  - For Ollama GPU: Uncomment 'runtime: nvidia' in docker-compose.yml (ollama service)"
echo "  - For Plex GPU transcoding: Uncomment GPU config in docker-compose.yml (plex service)"
echo "  - Requires NVIDIA drivers and nvidia-docker2 toolkit (auto-installed if GPU detected)"
echo ""

echo -e "${YELLOW}Media Server Setup:${NC}"
echo "  - Plex media location: Docker volume 'plex_media' (mount your media here)"
echo "  - To add media: docker volume inspect plex_media (find mount point)"
echo "  - Or: bind mount your media directory by editing docker-compose.yml"
echo ""

echo -e "${YELLOW}DNS Configuration (Pi-Hole):${NC}"
echo "  - Configure devices to use <server-ip> as DNS server"
echo "  - Or set as router's DNS server to protect entire network"
echo "  - Pi-Hole admin password is in .env file (PIHOLE_PASSWORD)"
echo ""
echo "  Once DNS is configured, access services via friendly names:"
echo "  - https://homarr.home - Dashboard"
echo "  - https://plex.home - Media Server"
echo "  - https://nextcloud.home - File Storage"
echo "  - https://pihole.home - Ad Blocker Admin"
echo "  - https://cockpit.home:9090 - Server Management"
echo "  - https://hoarder.home, https://ollama.home, https://openwebui.home, etc."
echo ""

log "Consider rebooting your system to ensure all changes take effect"
log "To start using Claude Code: claude-code"
echo ""
