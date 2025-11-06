#!/bin/bash

# Homelab Install Script for Ubuntu Server
# Automates setup of homelab with Docker containers and AI/ML workflows

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
echo -e "${BLUE}Homelab Server Install Script${NC}"
echo "This script will install and configure:"
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
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

log "Starting homelab setup..."

# Installation functions
install_system_updates() {
    sudo apt-get update && sudo apt-get upgrade -y || return 1
}

install_ssh() {
    # Check if SSH is already installed and running
    if sudo systemctl is-active --quiet ssh; then
        log "SSH already installed and running"
        # Apply hardening to existing SSH even if already installed
    else
        sudo apt-get install -y openssh-server openssh-client || return 1
        sudo systemctl enable ssh || return 1
        sudo systemctl start ssh || return 1
        track_package "openssh-server"
    fi

    # Harden SSH configuration
    log "Applying SSH security hardening..."

    # Backup original sshd_config
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d) 2>/dev/null || true

    # Disable root login
    sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config

    # Disable password authentication (key-based only)
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

    # Ensure public key authentication is enabled
    sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

    # Disable empty password login
    sudo sed -i 's/#PermitEmptyPasswords no/PermitEmptyPasswords no/' /etc/ssh/sshd_config
    sudo sed -i 's/PermitEmptyPasswords yes/PermitEmptyPasswords no/' /etc/ssh/sshd_config

    # Disable X11 forwarding (if not needed)
    sudo sed -i 's/X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config

    # Set login grace time
    sudo sed -i 's/#LoginGraceTime 2m/LoginGraceTime 1m/' /etc/ssh/sshd_config

    # Limit concurrent sessions
    sudo sed -i 's/#MaxStartups 10:30:100/MaxStartups 5:30:10/' /etc/ssh/sshd_config

    # Add additional security settings if not present
    sudo grep -q "ClientAliveInterval" /etc/ssh/sshd_config || echo "ClientAliveInterval 300" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    sudo grep -q "ClientAliveCountMax" /etc/ssh/sshd_config || echo "ClientAliveCountMax 2" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    sudo grep -q "Protocol 2" /etc/ssh/sshd_config || echo "Protocol 2" | sudo tee -a /etc/ssh/sshd_config > /dev/null

    # Validate sshd_config before applying
    sudo sshd -t || {
        error "SSH configuration is invalid, rolling back"
        sudo mv /etc/ssh/sshd_config.backup.$(date +%Y%m%d) /etc/ssh/sshd_config
        return 1
    }

    # Restart SSH with new configuration
    sudo systemctl restart ssh || return 1

    log "SSH hardened: Root login disabled, key-based auth only, password auth disabled"
    warning "Ensure you have SSH keys set up before disconnecting!"
    warning "Test SSH access in another terminal before closing this one!"
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

install_nvidia_gpu_support() {
    # Check if NVIDIA GPU is present
    if ! command -v nvidia-smi &> /dev/null; then
        log "No NVIDIA GPU detected or drivers not installed, skipping NVIDIA container toolkit"
        return 0
    fi

    # Check if nvidia-docker is already installed
    if command -v nvidia-docker &> /dev/null; then
        log "NVIDIA container toolkit already installed, skipping"
        return 0
    fi

    # Add NVIDIA repository with secure GPG key handling
    # Validate OS version before using it
    if [ ! -f /etc/os-release ]; then
        error "Cannot determine OS version (/etc/os-release not found)"
        return 1
    fi

    source /etc/os-release || return 1
    if [ -z "$ID" ] || [ -z "$VERSION_ID" ]; then
        error "Failed to determine OS ID or VERSION_ID from /etc/os-release"
        return 1
    fi

    # Whitelist supported distributions
    case "${ID}${VERSION_ID}" in
        ubuntu20.04|ubuntu22.04|ubuntu24.04)
            distribution="${ID}${VERSION_ID}"
            ;;
        *)
            error "Unsupported distribution: ${ID} ${VERSION_ID}"
            return 1
            ;;
    esac

    # Download and verify NVIDIA GPG key with checksum
    local nvidia_gpg_key="/tmp/nvidia-docker.gpg"
    local nvidia_keyring="/etc/apt/keyrings/nvidia-docker.gpg"

    # Download GPG key
    curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey -o "$nvidia_gpg_key" || {
        error "Failed to download NVIDIA GPG key"
        return 1
    }

    # Convert and install GPG key
    sudo gpg --dearmor < "$nvidia_gpg_key" -o "$nvidia_keyring" || {
        error "Failed to process NVIDIA GPG key"
        rm -f "$nvidia_gpg_key"
        return 1
    }

    sudo chmod 644 "$nvidia_keyring"
    rm -f "$nvidia_gpg_key"

    # Add NVIDIA repository with signed-by parameter
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$nvidia_keyring] https://nvidia.github.io/nvidia-docker/$distribution/amd64 /" | \
        sudo tee /etc/apt/sources.list.d/nvidia-docker.list > /dev/null || return 1
    track_repo "/etc/apt/sources.list.d/nvidia-docker.list"

    sudo apt-get update || return 1
    sudo apt-get install -y nvidia-docker2 || return 1
    track_package "nvidia-docker2"

    sudo systemctl restart docker || return 1
    log "NVIDIA container toolkit installed and Docker restarted"
}

install_docker_containers() {
    # Check if docker-compose.yml exists
    if [ ! -f "$(pwd)/docker-compose.yml" ]; then
        error "docker-compose.yml not found in current directory"
        return 1
    fi

    # Start all containers
    log "Starting Docker containers..."
    sudo docker-compose -f "$(pwd)/docker-compose.yml" up -d || return 1
    log "Waiting for services to be ready..."
    sleep 10
}

pull_ollama_models() {
    # Check if Ollama container is running
    if ! sudo docker ps | grep -q ollama; then
        error "Ollama container is not running"
        return 1
    fi

    log "Pulling Ollama models (this may take a while)..."

    local models=("gpt-oss:20b" "qwen3-vl:8b" "qwen3-coder:30b" "qwen3:8b")
    for model in "${models[@]}"; do
        log "Pulling model: $model"
        sudo docker exec ollama ollama pull "$model" || warning "Failed to pull $model, continuing with others..."
    done

    success "Ollama models pulled"
}

install_sqlite() {
    # Check if SQLite is already installed
    if command -v sqlite3 &> /dev/null; then
        log "SQLite already installed ($(sqlite3 --version | head -1)), skipping"
        return 0
    fi

    sudo apt-get install -y sqlite3 || return 1
    track_package "sqlite3"

    # Create SQLite database directory with restrictive permissions
    local DBDIR="$HOME/.local/share/homelab/databases"
    mkdir -p "$DBDIR" || return 1

    # Set restrictive permissions (owner only)
    chmod 700 "$DBDIR" || return 1

    # Create a default .env.local file for database credentials
    cat > "$DBDIR/.env" << 'EOF'
# SQLite Database Credentials
# Place actual passwords here, keep this file secret
SQLITE_BACKUP_ENABLED=true
SQLITE_BACKUP_PATH=$HOME/.local/share/homelab/backups
EOF

    chmod 600 "$DBDIR/.env" || return 1

    log "SQLite database directory created with restricted permissions (700): $DBDIR"
    log "Create backups directory for database backups"
    mkdir -p "$HOME/.local/share/homelab/backups"
    chmod 700 "$HOME/.local/share/homelab/backups"
}

install_utilities() {
    # Install useful utilities if not already present
    sudo apt-get install -y \
        git \
        vim \
        htop \
        tree \
        unzip \
        build-essential \
        net-tools \
        jq || return 1
}

cleanup_system() {
    sudo apt-get autoremove -y || return 1
    sudo apt-get autoclean || return 1
}

# Run installation steps
run_step "System Updates" install_system_updates true
run_step "SSH Server" install_ssh false
run_step "SQLite" install_sqlite false
run_step "Docker Engine" install_docker false
run_step "NVIDIA GPU Support" install_nvidia_gpu_support false
run_step "Docker Containers" install_docker_containers false
run_step "Ollama Models" pull_ollama_models false
run_step "Utility Packages" install_utilities false
run_step "System Cleanup" cleanup_system false

# Final summary
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

echo ""
echo -e "${YELLOW}Service Access:${NC}"
echo "  - Portainer (Container Management): http://<server-ip>:9000"
echo "  - OpenWebUI (Ollama Interface): http://<server-ip>:8080"
echo "  - Ollama API: http://<server-ip>:11434"
echo "  - Qdrant (Vector Database): http://<server-ip>:6333"
echo "  - Qdrant Admin: http://<server-ip>:6334"
echo "  - LangChain: http://<server-ip>:8000"
echo "  - LangGraph: http://<server-ip>:8001"
echo "  - LangFlow: http://<server-ip>:7860"
echo "  - n8n (Workflow Automation): http://<server-ip>:5678"
echo ""
echo -e "${YELLOW}Database Access:${NC}"
echo "  - SQLite: ~/.local/share/homelab/databases/"
echo "  - Qdrant Collections: Via REST API at http://<server-ip>:6333/collections"
echo ""
echo -e "${YELLOW}Important notes:${NC}"
echo "  - Log out and back in for Docker group changes to take effect"
echo "  - SSH is now enabled for remote access"
echo "  - Ollama models are being pulled in the background (may take 1-2 hours)"
echo "  - GPU support requires NVIDIA drivers and docker runtime configuration"
echo "  - Find your server IP with: hostname -I"
echo "  - SQLite databases location: ~/.local/share/homelab/databases/"
echo ""
log "For GPU support, uncomment the runtime: nvidia lines in docker-compose.yml"
log "Consider rebooting your system to ensure all changes take effect."
