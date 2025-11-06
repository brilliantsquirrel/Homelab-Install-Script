#!/bin/bash

# Personal Post-Install Script for Ubuntu
# Automates common tasks after a fresh Ubuntu installation

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track installation results
declare -A INSTALL_STATUS
FAILED_STEPS=()
INSTALLED_PACKAGES=()
ADDED_REPOS=()

# Track what was installed for potential rollback
track_package() {
    INSTALLED_PACKAGES+=("$1")
}

track_repo() {
    ADDED_REPOS+=("$1")
}

# Rollback function (called manually when needed)
rollback() {
    echo ""
    error "Would you like to rollback the changes made during this installation? (y/N)"
    read -p "> " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Rollback cancelled."
        return 0
    fi

    error "Rolling back changes..."

    # Remove installed packages
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        log "Removing installed packages: ${INSTALLED_PACKAGES[*]}"
        sudo apt-get remove -y "${INSTALLED_PACKAGES[@]}" 2>/dev/null || true
    fi

    # Remove added repositories
    if [ ${#ADDED_REPOS[@]} -gt 0 ]; then
        for repo in "${ADDED_REPOS[@]}"; do
            log "Removing repository: $repo"
            if [[ "$repo" == "ppa:"* ]]; then
                sudo add-apt-repository --remove -y "$repo" 2>/dev/null || true
            else
                sudo rm -f "$repo" 2>/dev/null || true
            fi
        done
    fi

    # Clean up any temporary files
    rm -f /tmp/discord.deb 2>/dev/null || true

    log "Rollback completed. Some manual cleanup may be required."
}

# Logging function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Execute a step and track its status
run_step() {
    local step_name="$1"
    local step_function="$2"
    local critical="${3:-false}"  # Default to non-critical

    log "Starting: $step_name"

    if $step_function; then
        INSTALL_STATUS["$step_name"]="SUCCESS"
        success "$step_name completed"
        return 0
    else
        INSTALL_STATUS["$step_name"]="FAILED"
        FAILED_STEPS+=("$step_name")
        error "$step_name failed"

        if [[ "$critical" == "true" ]]; then
            error "Critical step failed. Aborting."
            rollback
            exit 1
        fi
        return 1
    fi
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   error "This script should not be run as root. Run as regular user with sudo privileges."
   exit 1
fi

# Confirm before proceeding
echo -e "${BLUE}Personal Ubuntu Post-Install Script${NC}"
echo "This script will install and configure:"
echo "  - System updates"
echo "  - Proprietary graphics drivers"
echo "  - Docker Engine"
echo "  - Latest stable Python"
echo "  - Discord"
echo "  - 1Password Firefox add-on"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

log "Starting post-install setup..."

# Installation functions
install_system_updates() {
    sudo apt-get update && sudo apt-get upgrade -y
}

install_graphics_drivers() {
    # Check if proprietary drivers are already installed
    if ubuntu-drivers list --gpgpu 2>/dev/null | grep -q "installed"; then
        log "Proprietary graphics drivers already installed, skipping"
        return 0
    fi
    sudo ubuntu-drivers autoinstall
}

install_docker() {
    # Check if Docker is already installed
    if command -v docker &> /dev/null && docker --version &> /dev/null; then
        log "Docker already installed ($(docker --version)), skipping"
        # Still ensure user is in docker group
        sudo usermod -aG docker $USER 2>/dev/null || true
        return 0
    fi

    # Remove old versions if they exist (ignore if not present)
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release || return 1

    # Add Docker's official GPG key
    sudo mkdir -p /etc/apt/keyrings || return 1
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || return 1

    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || return 1
    track_repo "/etc/apt/sources.list.d/docker.list"

    # Install Docker Engine
    sudo apt-get update || return 1
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    track_package "docker-ce"

    # Add user to docker group (non-critical, ignore if already in group)
    sudo usermod -aG docker $USER 2>/dev/null || true
    log "You'll need to log out and back in for Docker group changes to take effect."
}

install_python() {
    sudo apt-get install -y software-properties-common || return 1
    sudo add-apt-repository ppa:deadsnakes/ppa -y || return 1
    track_repo "ppa:deadsnakes/ppa"
    sudo apt-get update || return 1

    # Auto-detect latest available Python 3 version from deadsnakes PPA
    # List available python3.x packages and extract highest version number
    PYTHON_VERSION=$(apt-cache search --names-only '^python3\.[0-9]+$' | \
        grep -oP 'python3\.\K[0-9]+' | \
        sort -n | \
        tail -1)

    if [ -z "$PYTHON_VERSION" ]; then
        warning "Could not auto-detect Python version, falling back to 3.12"
        PYTHON_VERSION="3.12"
    else
        log "Detected latest Python version: 3.${PYTHON_VERSION}"
        PYTHON_VERSION="3.${PYTHON_VERSION}"
    fi

    # Check if this Python version is already installed
    if command -v python${PYTHON_VERSION} &> /dev/null; then
        log "Python ${PYTHON_VERSION} already installed ($(python${PYTHON_VERSION} --version)), skipping"
        return 0
    fi

    sudo apt-get install -y python${PYTHON_VERSION} python${PYTHON_VERSION}-pip python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev || return 1
    track_package "python${PYTHON_VERSION}"

    # Make it available as python3
    sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 || return 1
}

install_discord() {
    # Check if Discord is already installed
    if command -v discord &> /dev/null || dpkg -l | grep -q "^ii.*discord"; then
        log "Discord already installed, skipping"
        return 0
    fi

    wget -O /tmp/discord.deb "https://discord.com/api/download?platform=linux&format=deb" || return 1
    sudo dpkg -i /tmp/discord.deb || sudo apt-get install -f -y  # Fix dependency issues if dpkg fails
    track_package "discord"
    rm -f /tmp/discord.deb
}

install_1password() {
    # Check if 1Password is already installed
    if command -v 1password &> /dev/null || dpkg -l | grep -q "^ii.*1password"; then
        log "1Password already installed, skipping"
        return 0
    fi

    warning "1Password Firefox add-on needs to be installed manually."
    warning "Please visit: https://addons.mozilla.org/en-US/firefox/addon/1password-x-password-manager/"

    # Install 1Password desktop app
    curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg || return 1
    echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main' | sudo tee /etc/apt/sources.list.d/1password.list || return 1
    track_repo "/etc/apt/sources.list.d/1password.list"
    sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/ || return 1
    curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol || return 1
    sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22 || return 1
    curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg || return 1
    sudo apt update && sudo apt install -y 1password || return 1
    track_package "1password"
}

install_utilities() {
    # Note: curl, wget, ca-certificates already installed by Docker
    # software-properties-common already installed by Python setup
    sudo apt-get install -y \
        git \
        vim \
        htop \
        tree \
        unzip \
        build-essential || return 1
}

cleanup_system() {
    sudo apt-get autoremove -y || return 1
    sudo apt-get autoclean || return 1
}

# Run installation steps
run_step "System Updates" install_system_updates true
run_step "Graphics Drivers" install_graphics_drivers false
run_step "Docker Engine" install_docker false
run_step "Python" install_python false
run_step "Discord" install_discord false
run_step "1Password" install_1password false
run_step "Utility Packages" install_utilities false
run_step "System Cleanup" cleanup_system false

# Final summary
echo ""
echo "========================================"
log "Post-install script completed!"
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

echo ""
echo -e "${YELLOW}Important notes:${NC}"
echo "  - Log out and back in for Docker group changes to take effect"
echo "  - Graphics drivers may require a reboot"
echo "  - Install 1Password Firefox add-on manually from the Firefox add-ons store"
echo "  - Solomon's personal scripts: None defined yet"
echo ""
log "Consider rebooting your system to ensure all changes take effect."