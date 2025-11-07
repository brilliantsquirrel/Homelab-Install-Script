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

    # Install standalone docker-compose for backward compatibility
    debug "Installing standalone docker-compose command"

    # Check if docker-compose already exists
    if command -v docker-compose &> /dev/null && docker-compose --version &> /dev/null; then
        log "docker-compose already installed ($(docker-compose --version)), skipping"
    else
        # Download and install docker-compose binary
        local compose_version="v2.24.5"
        local compose_url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)"

        debug "Downloading docker-compose ${compose_version}"
        if sudo curl -L "$compose_url" -o /usr/local/bin/docker-compose; then
            sudo chmod +x /usr/local/bin/docker-compose || return 1

            # Verify installation
            if docker-compose --version &> /dev/null; then
                log "docker-compose installed successfully ($(docker-compose --version))"
            else
                warning "docker-compose installed but verification failed"
            fi
        else
            warning "Failed to download docker-compose, you may need to install it manually"
            warning "Run: sudo apt-get install -y docker-compose"
        fi
    fi

    success "Docker Engine installed"
}

# ========================================
# NVIDIA GPU Support Installation
# ========================================

# Install NVIDIA Docker container toolkit for GPU support
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

# Start Docker containers from docker-compose.yml
install_docker_containers() {
    local compose_file="$(pwd)/docker-compose.yml"

    log "Starting Docker containers..."

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
    if ! sudo docker-compose -f "$compose_file" config > /dev/null 2>&1; then
        error "docker-compose.yml is invalid"
        error "Run the following to see detailed errors:"
        error "  sudo docker-compose -f $compose_file config"
        return 1
    fi
    success "docker-compose.yml is valid"

    # Start all containers
    log "Starting Docker containers..."
    if ! sudo docker-compose -f "$compose_file" up -d; then
        error "Failed to start Docker containers"
        error "Check docker-compose logs for details:"
        error "  sudo docker-compose -f $compose_file logs"
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
    log "Note: Large models (30B) may take 30+ minutes on first pull"

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

    # Get model pull timeout from configuration
    local model_timeout="${MODEL_PULL_TIMEOUT:-7200}"

    debug "Using model pull timeout: $model_timeout seconds ($((model_timeout / 60)) minutes)"

    for model in "${models[@]}"; do
        log "Pulling model: $model (timeout: $((model_timeout / 60)) minutes)"

        # Use timeout command to prevent hanging
        if timeout "$model_timeout" sudo docker exec ollama ollama pull "$model"; then
            success "Successfully pulled: $model"
            successful_models+=("$model")
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                warning "Model pull timed out: $model (exceeded $((model_timeout / 60)) minutes)"
            else
                warning "Failed to pull $model (exit code: $exit_code)"
            fi
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
