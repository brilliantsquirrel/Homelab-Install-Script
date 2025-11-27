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
        warning "nvidia-smi command exists but failed to run"
        log "Running diagnostics to identify the issue..."

        # Diagnostic 1: Check if NVIDIA kernel module is loaded
        local nvidia_module_loaded=false
        if lsmod | grep -q "^nvidia"; then
            nvidia_module_loaded=true
            log "  ✓ NVIDIA kernel module is loaded"
        else
            warning "  ✗ NVIDIA kernel module is NOT loaded"
        fi

        # Diagnostic 2: Check Secure Boot status
        local secure_boot_enabled=false
        if command -v mokutil &> /dev/null; then
            if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
                secure_boot_enabled=true
                warning "  ⚠ Secure Boot is ENABLED"
                warning "    Secure Boot can block loading unsigned NVIDIA kernel modules"
            else
                log "  ✓ Secure Boot is disabled or not applicable"
            fi
        else
            log "  - mokutil not available (cannot check Secure Boot status)"
        fi

        # Diagnostic 3: Check dmesg for NVIDIA errors
        local dmesg_errors=$(dmesg 2>/dev/null | grep -i nvidia | grep -iE "(error|fail|unable)" | tail -5)
        if [ -n "$dmesg_errors" ]; then
            warning "  NVIDIA errors in dmesg:"
            echo "$dmesg_errors" | while read line; do
                echo "    $line"
            done
        fi

        # Diagnostic 4: Check installed NVIDIA packages
        local nvidia_packages=$(dpkg -l | grep -i nvidia | grep "^ii" | awk '{print $2}' | head -10)
        if [ -n "$nvidia_packages" ]; then
            log "  Installed NVIDIA packages:"
            echo "$nvidia_packages" | while read pkg; do
                echo "    - $pkg"
            done
        fi

        # Diagnostic 5: Check kernel version vs DKMS
        local running_kernel=$(uname -r)
        log "  Running kernel: $running_kernel"

        # Recovery attempt 1: Try to load NVIDIA module manually
        if [ "$nvidia_module_loaded" = false ]; then
            log "Attempting to load NVIDIA kernel module..."
            if sudo modprobe nvidia 2>/dev/null; then
                success "  ✓ Successfully loaded nvidia module"
                # Try nvidia-smi again
                if nvidia-smi &> /dev/null; then
                    success "nvidia-smi now works after loading module"
                else
                    warning "  Module loaded but nvidia-smi still fails"
                fi
            else
                warning "  ✗ Failed to load nvidia module"
            fi
        fi

        # Recovery attempt 2: Rebuild DKMS modules (only if nvidia-smi still fails)
        if ! nvidia-smi &> /dev/null && command -v dkms &> /dev/null; then
            log "Checking DKMS status for NVIDIA modules..."
            local dkms_status=$(dkms status 2>/dev/null | grep -i nvidia)
            if [ -n "$dkms_status" ]; then
                log "  DKMS status: $dkms_status"

                # Check if module needs rebuilding for current kernel
                if ! echo "$dkms_status" | grep -q "$running_kernel"; then
                    log "Attempting to rebuild NVIDIA DKMS modules for kernel $running_kernel..."

                    # Get nvidia-dkms version
                    local nvidia_dkms_version=$(echo "$dkms_status" | head -1 | grep -oP '\d+\.\d+(\.\d+)?')
                    if [ -n "$nvidia_dkms_version" ]; then
                        if sudo dkms install nvidia/"$nvidia_dkms_version" -k "$running_kernel" 2>/dev/null; then
                            success "  ✓ DKMS rebuild successful"

                            # Try loading module again
                            sudo modprobe nvidia 2>/dev/null
                            if nvidia-smi &> /dev/null; then
                                success "nvidia-smi now works after DKMS rebuild!"
                            fi
                        else
                            warning "  ✗ DKMS rebuild failed"
                        fi
                    fi
                fi
            fi
        fi

        # If we still can't get nvidia-smi working, provide detailed guidance
        if ! nvidia-smi &> /dev/null; then
            echo ""
            error "Could not get NVIDIA drivers working. Recommended actions:"
            echo ""

            if [ "$secure_boot_enabled" = true ]; then
                error "  OPTION 1 - Disable Secure Boot (recommended):"
                error "    1. Reboot and enter BIOS/UEFI settings"
                error "    2. Find 'Secure Boot' option and disable it"
                error "    3. Save and exit, then re-run this script"
                echo ""
                error "  OPTION 2 - Sign the NVIDIA module (advanced):"
                error "    1. Run: sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"
                error "    2. Reboot and enroll the MOK key when prompted"
                error "    3. Re-run this script"
            else
                error "  OPTION 1 - Reinstall NVIDIA drivers:"
                error "    sudo apt-get purge 'nvidia-*'"
                error "    sudo apt-get autoremove"
                error "    sudo ubuntu-drivers autoinstall"
                error "    sudo reboot"
                echo ""
                error "  OPTION 2 - Install specific driver version:"
                error "    sudo apt-get install nvidia-driver-535"
                error "    sudo reboot"
            fi

            echo ""
            warning "Continuing without GPU support. You can fix this later and re-run the script."
            warning "GPU-dependent containers (Ollama, Plex transcoding) will use CPU only."
            return 1
        fi
    fi

    # Display GPU information
    log "NVIDIA GPU Information:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | while read line; do
        log "  $line"
    done

    # Check if nvidia-container-toolkit is already installed
    if dpkg -l | grep -q nvidia-container-toolkit; then
        log "NVIDIA container toolkit already installed, skipping"
        return 0
    fi

    log "Installing NVIDIA container toolkit..."

    # Validate OS version
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

    # Extract major version for compatibility check
    local major_version="${VERSION_ID%%.*}"

    # Check minimum supported version
    if [ "$major_version" -lt 20 ]; then
        error "Unsupported ${ID} version: ${VERSION_ID} (minimum 20.04)"
        return 1
    fi

    log "Installing NVIDIA Container Toolkit for ${ID} ${VERSION_ID}..."

    # Use the new NVIDIA Container Toolkit repository (supports Ubuntu 24.04)
    # Reference: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
    local nvidia_gpg_key="/tmp/nvidia-container-toolkit.gpg"
    local nvidia_keyring="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"

    debug "Downloading NVIDIA Container Toolkit GPG key"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --dearmor -o "$nvidia_keyring" || {
        error "Failed to download/process NVIDIA GPG key"
        return 1
    }
    sudo chmod 644 "$nvidia_keyring"

    debug "Adding NVIDIA Container Toolkit repository"
    # Use the stable repository which supports all recent Ubuntu versions
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null || {
        error "Failed to add NVIDIA repository"
        return 1
    }
    track_repo "/etc/apt/sources.list.d/nvidia-container-toolkit.list"

    debug "Installing nvidia-container-toolkit"
    sudo apt-get update || return 1
    sudo apt-get install -y nvidia-container-toolkit || return 1
    track_package "nvidia-container-toolkit"

    debug "Configuring Docker to use NVIDIA runtime"
    sudo nvidia-ctk runtime configure --runtime=docker || {
        warning "Failed to configure Docker runtime automatically"
        warning "You may need to manually add NVIDIA runtime to /etc/docker/daemon.json"
    }

    debug "Restarting Docker service"
    sudo systemctl restart docker || return 1
    log "NVIDIA container toolkit installed and Docker configured"

    # Verify installation
    if sudo docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi &>/dev/null; then
        success "NVIDIA GPU support installed and verified"
    else
        warning "NVIDIA container toolkit installed but GPU test container failed"
        warning "This may be normal if CUDA images need to be pulled first"
        success "NVIDIA GPU support installed (verification skipped)"
    fi
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

# Pull a single Docker image with retry logic
pull_docker_image_with_retry() {
    local image="$1"
    local max_retries=3
    local retry_delay=10
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        log "Pulling image: $image (attempt $attempt/$max_retries)"

        if sudo docker pull "$image"; then
            success "Successfully pulled: $image"
            return 0
        else
            if [ $attempt -lt $max_retries ]; then
                warning "Failed to pull $image (attempt $attempt/$max_retries)"
                log "Waiting ${retry_delay}s before retry..."
                sleep $retry_delay
                ((retry_delay *= 2))  # Exponential backoff
            else
                error "Failed to pull $image after $max_retries attempts"
                return 1
            fi
        fi

        ((attempt++))
    done

    return 1
}

# Pre-pull all Docker images sequentially
prepull_docker_images() {
    log "Pre-pulling Docker images (one at a time to handle slow connections)..."
    echo ""

    # Extract unique images from docker-compose.yml
    local images=($(grep -E '^\s+image:' docker-compose.yml | awk '{print $2}' | sort -u))

    log "Found ${#images[@]} unique images to download"
    echo ""

    local failed_images=()
    local successful_images=()

    for image in "${images[@]}"; do
        if pull_docker_image_with_retry "$image"; then
            successful_images+=("$image")
        else
            failed_images+=("$image")
        fi
    done

    # Summary
    echo ""
    log "Image pull summary:"
    log "  Successful: ${#successful_images[@]}/${#images[@]} images"

    if [ ${#failed_images[@]} -gt 0 ]; then
        warning "  Failed: ${#failed_images[@]} images"
        for image in "${failed_images[@]}"; do
            echo "    ✗ $image"
        done
        echo ""
        warning "Some images failed to download. Docker Compose will attempt to use existing images or retry."
        warning "If containers fail to start, you can manually pull failed images:"
        for image in "${failed_images[@]}"; do
            echo "    sudo docker pull $image"
        done
        echo ""
    fi

    return 0
}

# Start Docker containers from docker-compose.yml
install_docker_containers() {
    local compose_file="$(pwd)/docker-compose.yml"
    local max_retries=3
    local retry_count=0

    log "Starting Docker containers..."

    # Check if running in offline mode
    if [ "${OFFLINE_MODE:-false}" = "true" ]; then
        log "OFFLINE_MODE detected - using pre-loaded Docker images"
    else
        log "Online mode - will pull images sequentially"
        # Pre-pull images one at a time to handle slow/unreliable connections
        prepull_docker_images
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
    # Use --env-file to ensure .env is loaded (sudo doesn't inherit environment variables)
    local env_file="$(pwd)/.env"
    local compose_cmd="sudo docker compose -f $compose_file"
    if [ -f "$env_file" ]; then
        compose_cmd="sudo docker compose --env-file $env_file -f $compose_file"
    fi
    if ! $compose_cmd config > /dev/null 2>&1; then
        error "docker-compose.yml is invalid"
        error "Run the following to see detailed errors:"
        error "  $compose_cmd config"
        return 1
    fi
    success "docker-compose.yml is valid"

    # Start all containers with retry logic
    log "Starting Docker containers..."
    while [ $retry_count -lt $max_retries ]; do
        if $compose_cmd up -d; then
            debug "Waiting for services to be ready..."
            sleep "${DOCKER_STARTUP_WAIT:-10}"
            success "Docker containers started successfully"
            return 0
        else
            ((retry_count++))
            if [ $retry_count -lt $max_retries ]; then
                warning "Failed to start containers (attempt $retry_count/$max_retries)"
                log "Waiting 10s before retry..."
                sleep 10
            else
                error "Failed to start Docker containers after $max_retries attempts"
                error "Check logs for details:"
                error "  $compose_cmd logs"
                return 1
            fi
        fi
    done

    return 1
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

    # Verify model storage location
    local model_storage=$(sudo docker inspect ollama 2>/dev/null | grep -A1 '"Destination": "/root/.ollama"' | grep "Source" | grep -oP '(?<="Source": ")[^"]+' || echo "")
    if [ -n "$model_storage" ]; then
        log "Ollama models will be stored at: $model_storage"
        log "This location is on your configured model storage drive"
        log "Models will persist across OS reinstalls"
    else
        # Check via docker volume or bind mount
        model_storage=$(sudo docker inspect ollama --format '{{range .Mounts}}{{if eq .Destination "/root/.ollama"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || echo "")
        if [ -n "$model_storage" ]; then
            log "Ollama models will be stored at: $model_storage"
        fi
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
