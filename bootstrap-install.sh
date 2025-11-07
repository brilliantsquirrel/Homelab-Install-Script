#!/bin/bash

# Homelab Install Script - Bootstrap Installer
# This script clones the Homelab Install Script repository and guides you through setup
#
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/brilliantsquirrel/Homelab-Install-Script/main/bootstrap-install.sh)
#
# Or manually:
#   git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git ~/homelab-install
#   cd ~/homelab-install
#   ./bootstrap-install.sh

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
echo -e "${BLUE}Homelab Install Script - Bootstrap${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root"
    error "Run as regular user with sudo privileges"
    exit 1
fi

# Check prerequisites
echo "Checking prerequisites..."
echo ""

if ! command -v git &>/dev/null; then
    error "Git is not installed"
    info "Install with: sudo apt-get install -y git"
    exit 1
fi
log "Git is installed"

if ! command -v curl &>/dev/null; then
    warning "curl is not installed - you may need it for some operations"
fi

if ! command -v sudo &>/dev/null; then
    error "sudo is not available"
    error "This script requires sudo privileges"
    exit 1
fi
log "sudo is available"

echo ""

# Determine installation directory
INSTALL_DIR="${1:-$HOME/homelab-install}"

# Create installation directory
if [ -d "$INSTALL_DIR" ]; then
    warning "Directory already exists: $INSTALL_DIR"
    echo ""
    read -p "Do you want to update from git? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "Updating repository..."
        cd "$INSTALL_DIR"
        git pull origin main
        log "Repository updated"
    else
        info "Using existing installation directory"
    fi
else
    info "Creating installation directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    info "Cloning repository..."
    git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    log "Repository cloned"
fi

echo ""
cd "$INSTALL_DIR"

# Check that we have the required files
if [ ! -f "post-install.sh" ]; then
    error "post-install.sh not found in $INSTALL_DIR"
    error "Repository may be corrupted"
    exit 1
fi
log "Installation scripts found"

if [ ! -f ".env.example" ]; then
    error ".env.example not found"
    error "Repository may be incomplete"
    exit 1
fi
log "Configuration template found"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Setup Complete - Next Steps${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if .env exists
if [ ! -f ".env" ]; then
    info "Creating .env file from template..."
    cp .env.example .env
    log ".env file created"
    echo ""
    warning "IMPORTANT: Edit .env and set all required API keys"
    warning "           Some keys will prevent installation if missing"
else
    info ".env file already exists"
fi

echo ""
echo "1. Edit configuration (set API keys, passwords, etc):"
echo "   nano $INSTALL_DIR/.env"
echo ""

echo "2. Review required environment variables:"
echo "   cat .env"
echo ""

echo "3. Run pre-installation validation:"
echo "   cd $INSTALL_DIR"
echo "   ./validate-setup.sh"
echo ""

echo "4. Run the main installation:"
echo "   cd $INSTALL_DIR"
echo "   ./post-install.sh"
echo ""

echo -e "${BLUE}Documentation:${NC}"
echo "  - README.md           - User documentation and features"
echo "  - DEVELOPER.md        - Development guide and architecture"
echo "  - SECRETS.md          - Secret management best practices"
echo "  - SECURITY.md         - Security audit and recommendations"
echo "  - .env.example        - Configuration template with descriptions"
echo ""

echo -e "${BLUE}Project location:${NC}"
echo "  $INSTALL_DIR"
echo ""

log "Bootstrap complete! Ready to configure and install."
echo ""
