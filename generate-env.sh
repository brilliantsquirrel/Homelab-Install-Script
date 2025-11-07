#!/bin/bash

# Generate .env file with auto-generated secure keys
# Usage: ./generate-env.sh
# This script creates a .env file with randomly generated API keys

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[✓]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Header
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Homelab Environment Generator${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if .env already exists
if [ -f ".env" ]; then
    warning ".env file already exists"
    read -p "Do you want to regenerate it? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Using existing .env file"
        exit 0
    fi
    info "Backing up existing .env file to .env.backup"
    cp .env ".env.backup.$(date +%Y%m%d_%H%M%S)"
fi

# Check if .env.example exists
if [ ! -f ".env.example" ]; then
    error ".env.example not found in current directory"
    error "Make sure you're in the Homelab Install Script directory"
    exit 1
fi

info "Generating secure API keys..."
echo ""

# Generate all required keys
OLLAMA_API_KEY=$(openssl rand -base64 32)
log "Generated OLLAMA_API_KEY"

WEBUI_SECRET_KEY=$(openssl rand -base64 32)
log "Generated WEBUI_SECRET_KEY"

QDRANT_API_KEY=$(openssl rand -base64 32)
log "Generated QDRANT_API_KEY"

N8N_ENCRYPTION_KEY=$(openssl rand -base64 32)
log "Generated N8N_ENCRYPTION_KEY"

LANGCHAIN_API_KEY=$(openssl rand -base64 32)
log "Generated LANGCHAIN_API_KEY"

LANGGRAPH_API_KEY=$(openssl rand -base64 32)
log "Generated LANGGRAPH_API_KEY"

LANGFLOW_API_KEY=$(openssl rand -base64 32)
log "Generated LANGFLOW_API_KEY"

NGINX_AUTH_PASSWORD=$(openssl rand -base64 32)
log "Generated NGINX_AUTH_PASSWORD"

echo ""
info "Creating .env file..."

# Copy template and replace values
cp .env.example .env

# Replace empty API keys with generated values
sed -i "s|^OLLAMA_API_KEY=.*|OLLAMA_API_KEY=$OLLAMA_API_KEY|" .env
sed -i "s|^WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY|" .env
sed -i "s|^QDRANT_API_KEY=.*|QDRANT_API_KEY=$QDRANT_API_KEY|" .env
sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY|" .env
sed -i "s|^LANGCHAIN_API_KEY=.*|LANGCHAIN_API_KEY=$LANGCHAIN_API_KEY|" .env
sed -i "s|^LANGGRAPH_API_KEY=.*|LANGGRAPH_API_KEY=$LANGGRAPH_API_KEY|" .env
sed -i "s|^LANGFLOW_API_KEY=.*|LANGFLOW_API_KEY=$LANGFLOW_API_KEY|" .env
sed -i "s|^NGINX_AUTH_PASSWORD=.*|NGINX_AUTH_PASSWORD=$NGINX_AUTH_PASSWORD|" .env

log ".env file created with auto-generated keys"

# Set restrictive permissions
chmod 600 .env
log ".env permissions set to 600 (read/write owner only)"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Required Configuration${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

info "The following fields still need manual configuration:"
echo ""

# Check and prompt for required manual fields
N8N_ADMIN_EMAIL=$(grep "^N8N_ADMIN_EMAIL=" .env | cut -d'=' -f2)
if [ -z "$N8N_ADMIN_EMAIL" ]; then
    warning "N8N_ADMIN_EMAIL is not set"
    echo ""
    read -p "Enter n8n admin email address: " N8N_ADMIN_EMAIL
    if [ -n "$N8N_ADMIN_EMAIL" ]; then
        sed -i "s|^N8N_ADMIN_EMAIL=.*|N8N_ADMIN_EMAIL=$N8N_ADMIN_EMAIL|" .env
        log "N8N_ADMIN_EMAIL updated"
    else
        warning "N8N_ADMIN_EMAIL left empty (you can edit .env later)"
    fi
fi

echo ""
echo -e "${BLUE}Generated Values Summary${NC}"
echo "========================================${NC}"
echo ""
echo "The following API keys have been auto-generated:"
echo "  ✓ OLLAMA_API_KEY"
echo "  ✓ WEBUI_SECRET_KEY"
echo "  ✓ QDRANT_API_KEY"
echo "  ✓ N8N_ENCRYPTION_KEY"
echo "  ✓ LANGCHAIN_API_KEY"
echo "  ✓ LANGGRAPH_API_KEY"
echo "  ✓ LANGFLOW_API_KEY"
echo "  ✓ NGINX_AUTH_PASSWORD"
echo ""
echo "Manual configuration needed:"
echo "  □ N8N_ADMIN_EMAIL (n8n admin user email)"
echo "  □ Review other optional settings"
echo ""

info "To review or edit configuration:"
echo "  nano .env"
echo ""

info "To validate your setup:"
echo "  ./validate-setup.sh"
echo ""

info "To run the installation:"
echo "  ./post-install.sh"
echo ""

success ".env file ready for installation!"
echo ""
