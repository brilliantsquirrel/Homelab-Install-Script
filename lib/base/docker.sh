#!/bin/bash

# Docker Module - Docker Engine, containers, and GPU support
# Usage: source lib/base/docker.sh
# Provides: install_docker, install_nvidia_gpu_support, install_docker_containers, pull_ollama_models

# ========================================
# Docker Engine Installation
# ========================================

# Install Docker Engine from official repository
install_docker() {
    # Check if Docker is already installed
    if command -v docker &> /dev/null && docker --version &> /dev/null; then
        log "Docker already installed ($(docker --version)), skipping"
        # Still ensure user is in docker group
        sudo usermod -aG docker $USER 2>/dev/null || true
        return 0
    fi

    debug "Installing Docker Engine"

    # Remove old versions if they exist (ignore if not present)
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    debug "Installing Docker prerequisites"
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release || return 1

    # Add Docker's official GPG key
    debug "Adding Docker GPG key"
    sudo mkdir -p /etc/apt/keyrings || return 1
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || return 1

    # Set up the repository
    debug "Setting up Docker repository"
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || return 1
    track_repo "/etc/apt/sources.list.d/docker.list"

    # Install Docker Engine
    debug "Installing Docker Engine packages"
    sudo apt-get update || return 1
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    track_package "docker-ce"

    # Add user to docker group (non-critical, ignore if already in group)
    sudo usermod -aG docker $USER 2>/dev/null || true
    log "You'll need to log out and back in for Docker group changes to take effect."

    success "Docker Engine installed (includes docker-compose-plugin)"
}

# ========================================
# NVIDIA GPU Support Installation
# ========================================

# Install NVIDIA Docker container toolkit for GPU support
install_nvidia_gpu_support() {
    log "Checking for NVIDIA GPU..."

    # Check if NVIDIA GPU hardware is present
    local has_nvidia_gpu=false

    # Method 1: Check PCI devices
    if command -v lspci &> /dev/null; then
        if lspci | grep -i nvidia &> /dev/null; then
            has_nvidia_gpu=true
            log "NVIDIA GPU detected via lspci"
        fi
    fi

    # Method 2: Check for NVIDIA vendor ID in sysfs
    if [ "$has_nvidia_gpu" = false ]; then
        if grep -r "0x10de" /sys/class/drm/card*/device/vendor 2>/dev/null | grep -q "0x10de"; then
            has_nvidia_gpu=true
            log "NVIDIA GPU detected via sysfs"
        fi
    fi

    # Method 3: Check if nvidia-smi works (drivers already installed)
    if [ "$has_nvidia_gpu" = false ]; then
        if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
            has_nvidia_gpu=true
            log "NVIDIA GPU detected via nvidia-smi"
        fi
    fi

    if [ "$has_nvidia_gpu" = false ]; then
        log "No NVIDIA GPU detected, skipping NVIDIA support"
        return 0
    fi

    success "✓ NVIDIA GPU hardware detected"

    # Check if NVIDIA drivers are installed
    if ! command -v nvidia-smi &> /dev/null; then
        warning "NVIDIA GPU found but drivers not installed"
        log "Installing NVIDIA drivers..."

        # Install pciutils if not present (for GPU detection)
        if ! command -v lspci &> /dev/null; then
            sudo apt-get install -y pciutils || true
        fi

        # Detect recommended driver version
        log "Detecting recommended NVIDIA driver..."
        sudo apt-get update || return 1

        # Install ubuntu-drivers-common to detect recommended driver
        sudo apt-get install -y ubuntu-drivers-common || {
            warning "Could not install ubuntu-drivers-common, trying manual driver installation"
        }

        # Get recommended driver
        local recommended_driver=""
        if command -v ubuntu-drivers &> /dev/null; then
            recommended_driver=$(ubuntu-drivers devices 2>/dev/null | grep recommended | awk '{print $3}' | head -1)
        fi

        if [ -n "$recommended_driver" ]; then
            log "Installing recommended driver: $recommended_driver"
            sudo apt-get install -y "$recommended_driver" || {
                error "Failed to install $recommended_driver"
                return 1
            }
        else
            # Fallback to latest driver metapackage
            log "Installing nvidia-driver-535 (fallback)"
            sudo apt-get install -y nvidia-driver-535 || {
                error "Failed to install NVIDIA driver"
                warning "You may need to install drivers manually:"
                warning "  sudo ubuntu-drivers autoinstall"
                return 1
            }
        fi

        success "✓ NVIDIA drivers installed"
        warning "⚠️  REBOOT REQUIRED for NVIDIA drivers to take effect"
        warning "After reboot, re-run this script to complete GPU setup"

        # Track for rollback
        track_package "$recommended_driver"

        return 0
    fi

    # Verify nvidia-smi works
    if ! nvidia-smi &> /dev/null; then
        error "nvidia-smi command exists but failed to run"
        error "This usually means:"
        error "  1. NVIDIA drivers were just installed and system needs reboot"
        error "  2. Driver/kernel version mismatch"
        warning "Try rebooting the system and re-running this script"
        return 1
    fi

    # Display GPU information
    log "NVIDIA GPU Information:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | while read line; do
        log "  $line"
    done

    # Check if nvidia-docker is already installed
    if command -v nvidia-docker &> /dev/null; then
        log "NVIDIA container toolkit already installed, skipping"
        return 0
    fi

    log "Installing NVIDIA container toolkit..."

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

    debug "Detected OS: $ID $VERSION_ID"

    # Support Ubuntu and Debian distributions with version check
    local distribution=""
    case "$ID" in
        ubuntu|debian)
            # Extract major version for compatibility check
            local major_version="${VERSION_ID%%.*}"

            # Check minimum supported version
            if [ "$major_version" -lt 20 ]; then
                error "Unsupported ${ID} version: ${VERSION_ID} (minimum 20.04)"
                return 1
            fi

            # Construct distribution string
            distribution="${ID}${major_version}"
            log "Using distribution: $distribution (${ID} ${VERSION_ID})"
            ;;
        *)
            warning "Distribution ${ID} ${VERSION_ID} is not officially tested"
            warning "Attempting to install NVIDIA docker anyway (may fail)"
            distribution="${ID}${VERSION_ID}"
            ;;
    esac

    if [ -z "$distribution" ]; then
        error "Failed to determine distribution string"
        return 1
    fi

    # Download and verify NVIDIA GPG key with checksum
    local nvidia_gpg_key="/tmp/nvidia-docker.gpg"
    local nvidia_keyring="/etc/apt/keyrings/nvidia-docker.gpg"

    debug "Downloading NVIDIA GPG key"
    # Download GPG key
    curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey -o "$nvidia_gpg_key" || {
        error "Failed to download NVIDIA GPG key"
        return 1
    }

    debug "Processing NVIDIA GPG key"
    # Convert and install GPG key
    sudo gpg --dearmor < "$nvidia_gpg_key" -o "$nvidia_keyring" || {
        error "Failed to process NVIDIA GPG key"
        rm -f "$nvidia_gpg_key"
        return 1
    }

    sudo chmod 644 "$nvidia_keyring"
    rm -f "$nvidia_gpg_key"

    debug "Adding NVIDIA repository"
    # Add NVIDIA repository with signed-by parameter
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$nvidia_keyring] https://nvidia.github.io/nvidia-docker/$distribution/amd64 /" | \
        sudo tee /etc/apt/sources.list.d/nvidia-docker.list > /dev/null || return 1
    track_repo "/etc/apt/sources.list.d/nvidia-docker.list"

    debug "Installing nvidia-docker2"
    sudo apt-get update || return 1
    sudo apt-get install -y nvidia-docker2 || return 1
    track_package "nvidia-docker2"

    debug "Restarting Docker service"
    sudo systemctl restart docker || return 1
    log "NVIDIA container toolkit installed and Docker restarted"

    success "NVIDIA GPU support installed"
}

# ========================================
# Pi-Hole Custom DNS Configuration
# ========================================

# Generate Pi-Hole custom DNS configuration with actual server IP
configure_pihole_dns() {
    log "Configuring Pi-Hole custom DNS entries..."

    local template_file="$(pwd)/pihole-custom-dns.conf"

    # Check if template exists
    if [ ! -f "$template_file" ]; then
        warning "pihole-custom-dns.conf template not found, skipping custom DNS setup"
        return 0
    fi

    # Detect server IP address
    # Try multiple methods to get the most reliable IP
    local server_ip=""

    # Method 1: hostname -I (gets all IPs, we take the first non-loopback)
    if command -v hostname &> /dev/null; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # Method 2: ip route (fallback)
    if [ -z "$server_ip" ] && command -v ip &> /dev/null; then
        server_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+')
    fi

    # Method 3: Check for SERVER_IP environment variable
    if [ -z "$server_ip" ] && [ -n "$SERVER_IP" ]; then
        server_ip="$SERVER_IP"
    fi

    # Validate we got an IP
    if [ -z "$server_ip" ]; then
        warning "Could not detect server IP address"
        warning "Pi-Hole custom DNS will not be configured"
        warning "You can manually edit pihole-custom-dns.conf and restart Pi-Hole"
        return 0
    fi

    # Validate IP format (basic check)
    if ! [[ "$server_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        warning "Detected IP address appears invalid: $server_ip"
        warning "Skipping custom DNS configuration"
        return 0
    fi

    log "Detected server IP: $server_ip"

    # Check if already configured (avoid rewriting on reruns)
    if grep -q "address=.*/${server_ip}" "$template_file" 2>/dev/null; then
        log "Pi-Hole DNS already configured with IP $server_ip"
        return 0
    fi

    # Replace placeholder with actual IP
    debug "Updating DNS configuration with server IP..."
    if sed -i "s/SERVER_IP_PLACEHOLDER/${server_ip}/g" "$template_file"; then
        success "Pi-Hole custom DNS configured for $server_ip"
        log "Services will be accessible via:"
        log "  - homarr.home, plex.home, nextcloud.home, etc."
    else
        warning "Failed to update DNS configuration file"
        return 0
    fi
}

# ========================================
# Docker Containers
# ========================================

# Disable systemd-resolved DNS stub listener for Pi-Hole
disable_systemd_resolved_stub() {
    log "Checking if port 53 is available for Pi-Hole..."

    # Check if port 53 is in use
    if sudo lsof -i :53 >/dev/null 2>&1; then
        local process=$(sudo lsof -i :53 | tail -n +2 | awk '{print $1}' | head -1)

        if [[ "$process" == "systemd-r"* ]]; then
            warning "systemd-resolved is using port 53, which Pi-Hole needs"
            log "Disabling systemd-resolved DNS stub listener..."

            # Backup resolved.conf
            if [ ! -f /etc/systemd/resolved.conf.backup ]; then
                sudo cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup
                log "Backed up /etc/systemd/resolved.conf"
            fi

            # Disable DNS stub listener
            sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
            sudo sed -i 's/DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf

            # Restart systemd-resolved
            log "Restarting systemd-resolved..."
            sudo systemctl restart systemd-resolved || true

            # Remove symlink and create regular file for resolv.conf
            if [ -L /etc/resolv.conf ]; then
                sudo rm /etc/resolv.conf
                echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
                echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf > /dev/null
            fi

            success "✓ Disabled systemd-resolved DNS stub listener"
            log "Port 53 is now available for Pi-Hole"
        else
            warning "Port 53 is in use by: $process"
            warning "Pi-Hole may fail to start. Please manually stop $process"
        fi
    else
        success "✓ Port 53 is available"
    fi
}

# Start Docker containers from docker-compose.yml
install_docker_containers() {
    local compose_file="$(pwd)/docker-compose.yml"

    log "Starting Docker containers..."

    # Check if running in offline mode
    if [ "${OFFLINE_MODE:-false}" = "true" ]; then
        log "OFFLINE_MODE detected - using pre-loaded Docker images"
    else
        log "Online mode - Docker will pull images as needed"
    fi

    # Disable systemd-resolved stub listener before starting Pi-Hole
    disable_systemd_resolved_stub

    # Validate docker-compose.yml exists
    if [ ! -f "$compose_file" ]; then
        error "docker-compose.yml not found in current directory: $(pwd)"
        error "Make sure you run this script from the homelab repository directory"
        return 1
    fi

    debug "Found docker-compose.yml at: $compose_file"

    # Validate docker-compose.yml is readable
    if [ ! -r "$compose_file" ]; then
        error "docker-compose.yml is not readable: $compose_file"
        error "Check file permissions: ls -la $compose_file"
        return 1
    fi

    # Validate docker-compose.yml syntax
    log "Validating docker-compose.yml syntax..."
    if ! sudo docker compose -f "$compose_file" config > /dev/null 2>&1; then
        error "docker-compose.yml is invalid"
        error "Run the following to see detailed errors:"
        error "  sudo docker compose -f $compose_file config"
        return 1
    fi
    success "docker-compose.yml is valid"

    # Start all containers
    log "Starting Docker containers..."
    if ! sudo docker compose -f "$compose_file" up -d; then
        error "Failed to start Docker containers"
        error "Check logs for details:"
        error "  sudo docker compose -f $compose_file logs"
        return 1
    fi

    debug "Waiting for services to be ready..."
    sleep "${DOCKER_STARTUP_WAIT:-10}"

    success "Docker containers started successfully"
}

# ========================================
# Ollama Model Pulling
# ========================================

# Pull Ollama LLM models into the Ollama container
pull_ollama_models() {
    log "Preparing to pull Ollama models..."

    # Check if running in offline mode
    if [ "${OFFLINE_MODE:-false}" = "true" ]; then
        log "OFFLINE_MODE detected - skipping model download"
        log "Models should be loaded using: /opt/homelab-offline/scripts/load-ollama-models.sh"
        return 0
    fi

    # Check if Ollama container is running
    if ! sudo docker ps | grep -q ollama; then
        error "Ollama container is not running"
        return 1
    fi

    debug "Ollama container is running"

    # Verify ollama command is available in container
    if ! sudo docker exec ollama ollama --version &>/dev/null; then
        error "Ollama command not available in container"
        return 1
    fi

    log "Pulling Ollama models (this may take a while)..."
    log "Note: Large models (30B) may take 30+ minutes to several hours depending on network speed"

    # Get models from configuration
    local models=()
    if declare -p OLLAMA_MODELS 2>/dev/null | grep -q "^declare -a"; then
        models=("${OLLAMA_MODELS[@]}")
    else
        # Fallback to hardcoded list if config not loaded
        models=("gpt-oss:20b" "qwen3-vl:8b" "qwen3-coder:30b" "qwen3:8b")
    fi

    local successful_models=()
    local failed_models=()

    for model in "${models[@]}"; do
        log "Pulling model: $model (no timeout - may take a long time for large models)"

        # Pull model without timeout to allow large models to download fully
        if sudo docker exec ollama ollama pull "$model"; then
            success "Successfully pulled: $model"
            successful_models+=("$model")
        else
            local exit_code=$?
            warning "Failed to pull $model (exit code: $exit_code)"
            failed_models+=("$model")
        fi
    done

    # Summary
    echo ""
    log "Ollama model pull summary:"
    log "  Successful: ${#successful_models[@]} models"
    for model in "${successful_models[@]}"; do
        echo "    ✓ $model"
    done

    if [ ${#failed_models[@]} -gt 0 ]; then
        warning "  Failed: ${#failed_models[@]} models"
        for model in "${failed_models[@]}"; do
            echo "    ✗ $model"
        done
        warning "You can retry pulling failed models manually:"
        for model in "${failed_models[@]}"; do
            echo "    sudo docker exec ollama ollama pull $model"
        done
    fi

    return 0
}
