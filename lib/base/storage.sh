#!/bin/bash

# Storage Configuration Module - Auto-Partitioning Edition
# Detects drives, creates partitions, and configures storage tiers
# Usage: source lib/base/storage.sh

# ========================================
# Drive Detection
# ========================================

# Detect all available non-boot drives
detect_available_drives() {
    log "Detecting available storage drives..."

    # Get boot drive
    local boot_drive=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /))
    log "Boot drive detected: $boot_drive"

    # Get all block devices excluding boot drive, loop devices, and partitions
    AVAILABLE_DRIVES=()
    while IFS= read -r line; do
        local drive=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local type=$(echo "$line" | awk '{print $3}')

        # Skip if it's the boot drive
        if [ "$drive" = "$boot_drive" ]; then
            continue
        fi

        AVAILABLE_DRIVES+=("$drive|$size|$type")
    done < <(lsblk -d -n -o NAME,SIZE,ROTA | grep -v "^loop\|^sr")

    if [ ${#AVAILABLE_DRIVES[@]} -eq 0 ]; then
        warning "No additional drives detected (only boot drive found)"
        return 1
    fi

    success "Detected ${#AVAILABLE_DRIVES[@]} available drive(s) for storage"
    return 0
}

# Display drive information in a user-friendly format
display_drive_info() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Available Storage Drives${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    local index=1
    for drive_info in "${AVAILABLE_DRIVES[@]}"; do
        local drive=$(echo "$drive_info" | cut -d'|' -f1)
        local size=$(echo "$drive_info" | cut -d'|' -f2)
        local rota=$(echo "$drive_info" | cut -d'|' -f3)

        # Determine drive type (0=SSD/NVMe, 1=HDD)
        local drive_type="SSD/NVMe"
        if [ "$rota" = "1" ]; then
            drive_type="HDD"
        fi

        # Get drive model if available
        local model=$(lsblk -d -n -o MODEL /dev/$drive 2>/dev/null || echo "Unknown")

        echo "[$index] /dev/$drive - $size ($drive_type)"
        echo "    Model: $model"

        # Show existing partitions if any
        local partitions=$(lsblk -n -o NAME /dev/$drive | tail -n +2)
        if [ -n "$partitions" ]; then
            echo "    Existing partitions:"
            while IFS= read -r part; do
                local part_size=$(lsblk -n -o SIZE /dev/$part 2>/dev/null)
                local part_mount=$(lsblk -n -o MOUNTPOINT /dev/$part 2>/dev/null)
                if [ -n "$part_mount" ]; then
                    echo "      - $part ($part_size) mounted at $part_mount"
                else
                    echo "      - $part ($part_size) not mounted"
                fi
            done <<< "$partitions"
        else
            echo "    No partitions (empty drive)"
        fi
        echo ""

        ((index++))
    done
}

# ========================================
# Storage Tier Configuration
# ========================================

# Configure storage tiers with automatic partitioning
configure_storage_tiers() {
    log "Configuring storage tiers with automatic partitioning..."
    echo ""

    # Detect available drives
    if ! detect_available_drives; then
        warning "No additional drives available"
        warning "All data will be stored on boot drive (not recommended for production)"
        read -p "Continue with boot drive only? (y/N): " use_boot_only
        if [[ ! "$use_boot_only" =~ ^[Yy]$ ]]; then
            error "Storage configuration cancelled"
            return 1
        fi
        configure_boot_drive_only
        return 0
    fi

    # Display drive information
    display_drive_info

    echo -e "${YELLOW}Storage Tier Setup${NC}"
    echo ""
    echo "You will configure 4 storage tiers:"
    echo "  a. Fast Storage (databases, caches) - Recommended: SSD/NVMe, Default: 100GB"
    echo "  b. AI Service Data (app data) - Recommended: SSD, Default: 50GB"
    echo "  c. Model Storage (AI models) - Recommended: SSD, Default: 500GB"
    echo "  d. Bulk Storage (media, files, docker) - Acceptable: HDD, Default: remaining space"
    echo ""
    echo "For each tier, you'll select a drive and partition size."
    echo ""

    read -p "Continue with automatic partitioning? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        error "Storage configuration cancelled"
        return 1
    fi

    # Configure each tier
    configure_tier_a_fast_storage || return 1
    configure_tier_b_ai_data || return 1
    configure_tier_c_model_storage || return 1
    configure_tier_d_bulk_storage || return 1

    # Display configuration summary
    display_storage_summary

    read -p "Proceed with creating partitions? (y/N): " final_confirm
    if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
        error "Partition creation cancelled"
        return 1
    fi

    # Create all partitions and mount them
    create_all_partitions || return 1

    # Save configuration
    save_storage_config "$HOME/.homelab-storage.conf" || return 1

    success "Storage tiers configured successfully"
    return 0
}

# Configure Tier A: Fast Storage
configure_tier_a_fast_storage() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Tier A: Fast Storage${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Purpose: High-performance databases and caches"
    echo "Services: PostgreSQL (Nextcloud, LangGraph), Redis, Qdrant, SQLite"
    echo "Recommended: SSD or NVMe"
    echo "Default Size: 100GB"
    echo ""

    select_drive_and_size "Fast Storage" "100" "TIER_A"
    TIER_A_MOUNT="/mnt/fast"
}

# Configure Tier B: AI Service Data
configure_tier_b_ai_data() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Tier B: AI Service Data Storage${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Purpose: AI application data and configurations"
    echo "Services: OpenWebUI, n8n, LangFlow, LangChain, Plex config,"
    echo "          Portainer, Homarr, Hoarder, Pi-Hole"
    echo "Recommended: SSD for better performance"
    echo "Default Size: 50GB"
    echo ""

    select_drive_and_size "AI Service Data" "50" "TIER_B"
    TIER_B_MOUNT="/mnt/ai-data"
}

# Configure Tier C: Model Storage
configure_tier_c_model_storage() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Tier C: AI Model Storage${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Purpose: Large AI model files (20GB+ per model)"
    echo "Services: Ollama models"
    echo "Recommended: SSD for faster model loading"
    echo "Default Size: 500GB"
    echo ""

    select_drive_and_size "Model Storage" "500" "TIER_C"
    TIER_C_MOUNT="/mnt/models"
}

# Configure Tier D: Bulk Storage
configure_tier_d_bulk_storage() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Tier D: Bulk Storage${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Purpose: Large media files, user data, Docker images"
    echo "Services: Plex media, Nextcloud files, Docker storage"
    echo "Acceptable: HDD (slower storage is fine)"
    echo "Default Size: Use remaining space on drive"
    echo ""

    select_drive_and_size "Bulk Storage" "remaining" "TIER_D"
    TIER_D_MOUNT="/mnt/bulk"
}

# Select drive and partition size for a tier
select_drive_and_size() {
    local tier_name="$1"
    local default_size="$2"
    local tier_var_prefix="$3"

    # Select drive
    echo "Select drive for $tier_name:"
    for i in "${!AVAILABLE_DRIVES[@]}"; do
        local drive_info="${AVAILABLE_DRIVES[$i]}"
        local drive=$(echo "$drive_info" | cut -d'|' -f1)
        local size=$(echo "$drive_info" | cut -d'|' -f2)
        local rota=$(echo "$drive_info" | cut -d'|' -f3)
        local drive_type="SSD/NVMe"
        [ "$rota" = "1" ] && drive_type="HDD"

        echo "  [$((i+1))] /dev/$drive - $size ($drive_type)"
    done

    local drive_selection
    while true; do
        read -p "Enter drive number [1-${#AVAILABLE_DRIVES[@]}]: " drive_selection
        if [[ "$drive_selection" =~ ^[0-9]+$ ]] && [ "$drive_selection" -ge 1 ] && [ "$drive_selection" -le "${#AVAILABLE_DRIVES[@]}" ]; then
            break
        fi
        echo "Invalid selection. Please enter a number between 1 and ${#AVAILABLE_DRIVES[@]}"
    done

    local selected_drive_info="${AVAILABLE_DRIVES[$((drive_selection-1))]}"
    local selected_drive=$(echo "$selected_drive_info" | cut -d'|' -f1)

    # Get partition size
    local partition_size
    if [ "$default_size" = "remaining" ]; then
        echo "Size: Use all remaining space on /dev/$selected_drive"
        partition_size="remaining"
    else
        read -p "Partition size in GB [default: ${default_size}GB]: " partition_size
        partition_size="${partition_size:-$default_size}"

        # Validate size is a number
        if ! [[ "$partition_size" =~ ^[0-9]+$ ]]; then
            error "Invalid size. Using default: ${default_size}GB"
            partition_size="$default_size"
        fi
    fi

    # Store configuration
    eval "${tier_var_prefix}_DRIVE=$selected_drive"
    eval "${tier_var_prefix}_SIZE=$partition_size"

    log "✓ $tier_name: /dev/$selected_drive ($partition_size GB)"
}

# ========================================
# Partition Creation
# ========================================

# Create all configured partitions
create_all_partitions() {
    log "Creating and mounting all partitions..."

    # Track created partitions for rollback
    CREATED_PARTITIONS=()

    # Create partitions for each tier
    create_partition "$TIER_A_DRIVE" "$TIER_A_SIZE" "$TIER_A_MOUNT" "fast" || return 1
    create_partition "$TIER_B_DRIVE" "$TIER_B_SIZE" "$TIER_B_MOUNT" "ai-data" || return 1
    create_partition "$TIER_C_DRIVE" "$TIER_C_SIZE" "$TIER_C_MOUNT" "models" || return 1
    create_partition "$TIER_D_DRIVE" "$TIER_D_SIZE" "$TIER_D_MOUNT" "bulk" || return 1

    success "All partitions created and mounted successfully"
    return 0
}

# Create a single partition, format it, and mount it
create_partition() {
    local drive="$1"
    local size="$2"
    local mount_point="$3"
    local label="$4"

    log "Creating partition on /dev/$drive for $mount_point..."

    # Initialize partition table if it doesn't exist
    if ! sudo parted -s /dev/$drive print &>/dev/null; then
        log "No partition table found on /dev/$drive, creating GPT partition table..."
        sudo parted -s /dev/$drive mklabel gpt || {
            error "Failed to create partition table on /dev/$drive"
            return 1
        }
        success "✓ Created GPT partition table on /dev/$drive"
    fi

    # Validate free space
    if ! validate_free_space "$drive" "$size"; then
        return 1
    fi

    # Get next partition number
    local part_num=$(get_next_partition_number "$drive")
    local partition="${drive}${part_num}"

    # Handle NVMe drives (use p separator)
    if [[ "$drive" =~ nvme ]]; then
        partition="${drive}p${part_num}"
    fi

    # Calculate size for parted
    local parted_size
    local parted_end
    if [ "$size" = "remaining" ]; then
        parted_end="-1s"  # Use -1s to mean "end of disk"
        log "Using all remaining space on /dev/$drive"
    else
        # Convert GB to sectors for precise calculation
        parted_end="${size}GB"
    fi

    # Get start position (end of last partition or beginning of disk)
    local start_pos=$(get_partition_start_position "$drive")

    # Create partition using parted
    log "Creating partition: /dev/$partition (from $start_pos to $parted_end)"
    sudo parted -s --align optimal /dev/$drive mkpart primary ext4 "$start_pos" "$parted_end" || {
        error "Failed to create partition on /dev/$drive"
        error "Debug: start=$start_pos, end=$parted_end"
        return 1
    }

    # Wait for partition to be recognized
    sleep 2
    sudo partprobe /dev/$drive
    sleep 1

    # Verify partition exists
    if [ ! -b "/dev/$partition" ]; then
        error "Partition /dev/$partition was not created"
        return 1
    fi

    # Format partition with ext4
    log "Formatting /dev/$partition with ext4..."
    sudo mkfs.ext4 -F -L "homelab-$label" /dev/$partition || {
        error "Failed to format /dev/$partition"
        return 1
    }

    # Create mount point
    sudo mkdir -p "$mount_point" || {
        error "Failed to create mount point: $mount_point"
        return 1
    }

    # Get UUID for fstab
    local uuid=$(sudo blkid -s UUID -o value /dev/$partition)

    # Mount partition
    log "Mounting /dev/$partition to $mount_point..."
    sudo mount /dev/$partition "$mount_point" || {
        error "Failed to mount /dev/$partition"
        return 1
    }

    # Add to fstab for persistent mounting
    if ! grep -q "$uuid" /etc/fstab; then
        log "Adding to /etc/fstab for persistent mounting..."
        echo "UUID=$uuid  $mount_point  ext4  defaults,noatime  0  2" | sudo tee -a /etc/fstab > /dev/null
    fi

    # Set permissions
    sudo chown -R $USER:$USER "$mount_point"
    sudo chmod 755 "$mount_point"

    # Track for rollback
    CREATED_PARTITIONS+=("/dev/$partition")

    success "✓ Created and mounted /dev/$partition at $mount_point"
    return 0
}

# Get the next available partition number for a drive
get_next_partition_number() {
    local drive="$1"

    # Get last partition number
    local last_part=$(lsblk -n -o NAME /dev/$drive | tail -1 | grep -o '[0-9]*$')

    if [ -z "$last_part" ]; then
        echo "1"
    else
        echo "$((last_part + 1))"
    fi
}

# Get the start position for the next partition
get_partition_start_position() {
    local drive="$1"

    # Check if drive has any partitions
    local last_partition=$(lsblk -n -o NAME /dev/$drive | tail -n +2 | tail -1)

    if [ -z "$last_partition" ]; then
        # No partitions, start at beginning
        echo "0%"
    else
        # Get the end of the last partition
        local end_sector=$(sudo parted -s /dev/$drive unit s print | grep "^ $last_partition" | awk '{print $3}' | sed 's/s//')

        if [ -z "$end_sector" ]; then
            # Fallback: try to get from parted print
            local partition_num=$(echo "$last_partition" | grep -o '[0-9]*$')
            end_sector=$(sudo parted -s /dev/$drive unit s print | grep "^ *${partition_num} " | awk '{print $3}' | sed 's/s//')
        fi

        if [ -z "$end_sector" ]; then
            # Last resort: start at 1MB aligned
            echo "1MiB"
        else
            # Start next partition at next sector after last partition
            echo "$((end_sector + 1))s"
        fi
    fi
}

# Validate there's enough free space on the drive
validate_free_space() {
    local drive="$1"
    local required_gb="$2"

    # Get drive size in GB
    local drive_size=$(lsblk -b -d -n -o SIZE /dev/$drive)
    local drive_size_gb=$((drive_size / 1024 / 1024 / 1024))

    # Get used space by existing partitions (only TYPE=part, not lvm or other descendants)
    local used_space=0
    local partitions=$(lsblk -b -n -o NAME,SIZE,TYPE /dev/$drive | grep 'part' | awk '{print $2}')

    if [ -n "$partitions" ]; then
        while IFS= read -r part_size; do
            used_space=$((used_space + part_size))
        done <<< "$partitions"
    fi

    local used_gb=$((used_space / 1024 / 1024 / 1024))
    local free_gb=$((drive_size_gb - used_gb))

    log "Drive /dev/$drive: Total ${drive_size_gb}GB, Used ${used_gb}GB, Free ${free_gb}GB"

    if [ "$required_gb" != "remaining" ]; then
        if [ "$free_gb" -lt "$required_gb" ]; then
            error "Not enough free space on /dev/$drive"
            error "Required: ${required_gb}GB, Available: ${free_gb}GB"
            return 1
        fi
    fi

    return 0
}

# ========================================
# Boot Drive Only Configuration
# ========================================

# Configure storage using only the boot drive
configure_boot_drive_only() {
    warning "Configuring storage on boot drive only"
    warning "This is NOT recommended for production use"

    # Use subdirectories on boot drive
    TIER_A_MOUNT="/var/lib/homelab/fast"
    TIER_B_MOUNT="/var/lib/homelab/ai-data"
    TIER_C_MOUNT="/var/lib/homelab/models"
    TIER_D_MOUNT="/var/lib/homelab/bulk"

    # Create directories
    sudo mkdir -p "$TIER_A_MOUNT" "$TIER_B_MOUNT" "$TIER_C_MOUNT" "$TIER_D_MOUNT"
    sudo chown -R $USER:$USER /var/lib/homelab

    log "Created storage directories on boot drive"
}

# ========================================
# Docker Compose Integration
# ========================================

# Update docker-compose.yml to use configured storage tiers
update_docker_compose_storage() {
    local compose_override="docker-compose.override.yml"

    log "Creating docker-compose override for storage tiers..."

    # Export paths for docker-compose
    export FAST_STORAGE_PATH="${TIER_A_MOUNT:-/mnt/fast}"
    export AI_STORAGE_PATH="${TIER_B_MOUNT:-/mnt/ai-data}"
    export MODEL_STORAGE_PATH="${TIER_C_MOUNT:-/mnt/models}"
    export BULK_STORAGE_PATH="${TIER_D_MOUNT:-/mnt/bulk}"

    cat > "$compose_override" << EOF
# Docker Compose Override - Storage Tier Configuration
# Auto-generated by homelab installation script
# DO NOT EDIT MANUALLY

services:
  # TIER C: Model Storage - Ollama
  ollama:
    volumes:
      - ${MODEL_STORAGE_PATH}/ollama:/root/.ollama

  # TIER B: AI Service Data
  openwebui:
    volumes:
      - ${AI_STORAGE_PATH}/openwebui:/app/backend/data

  langflow:
    volumes:
      - ${AI_STORAGE_PATH}/langflow:/root/.langflow

  n8n:
    volumes:
      - ${AI_STORAGE_PATH}/n8n:/home/node/.n8n

  portainer:
    volumes:
      - ${AI_STORAGE_PATH}/portainer:/data

  homarr:
    volumes:
      - ${AI_STORAGE_PATH}/homarr-config:/app/data/configs
      - ${AI_STORAGE_PATH}/homarr-icons:/app/public/icons
      - ${AI_STORAGE_PATH}/homarr-data:/data

  hoarder:
    volumes:
      - ${AI_STORAGE_PATH}/hoarder:/data

  pihole:
    volumes:
      - ${AI_STORAGE_PATH}/pihole-etc:/etc/pihole
      - ${AI_STORAGE_PATH}/pihole-dnsmasq:/etc/dnsmasq.d
      - ./pihole-custom-dns.conf:/etc/dnsmasq.d/02-custom-dns.conf:ro

  plex:
    volumes:
      - ${AI_STORAGE_PATH}/plex-config:/config
      - ${BULK_STORAGE_PATH}/plex-media:/media
      - ${AI_STORAGE_PATH}/plex-transcode:/transcode

  # TIER A: Fast Storage - Databases
  qdrant:
    volumes:
      - ${FAST_STORAGE_PATH}/qdrant:/qdrant/storage
      - ./qdrant_config.yaml:/qdrant/config/config.yaml:ro

  nextcloud-db:
    volumes:
      - ${FAST_STORAGE_PATH}/nextcloud-db:/var/lib/postgresql/data

  nextcloud-redis:
    volumes:
      - ${FAST_STORAGE_PATH}/nextcloud-redis:/data

  langgraph-db:
    volumes:
      - ${FAST_STORAGE_PATH}/langgraph-db:/var/lib/postgresql/data

  langgraph-redis:
    volumes:
      - ${FAST_STORAGE_PATH}/langgraph-redis:/data

  # TIER D: Bulk Storage
  nextcloud:
    volumes:
      - ${BULK_STORAGE_PATH}/nextcloud:/var/www/html
EOF

    success "Docker Compose override created"
    log "Storage tier paths configured in docker-compose.override.yml"

    return 0
}

# Configure Docker to use bulk storage
configure_docker_storage() {
    local docker_path="${TIER_D_MOUNT:-/mnt/bulk}/docker"

    if [ ! -d "$docker_path" ]; then
        log "Docker will use default storage location (/var/lib/docker)"
        return 0
    fi

    log "Configuring Docker to use: $docker_path"

    # Create daemon.json
    sudo mkdir -p /etc/docker
    echo '{
  "data-root": "'$docker_path'"
}' | sudo tee /etc/docker/daemon.json > /dev/null

    # Restart Docker
    sudo systemctl restart docker || {
        warning "Failed to restart Docker with new storage location"
        return 1
    }

    success "Docker configured to use $docker_path"
    return 0
}

# Configure SQLite storage on fast tier
configure_sqlite_storage() {
    local sqlite_dir="${TIER_A_MOUNT:-/mnt/fast}/databases"

    log "Configuring SQLite databases at: $sqlite_dir"

    mkdir -p "$sqlite_dir" || {
        error "Failed to create SQLite directory"
        return 1
    }

    # Create symlink from default location
    local default_dir="$HOME/.local/share/homelab/databases"
    mkdir -p "$(dirname "$default_dir")"

    if [ ! -L "$default_dir" ]; then
        ln -s "$sqlite_dir" "$default_dir"
        log "Created symlink: $default_dir -> $sqlite_dir"
    fi

    success "SQLite storage configured"
    return 0
}

# ========================================
# Display and Save Configuration
# ========================================

# Display storage configuration summary
display_storage_summary() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Storage Configuration Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Tier A - Fast Storage:"
    echo "  Drive: /dev/${TIER_A_DRIVE}"
    echo "  Size: ${TIER_A_SIZE}GB"
    echo "  Mount: ${TIER_A_MOUNT}"
    echo "  Services: PostgreSQL, Redis, Qdrant, SQLite"
    echo ""
    echo "Tier B - AI Service Data:"
    echo "  Drive: /dev/${TIER_B_DRIVE}"
    echo "  Size: ${TIER_B_SIZE}GB"
    echo "  Mount: ${TIER_B_MOUNT}"
    echo "  Services: OpenWebUI, n8n, LangFlow, Plex config, etc."
    echo ""
    echo "Tier C - Model Storage:"
    echo "  Drive: /dev/${TIER_C_DRIVE}"
    echo "  Size: ${TIER_C_SIZE}GB"
    echo "  Mount: ${TIER_C_MOUNT}"
    echo "  Services: Ollama models"
    echo ""
    echo "Tier D - Bulk Storage:"
    echo "  Drive: /dev/${TIER_D_DRIVE}"
    echo "  Size: ${TIER_D_SIZE}GB"
    echo "  Mount: ${TIER_D_MOUNT}"
    echo "  Services: Plex media, Nextcloud files, Docker"
    echo ""
}

# Save storage configuration to file
save_storage_config() {
    local config_file="$1"

    log "Saving storage configuration to: $config_file"

    cat > "$config_file" << EOF
# Homelab Storage Configuration
# Auto-generated: $(date)

# Tier A: Fast Storage
export TIER_A_DRIVE="${TIER_A_DRIVE}"
export TIER_A_SIZE="${TIER_A_SIZE}"
export TIER_A_MOUNT="${TIER_A_MOUNT}"

# Tier B: AI Service Data
export TIER_B_DRIVE="${TIER_B_DRIVE}"
export TIER_B_SIZE="${TIER_B_SIZE}"
export TIER_B_MOUNT="${TIER_B_MOUNT}"

# Tier C: Model Storage
export TIER_C_DRIVE="${TIER_C_DRIVE}"
export TIER_C_SIZE="${TIER_C_SIZE}"
export TIER_C_MOUNT="${TIER_C_MOUNT}"

# Tier D: Bulk Storage
export TIER_D_DRIVE="${TIER_D_DRIVE}"
export TIER_D_SIZE="${TIER_D_SIZE}"
export TIER_D_MOUNT="${TIER_D_MOUNT}"

# Storage paths for docker-compose
export FAST_STORAGE_PATH="${TIER_A_MOUNT}"
export AI_STORAGE_PATH="${TIER_B_MOUNT}"
export MODEL_STORAGE_PATH="${TIER_C_MOUNT}"
export BULK_STORAGE_PATH="${TIER_D_MOUNT}"
EOF

    chmod 600 "$config_file"
    source "$config_file"

    success "Storage configuration saved"
    return 0
}

# Load storage configuration if exists
load_storage_config() {
    local storage_config="$HOME/.homelab-storage.conf"

    if [ -f "$storage_config" ]; then
        source "$storage_config"
        return 0
    fi

    return 1
}
