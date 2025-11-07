#!/bin/bash

# Homelab Install Script for Ubuntu Server
# Automates setup of homelab with Docker containers and AI/ML workflows
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

# Confirm before proceeding
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Homelab Server Install Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
info "This script will install and configure:"
echo "  - System updates"
echo "  - SSH server"
echo "  - SQLite (local database)"
echo "  - Docker Engine with GPU support"
echo "  - Portainer (container management)"
echo "  - Ollama (LLM runtime)"
echo "  - OpenWebUI (Ollama web interface)"
echo "  - LangChain, LangGraph, LangFlow (AI frameworks)"
echo "  - n8n (workflow automation)"
echo "  - Qdrant (vector database)"
echo "  - AI Models (gpt-oss:20b, qwen3-vl:8b, qwen3-coder:30b, qwen3:8b)"
echo "  - Git (with user configuration)"
echo "  - Claude Code (with project configuration)"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
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
run_step "Docker Engine" install_docker false
run_step "NVIDIA GPU Support" install_nvidia_gpu_support false
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
echo -e "${YELLOW}Service Access:${NC}"
echo "  - nginx reverse proxy (authenticated): https://<server-ip>/"
echo "  - Portainer (Container Management): https://<server-ip>/portainer/"
echo "  - OpenWebUI (Ollama Interface): https://<server-ip>/openwebui/"
echo "  - Ollama API: https://<server-ip>/ollama/"
echo "  - Qdrant (Vector Database): https://<server-ip>/qdrant/"
echo "  - LangChain: https://<server-ip>/langchain/"
echo "  - LangGraph: https://<server-ip>/langgraph/"
echo "  - LangFlow: https://<server-ip>/langflow/"
echo "  - n8n (Workflow Automation): https://<server-ip>/n8n/"
echo ""

echo -e "${YELLOW}Database Access:${NC}"
echo "  - SQLite: ~/.local/share/homelab/databases/"
echo "  - Qdrant Collections: Via REST API at https://<server-ip>/qdrant/"
echo ""

echo -e "${YELLOW}Important notes:${NC}"
echo "  - Log out and back in for Docker group changes to take effect"
echo "  - SSH is now enabled for remote access (key-based auth only)"
echo "  - Git is configured with your user information"
echo "  - Claude Code is installed globally and ready to use"
echo "  - Project-specific Claude Code configuration at: ./.claude/CLAUDE.md"
echo "  - Global Claude Code configuration at: ~/.claude/CLAUDE.md"
echo "  - Ollama models are being pulled in the background (may take 1-2 hours)"
echo "  - GPU support requires NVIDIA drivers and docker runtime configuration"
echo "  - Find your server IP with: hostname -I"
echo "  - SQLite databases location: ~/.local/share/homelab/databases/"
echo ""

log "For GPU support, uncomment the runtime: nvidia lines in docker-compose.yml"
log "To start using Claude Code: claude-code"
log "Consider rebooting your system to ensure all changes take effect."
echo ""
