#!/bin/bash

# Storage Configuration Module
# Manages custom storage paths for Docker, databases, media, and AI data
# Usage: source lib/base/storage.sh

# ========================================
# Storage Path Configuration
# ========================================

# Prompt for custom storage paths
configure_storage_paths() {
    log "Configuring custom storage paths for optimal performance..."
    echo ""

    # Create storage config file
    local storage_config="$HOME/.homelab-storage.conf"

    # Check if already configured
    if [ -f "$storage_config" ]; then
        log "Storage paths already configured at: $storage_config"
        read -p "Do you want to reconfigure storage paths? (y/N): " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
            log "Using existing storage configuration"
            source "$storage_config"
            return 0
        fi
    fi

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Storage Path Configuration${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "This setup will configure storage paths for different types of data."
    echo "You can use different drives/partitions for optimal performance:"
    echo ""
    echo "  - Fast storage (SSD/NVMe): Databases, caches, AI service data"
    echo "  - Bulk storage (HDD): Media files, user files, backups"
    echo "  - Model storage: AI models (prefer SSD for faster loading)"
    echo "  - Docker storage: Container images and layers"
    echo ""
    echo "Press Enter to use defaults, or specify custom paths."
    echo ""

    # Docker images and container storage
    echo -e "${YELLOW}Docker Images and Container Storage${NC}"
    echo "Default: /var/lib/docker (boot drive)"
    read -p "Docker storage path [/var/lib/docker]: " docker_storage
    DOCKER_STORAGE_PATH="${docker_storage:-/var/lib/docker}"

    # Fast storage (databases and caches)
    echo ""
    echo -e "${YELLOW}Fast Storage (Databases, Redis, Caches)${NC}"
    echo "For: PostgreSQL, Redis, Qdrant, SQLite databases"
    echo "Recommended: SSD or NVMe drive"
    read -p "Fast storage path [/mnt/fast]: " fast_storage
    FAST_STORAGE_PATH="${fast_storage:-/mnt/fast}"

    # AI service data storage
    echo ""
    echo -e "${YELLOW}AI Service Data Storage${NC}"
    echo "For: OpenWebUI, n8n, LangFlow, LangChain, LangGraph data"
    echo "Recommended: SSD for better performance"
    read -p "AI data storage path [/mnt/ai-data]: " ai_storage
    AI_STORAGE_PATH="${ai_storage:-/mnt/ai-data}"

    # Model storage
    echo ""
    echo -e "${YELLOW}AI Model Storage${NC}"
    echo "For: Ollama models (can be 20GB+ per model)"
    echo "Recommended: SSD for faster model loading"
    read -p "Model storage path [/mnt/models]: " model_storage
    MODEL_STORAGE_PATH="${model_storage:-/mnt/models}"

    # Bulk storage (media files)
    echo ""
    echo -e "${YELLOW}Bulk Media Storage${NC}"
    echo "For: Plex media library, video files, music, photos"
    echo "Can use slower HDD storage"
    read -p "Media storage path [/mnt/media]: " media_storage
    MEDIA_STORAGE_PATH="${media_storage:-/mnt/media}"

    # Nextcloud user files
    echo ""
    echo -e "${YELLOW}Nextcloud User Files Storage${NC}"
    echo "For: Nextcloud user data, documents, uploads"
    read -p "Nextcloud storage path [/mnt/nextcloud]: " nextcloud_storage
    NEXTCLOUD_STORAGE_PATH="${nextcloud_storage:-/mnt/nextcloud}"

    # Summary
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Storage Configuration Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Docker storage:     $DOCKER_STORAGE_PATH"
    echo "Fast storage:       $FAST_STORAGE_PATH"
    echo "AI data storage:    $AI_STORAGE_PATH"
    echo "Model storage:      $MODEL_STORAGE_PATH"
    echo "Media storage:      $MEDIA_STORAGE_PATH"
    echo "Nextcloud storage:  $NEXTCLOUD_STORAGE_PATH"
    echo ""

    read -p "Continue with these paths? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        error "Storage configuration cancelled"
        return 1
    fi

    # Validate and create directories
    validate_and_create_storage_paths || return 1

    # Save configuration
    save_storage_config "$storage_config" || return 1

    success "Storage paths configured successfully"
    return 0
}

# Validate storage paths and create directories
validate_and_create_storage_paths() {
    log "Validating and creating storage directories..."

    local paths=(
        "$DOCKER_STORAGE_PATH"
        "$FAST_STORAGE_PATH"
        "$AI_STORAGE_PATH"
        "$MODEL_STORAGE_PATH"
        "$MEDIA_STORAGE_PATH"
        "$NEXTCLOUD_STORAGE_PATH"
    )

    for path in "${paths[@]}"; do
        # Skip /var/lib/docker as it's managed by Docker
        if [ "$path" = "/var/lib/docker" ]; then
            continue
        fi

        # Check if parent directory exists
        local parent_dir=$(dirname "$path")
        if [ ! -d "$parent_dir" ]; then
            warning "Parent directory does not exist: $parent_dir"
            warning "Please ensure the drive is mounted before continuing"
            read -p "Create directory $path anyway? (y/N): " create_anyway
            if [[ ! "$create_anyway" =~ ^[Yy]$ ]]; then
                error "Directory creation cancelled"
                return 1
            fi
        fi

        # Create directory if it doesn't exist
        if [ ! -d "$path" ]; then
            log "Creating directory: $path"
            sudo mkdir -p "$path" || {
                error "Failed to create directory: $path"
                return 1
            }
        fi

        # Check if directory is writable
        if [ ! -w "$path" ]; then
            log "Setting permissions for: $path"
            sudo chown -R $USER:$USER "$path" || {
                warning "Failed to set ownership for: $path"
            }
        fi

        # Verify directory is accessible
        if [ ! -w "$path" ]; then
            error "Directory is not writable: $path"
            return 1
        fi

        log "✓ $path"
    done

    success "All storage directories validated"
    return 0
}

# Save storage configuration to file
save_storage_config() {
    local config_file="$1"

    log "Saving storage configuration to: $config_file"

    cat > "$config_file" << EOF
# Homelab Storage Configuration
# Generated: $(date)
# Do not edit manually unless you know what you're doing

# Docker storage path
export DOCKER_STORAGE_PATH="$DOCKER_STORAGE_PATH"

# Fast storage (databases, caches)
export FAST_STORAGE_PATH="$FAST_STORAGE_PATH"

# AI service data
export AI_STORAGE_PATH="$AI_STORAGE_PATH"

# AI model storage
export MODEL_STORAGE_PATH="$MODEL_STORAGE_PATH"

# Media storage (Plex)
export MEDIA_STORAGE_PATH="$MEDIA_STORAGE_PATH"

# Nextcloud user files
export NEXTCLOUD_STORAGE_PATH="$NEXTCLOUD_STORAGE_PATH"
EOF

    chmod 600 "$config_file"
    log "Storage configuration saved"

    # Source the config
    source "$config_file"

    return 0
}

# Configure Docker daemon to use custom storage path
configure_docker_storage() {
    if [ "$DOCKER_STORAGE_PATH" = "/var/lib/docker" ]; then
        log "Using default Docker storage path"
        return 0
    fi

    log "Configuring Docker to use custom storage path: $DOCKER_STORAGE_PATH"

    local docker_daemon_config="/etc/docker/daemon.json"
    local backup_file="${docker_daemon_config}.backup.$(date +%Y%m%d_%H%M%S)"

    # Backup existing configuration
    if [ -f "$docker_daemon_config" ]; then
        log "Backing up existing Docker daemon config to: $backup_file"
        sudo cp "$docker_daemon_config" "$backup_file"
    fi

    # Create or update daemon.json
    if [ -f "$docker_daemon_config" ]; then
        # Update existing config
        log "Updating existing Docker daemon configuration"
        sudo jq --arg path "$DOCKER_STORAGE_PATH" '.["data-root"] = $path' "$docker_daemon_config" > /tmp/daemon.json
        sudo mv /tmp/daemon.json "$docker_daemon_config"
    else
        # Create new config
        log "Creating new Docker daemon configuration"
        sudo mkdir -p /etc/docker
        echo '{
  "data-root": "'$DOCKER_STORAGE_PATH'"
}' | sudo tee "$docker_daemon_config" > /dev/null
    fi

    # Stop Docker
    log "Stopping Docker to apply storage configuration..."
    sudo systemctl stop docker || {
        warning "Failed to stop Docker gracefully"
    }

    # Move existing Docker data if it exists
    if [ -d "/var/lib/docker" ] && [ "$(sudo ls -A /var/lib/docker 2>/dev/null)" ]; then
        warning "Existing Docker data found at /var/lib/docker"
        read -p "Move existing Docker data to new location? (y/N): " move_data
        if [[ "$move_data" =~ ^[Yy]$ ]]; then
            log "Moving Docker data to $DOCKER_STORAGE_PATH..."
            sudo rsync -av /var/lib/docker/ "$DOCKER_STORAGE_PATH/" || {
                error "Failed to move Docker data"
                return 1
            }
            log "Docker data moved successfully"
        fi
    fi

    # Start Docker
    log "Starting Docker with new storage configuration..."
    sudo systemctl start docker || {
        error "Failed to start Docker"
        error "Restoring backup configuration..."
        if [ -f "$backup_file" ]; then
            sudo cp "$backup_file" "$docker_daemon_config"
            sudo systemctl start docker
        fi
        return 1
    }

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        error "Docker failed to start with new configuration"
        return 1
    fi

    success "Docker configured to use $DOCKER_STORAGE_PATH"
    return 0
}

# Update docker-compose.yml to use custom storage paths
update_docker_compose_storage() {
    local compose_file="docker-compose.yml"
    local compose_override="docker-compose.override.yml"

    log "Creating docker-compose override for custom storage paths..."

    cat > "$compose_override" << EOF
# Docker Compose Override - Custom Storage Paths
# This file overrides volume mounts in docker-compose.yml
# Generated automatically - do not edit manually

services:
  # Ollama - Use custom model storage
  ollama:
    volumes:
      - ${MODEL_STORAGE_PATH}/ollama:/root/.ollama

  # OpenWebUI - AI service data
  openwebui:
    volumes:
      - ${AI_STORAGE_PATH}/openwebui:/app/backend/data

  # LangFlow - AI workflow data
  langflow:
    volumes:
      - ${AI_STORAGE_PATH}/langflow:/root/.langflow

  # n8n - Workflow automation data
  n8n:
    volumes:
      - ${AI_STORAGE_PATH}/n8n:/home/node/.n8n

  # Qdrant - Vector database (fast storage)
  qdrant:
    volumes:
      - ${FAST_STORAGE_PATH}/qdrant:/qdrant/storage
      - ./qdrant_config.yaml:/qdrant/config/config.yaml:ro

  # PostgreSQL databases (fast storage)
  nextcloud-db:
    volumes:
      - ${FAST_STORAGE_PATH}/nextcloud-db:/var/lib/postgresql/data

  langgraph-db:
    volumes:
      - ${FAST_STORAGE_PATH}/langgraph-db:/var/lib/postgresql/data

  # Nextcloud - User files (bulk storage)
  nextcloud:
    volumes:
      - ${NEXTCLOUD_STORAGE_PATH}:/var/www/html

  # Plex - Media files (bulk storage)
  plex:
    volumes:
      - ${AI_STORAGE_PATH}/plex-config:/config
      - ${MEDIA_STORAGE_PATH}:/media
      - ${AI_STORAGE_PATH}/plex-transcode:/transcode

  # Homarr - Dashboard data
  homarr:
    volumes:
      - ${AI_STORAGE_PATH}/homarr-config:/app/data/configs
      - ${AI_STORAGE_PATH}/homarr-icons:/app/public/icons
      - ${AI_STORAGE_PATH}/homarr-data:/data

  # Hoarder - Bookmark data
  hoarder:
    volumes:
      - ${AI_STORAGE_PATH}/hoarder:/data

  # Portainer - Container management data
  portainer:
    volumes:
      - ${AI_STORAGE_PATH}/portainer:/data

  # Pi-Hole - DNS configuration
  pihole:
    volumes:
      - ${AI_STORAGE_PATH}/pihole-etc:/etc/pihole
      - ${AI_STORAGE_PATH}/pihole-dnsmasq:/etc/dnsmasq.d
      - ./pihole-custom-dns.conf:/etc/dnsmasq.d/02-custom-dns.conf:ro
EOF

    success "Docker Compose override created with custom storage paths"
    log "Override file: $compose_override"

    return 0
}

# Create SQLite database directory on fast storage
configure_sqlite_storage() {
    local sqlite_dir="${FAST_STORAGE_PATH}/databases"

    log "Configuring SQLite database storage at: $sqlite_dir"

    mkdir -p "$sqlite_dir" || {
        error "Failed to create SQLite directory"
        return 1
    }

    # Update SQLite init script
    if [ -f "sqlite-ai-init.sh" ]; then
        sed -i "s|~/.local/share/homelab/databases|${sqlite_dir}|g" sqlite-ai-init.sh
    fi

    # Create symlink from default location
    local default_dir="$HOME/.local/share/homelab/databases"
    if [ ! -e "$default_dir" ]; then
        mkdir -p "$(dirname "$default_dir")"
        ln -s "$sqlite_dir" "$default_dir"
        log "Created symlink: $default_dir -> $sqlite_dir"
    fi

    success "SQLite storage configured"
    return 0
}

# Display storage recommendations
display_storage_recommendations() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Storage Recommendations${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${YELLOW}For optimal performance:${NC}"
    echo ""
    echo "1. Fast Storage (SSD/NVMe) - Use for:"
    echo "   • PostgreSQL databases (Nextcloud, LangGraph)"
    echo "   • Redis caches (Nextcloud, LangGraph)"
    echo "   • Qdrant vector database"
    echo "   • SQLite databases"
    echo "   Estimated size: 50-100GB for databases"
    echo ""
    echo "2. AI Data Storage (SSD preferred) - Use for:"
    echo "   • OpenWebUI, n8n, LangFlow, LangChain data"
    echo "   • Plex configuration and transcoding cache"
    echo "   • Portainer, Homarr, Hoarder, Pi-Hole data"
    echo "   Estimated size: 20-50GB"
    echo ""
    echo "3. Model Storage (SSD preferred) - Use for:"
    echo "   • Ollama AI models (20GB+ per large model)"
    echo "   Estimated size: 100-500GB depending on models"
    echo ""
    echo "4. Bulk Storage (HDD acceptable) - Use for:"
    echo "   • Plex media library"
    echo "   • Nextcloud user files"
    echo "   • Backups"
    echo "   Estimated size: Varies (typically 1TB+)"
    echo ""
    echo "5. Docker Storage - Container images and layers:"
    echo "   • Can stay on boot drive or move to SSD"
    echo "   Estimated size: 20-50GB"
    echo ""
    echo -e "${YELLOW}Example setup for Dell PowerEdge R630:${NC}"
    echo "  • Boot drive (SSD): OS + Docker (/var/lib/docker)"
    echo "  • NVMe/SSD 1: Fast storage (/mnt/fast)"
    echo "  • NVMe/SSD 2: AI data + Models (/mnt/ai-data, /mnt/models)"
    echo "  • HDD RAID: Media + Nextcloud (/mnt/media, /mnt/nextcloud)"
    echo ""
}

# Load storage configuration if exists
load_storage_config() {
    local storage_config="$HOME/.homelab-storage.conf"

    if [ -f "$storage_config" ]; then
        source "$storage_config"
        return 0
    fi

    # Set defaults
    export DOCKER_STORAGE_PATH="/var/lib/docker"
    export FAST_STORAGE_PATH="/mnt/fast"
    export AI_STORAGE_PATH="/mnt/ai-data"
    export MODEL_STORAGE_PATH="/mnt/models"
    export MEDIA_STORAGE_PATH="/mnt/media"
    export NEXTCLOUD_STORAGE_PATH="/mnt/nextcloud"

    return 1
}
