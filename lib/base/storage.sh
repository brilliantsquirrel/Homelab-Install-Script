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
# Partition Management
# ========================================

# Manage existing partitions - delete or format drives
manage_partitions() {
    log "Partition management..."
    echo ""

    # Get boot drive to prevent accidental deletion
    local boot_drive=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /))

    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Partition Management${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo "Would you like to delete existing partitions or format drives?"
    echo "This can free up space for the new storage configuration."
    echo ""
    echo -e "${RED}WARNING: This will permanently delete data!${NC}"
    echo ""

    read -p "Manage partitions? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Skipping partition management"
        return 0
    fi

    # Loop to allow multiple operations
    while true; do
        echo ""
        echo "Partition Management Options:"
        echo "  1. Delete a specific partition"
        echo "  2. Format entire drive (delete all partitions)"
        echo "  3. View current partitions"
        echo "  4. Done (continue with storage configuration)"
        echo ""

        read -p "Choose option [1-4]: " choice

        case $choice in
            1)
                delete_partition "$boot_drive"
                ;;
            2)
                format_drive "$boot_drive"
                ;;
            3)
                display_all_partitions "$boot_drive"
                ;;
            4)
                log "Partition management complete"
                return 0
                ;;
            *)
                warning "Invalid option. Please choose 1-4."
                ;;
        esac
    done
}

# Display all partitions on all drives
display_all_partitions() {
    local boot_drive="$1"

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}All Partitions${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # List all drives
    while IFS= read -r line; do
        local drive=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')

        # Mark boot drive
        local boot_marker=""
        if [ "$drive" = "$boot_drive" ]; then
            boot_marker=" ${RED}(BOOT DRIVE - DO NOT MODIFY)${NC}"
        fi

        echo -e "/dev/$drive - $size$boot_marker"

        # Show partitions
        local partitions=$(lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT /dev/$drive | tail -n +2)
        if [ -n "$partitions" ]; then
            echo "$partitions" | while IFS= read -r part_line; do
                echo "  $part_line"
            done
        else
            echo "  (no partitions)"
        fi
        echo ""
    done < <(lsblk -d -n -o NAME,SIZE | grep -v "^loop\|^sr")
}

# Delete a specific partition
delete_partition() {
    local boot_drive="$1"

    echo ""
    display_all_partitions "$boot_drive"

    echo "Enter the partition to delete (e.g., sda1, nvme0n1p1):"
    echo -e "${RED}WARNING: This will permanently delete all data on the partition!${NC}"
    read -p "Partition name (or 'cancel'): " partition_name

    if [ "$partition_name" = "cancel" ] || [ -z "$partition_name" ]; then
        log "Cancelled partition deletion"
        return 0
    fi

    # Validate partition exists
    if [ ! -b "/dev/$partition_name" ]; then
        error "Partition /dev/$partition_name does not exist"
        return 1
    fi

    # Check if it's on the boot drive
    local part_drive=$(lsblk -no PKNAME /dev/$partition_name 2>/dev/null)
    if [ "$part_drive" = "$boot_drive" ]; then
        error "Cannot delete partition on boot drive: /dev/$partition_name"
        error "This could make your system unbootable!"
        return 1
    fi

    # Check if partition is mounted
    local mount_point=$(lsblk -no MOUNTPOINT /dev/$partition_name 2>/dev/null)
    if [ -n "$mount_point" ]; then
        warning "Partition /dev/$partition_name is mounted at: $mount_point"
        read -p "Unmount and delete? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Cancelled"
            return 0
        fi

        log "Unmounting /dev/$partition_name..."
        sudo umount /dev/$partition_name || {
            error "Failed to unmount /dev/$partition_name"
            return 1
        }
    fi

    # Final confirmation
    echo ""
    echo -e "${RED}FINAL WARNING: About to delete /dev/$partition_name${NC}"
    read -p "Type 'DELETE' to confirm: " confirm

    if [ "$confirm" != "DELETE" ]; then
        log "Cancelled partition deletion"
        return 0
    fi

    log "Deleting partition /dev/$partition_name..."

    # Get partition number
    local part_num=$(echo "$partition_name" | grep -o '[0-9]*$')
    local drive_name=$(echo "$partition_name" | sed 's/[0-9]*$//' | sed 's/p$//')

    # Delete partition using parted
    sudo parted -s /dev/$drive_name rm $part_num || {
        error "Failed to delete partition /dev/$partition_name"
        return 1
    }

    # Update partition table
    sudo partprobe /dev/$drive_name
    sleep 1

    success "Partition /dev/$partition_name deleted successfully"
    return 0
}

# Format entire drive (delete all partitions)
format_drive() {
    local boot_drive="$1"

    echo ""
    display_all_partitions "$boot_drive"

    echo "Enter the drive to format (e.g., sda, nvme0n1):"
    echo -e "${RED}WARNING: This will delete ALL partitions and data on the drive!${NC}"
    read -p "Drive name (or 'cancel'): " drive_name

    if [ "$drive_name" = "cancel" ] || [ -z "$drive_name" ]; then
        log "Cancelled drive format"
        return 0
    fi

    # Validate drive exists
    if [ ! -b "/dev/$drive_name" ]; then
        error "Drive /dev/$drive_name does not exist"
        return 1
    fi

    # Check if it's the boot drive
    if [ "$drive_name" = "$boot_drive" ]; then
        error "Cannot format boot drive: /dev/$drive_name"
        error "This would make your system unbootable!"
        return 1
    fi

    # Check for mounted partitions
    local mounted_parts=$(lsblk -no MOUNTPOINT /dev/$drive_name | grep -v '^$')
    if [ -n "$mounted_parts" ]; then
        warning "Drive /dev/$drive_name has mounted partitions:"
        echo "$mounted_parts"
        read -p "Unmount all and format? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Cancelled"
            return 0
        fi

        log "Unmounting all partitions on /dev/$drive_name..."
        sudo umount /dev/${drive_name}* 2>/dev/null || true
    fi

    # Final confirmation
    echo ""
    echo -e "${RED}FINAL WARNING: About to wipe ALL data on /dev/$drive_name${NC}"
    local drive_size=$(lsblk -d -n -o SIZE /dev/$drive_name)
    echo "Drive: /dev/$drive_name ($drive_size)"
    read -p "Type 'FORMAT' to confirm: " confirm

    if [ "$confirm" != "FORMAT" ]; then
        log "Cancelled drive format"
        return 0
    fi

    log "Formatting /dev/$drive_name (creating new GPT partition table)..."

    # Create new GPT partition table (deletes all partitions)
    sudo parted -s /dev/$drive_name mklabel gpt || {
        error "Failed to create partition table on /dev/$drive_name"
        return 1
    }

    # Update partition table
    sudo partprobe /dev/$drive_name
    sleep 1

    success "Drive /dev/$drive_name formatted successfully (all partitions removed)"
    return 0
}

# ========================================
# Storage Tier Configuration
# ========================================

# Configure storage tiers with automatic partitioning
configure_storage_tiers() {
    log "Configuring storage tiers with automatic partitioning..."
    echo ""

    # Check for existing storage configuration (e.g., after OS reinstall)
    if load_storage_config 2>/dev/null; then
        log "Found existing storage configuration!"
        echo ""
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}Existing Storage Configuration Detected${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo "Previous storage configuration found at: ~/.homelab-storage.conf"
        echo ""
        echo "Storage tiers:"
        echo "  - Fast Storage (Tier A): ${TIER_A_MOUNT:-not set}"
        echo "  - AI Data (Tier B): ${TIER_B_MOUNT:-not set}"
        echo "  - Model Storage (Tier C): ${TIER_C_MOUNT:-not set}"
        echo "  - Bulk Storage (Tier D): ${TIER_D_MOUNT:-not set}"
        echo ""

        # Verify mounts are accessible
        local mounts_valid=true
        for mount in "$TIER_A_MOUNT" "$TIER_B_MOUNT" "$TIER_C_MOUNT" "$TIER_D_MOUNT"; do
            if [ -n "$mount" ] && [ -d "$mount" ]; then
                echo -e "  ${GREEN}✓${NC} $mount is accessible"
            elif [ -n "$mount" ]; then
                echo -e "  ${RED}✗${NC} $mount is NOT accessible"
                mounts_valid=false
            fi
        done
        echo ""

        if [ "$mounts_valid" = true ]; then
            echo "All storage mounts are accessible."
            echo "Your Docker images and Ollama models should still be available!"
            echo ""
            read -p "Use existing storage configuration? (Y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                success "Using existing storage configuration"
                log "Docker images and Ollama models will be preserved"
                return 0
            fi
            log "User chose to reconfigure storage"
        else
            warning "Some storage mounts are not accessible"
            warning "This may happen if drives were not mounted automatically"
            echo ""
            echo "You can either:"
            echo "  1. Mount the existing partitions manually and re-run this script"
            echo "  2. Reconfigure storage (may lose existing data)"
            echo ""
            read -p "Reconfigure storage? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                error "Storage configuration cancelled"
                error "Mount the drives manually and re-run this script"
                return 1
            fi
        fi
    fi

    # Offer partition management before configuring storage
    manage_partitions

    # Detect available drives
    if ! detect_available_drives; then
        warning "No additional drives available"
        warning "All data will be stored on boot drive (not recommended for production)"
        read -p "Continue with boot drive only? (y/N): " -n 1 -r use_boot_only
        echo
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
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

    read -p "Continue with automatic partitioning? (y/N): " -n 1 -r
    echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
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

    read -p "Proceed with creating partitions? (y/N): " -n 1 -r
    echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
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

# Get free space on a drive in GB
get_drive_free_space_gb() {
    local drive="$1"
    local drive_size=$(lsblk -b -d -n -o SIZE /dev/$drive)
    local drive_size_gb=$((drive_size / 1024 / 1024 / 1024))

    # Get used space by existing partitions
    local used_space=0
    local partitions=$(lsblk -b -n -o NAME,SIZE,TYPE /dev/$drive | grep 'part' | awk '{print $2}')
    if [ -n "$partitions" ]; then
        while IFS= read -r part_size; do
            used_space=$((used_space + part_size))
        done <<< "$partitions"
    fi

    local used_gb=$((used_space / 1024 / 1024 / 1024))
    local free_gb=$((drive_size_gb - used_gb))
    echo "$free_gb"
}

# Select drive and partition size for a tier
select_drive_and_size() {
    local tier_name="$1"
    local default_size="$2"
    local tier_var_prefix="$3"

    local selected_drive=""
    local partition_size=""

    # Loop until valid drive and size are selected
    while true; do
        # Select drive
        echo "Select drive for $tier_name:"
        for i in "${!AVAILABLE_DRIVES[@]}"; do
            local drive_info="${AVAILABLE_DRIVES[$i]}"
            local drive=$(echo "$drive_info" | cut -d'|' -f1)
            local size=$(echo "$drive_info" | cut -d'|' -f2)
            local rota=$(echo "$drive_info" | cut -d'|' -f3)
            local drive_type="SSD/NVMe"
            [ "$rota" = "1" ] && drive_type="HDD"
            local free_gb=$(get_drive_free_space_gb "$drive")

            echo "  [$((i+1))] /dev/$drive - $size ($drive_type) - ${free_gb}GB free"
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
        selected_drive=$(echo "$selected_drive_info" | cut -d'|' -f1)
        local free_space_gb=$(get_drive_free_space_gb "$selected_drive")

        # Get partition size
        if [ "$default_size" = "remaining" ]; then
            echo "Size: Use all remaining space on /dev/$selected_drive (${free_space_gb}GB available)"
            partition_size="remaining"
            break
        else
            # Show available space and allow re-selection
            echo "Available space on /dev/$selected_drive: ${free_space_gb}GB"
            read -p "Partition size in GB [default: ${default_size}GB, max: ${free_space_gb}GB]: " partition_size
            partition_size="${partition_size:-$default_size}"

            # Validate size is a number
            if ! [[ "$partition_size" =~ ^[0-9]+$ ]]; then
                error "Invalid size. Please enter a number."
                continue
            fi

            # Check if there's enough space
            if [ "$partition_size" -gt "$free_space_gb" ]; then
                warning "Not enough free space on /dev/$selected_drive"
                warning "Required: ${partition_size}GB, Available: ${free_space_gb}GB"
                echo ""
                echo "Options:"
                echo "  1. Enter a smaller size (max ${free_space_gb}GB)"
                echo "  2. Select a different drive"
                read -p "Choose [1-2]: " retry_choice
                if [ "$retry_choice" = "1" ]; then
                    # Let them re-enter size for same drive
                    echo "Selected drive: /dev/$selected_drive (${free_space_gb}GB available)"
                    read -p "Partition size in GB [max: ${free_space_gb}GB]: " partition_size
                    if ! [[ "$partition_size" =~ ^[0-9]+$ ]] || [ "$partition_size" -gt "$free_space_gb" ]; then
                        error "Invalid size. Starting over..."
                        continue
                    fi
                    break
                else
                    # Restart drive selection
                    continue
                fi
            else
                break
            fi
        fi
    done

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

    # Get start position (end of last partition or beginning of disk)
    local start_pos=$(get_partition_start_position "$drive")

    # Calculate end position for parted
    local parted_end
    if [ "$size" = "remaining" ]; then
        parted_end="100%"  # Use 100% to mean "end of disk"
        log "Using all remaining space on /dev/$drive"
    elif [[ "$start_pos" =~ s$ ]]; then
        # Start is in sectors (e.g., "195311616s")
        local start_sector=$(echo "$start_pos" | sed 's/s$//')
        # Convert GB to sectors (assuming 512 byte sectors: 1GB = 2097152 sectors)
        local size_sectors=$((size * 2097152))
        parted_end="$((start_sector + size_sectors))s"
    elif [ "$start_pos" = "0%" ]; then
        # First partition starting at beginning of disk
        parted_end="${size}GB"
    else
        # Start position is in another unit (e.g., "MiB", "GB")
        # This shouldn't happen with current logic, but handle it
        parted_end="${size}GB"
    fi

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
            # Align to 2048-sector boundary (1MiB for 512-byte sectors) for optimal performance
            local next_sector=$((end_sector + 1))
            local aligned_sector=$(( (next_sector + 2047) / 2048 * 2048 ))
            echo "${aligned_sector}s"
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

# Configure Docker to use bulk storage for images and containers
# This should be run BEFORE pulling any Docker images to ensure
# images are stored on the specified drive and survive OS reinstalls
configure_docker_storage() {
    # Load storage config if available
    load_storage_config 2>/dev/null || true

    local docker_path="${TIER_D_MOUNT:-/mnt/bulk}/docker"
    local current_data_root=""

    log "Configuring Docker storage location..."

    # Check if mount point exists
    if [ ! -d "${TIER_D_MOUNT:-/mnt/bulk}" ]; then
        warning "Storage mount point not found: ${TIER_D_MOUNT:-/mnt/bulk}"
        warning "Docker will use default storage location (/var/lib/docker)"
        warning "Run storage configuration first to use external drives"
        return 0
    fi

    # Create docker directory on the target drive
    log "Creating Docker data directory: $docker_path"
    sudo mkdir -p "$docker_path" || {
        error "Failed to create Docker directory: $docker_path"
        return 1
    }
    sudo chown root:root "$docker_path"
    sudo chmod 711 "$docker_path"

    # Check current Docker data-root configuration
    if [ -f /etc/docker/daemon.json ]; then
        current_data_root=$(grep -oP '"data-root"\s*:\s*"\K[^"]+' /etc/docker/daemon.json 2>/dev/null || echo "")
    fi

    # Check if already configured correctly
    if [ "$current_data_root" = "$docker_path" ]; then
        log "Docker already configured to use: $docker_path"
        return 0
    fi

    log "Configuring Docker to use: $docker_path"

    # Stop Docker before changing data-root
    log "Stopping Docker service..."
    sudo systemctl stop docker || true
    sudo systemctl stop docker.socket || true

    # Check if there are existing images in /var/lib/docker
    local old_docker_path="/var/lib/docker"
    if [ -d "$old_docker_path" ] && [ "$(sudo ls -A $old_docker_path 2>/dev/null)" ]; then
        log "Existing Docker data found in $old_docker_path"

        # Check if target already has data
        if [ "$(sudo ls -A $docker_path 2>/dev/null)" ]; then
            log "Target directory already has data, preserving existing data"
        else
            log "Moving existing Docker data to new location..."
            log "This may take a while depending on the amount of data..."
            sudo rsync -aP "$old_docker_path/" "$docker_path/" || {
                warning "Failed to move existing Docker data"
                warning "Starting fresh at new location"
            }
        fi
    fi

    # Create or update daemon.json
    sudo mkdir -p /etc/docker

    # Preserve existing daemon.json settings if present
    if [ -f /etc/docker/daemon.json ] && [ -s /etc/docker/daemon.json ]; then
        # Backup existing config
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup

        # Update data-root in existing config using jq if available, otherwise replace
        if command -v jq &> /dev/null; then
            sudo jq --arg path "$docker_path" '. + {"data-root": $path}' /etc/docker/daemon.json.backup | sudo tee /etc/docker/daemon.json > /dev/null
        else
            # Simple replacement - create new config with data-root
            echo '{
  "data-root": "'$docker_path'"
}' | sudo tee /etc/docker/daemon.json > /dev/null
        fi
    else
        echo '{
  "data-root": "'$docker_path'"
}' | sudo tee /etc/docker/daemon.json > /dev/null
    fi

    # Start Docker with new configuration
    log "Starting Docker with new storage location..."
    sudo systemctl start docker.socket || true
    sudo systemctl start docker || {
        error "Failed to start Docker with new storage location"
        error "Restoring previous configuration..."
        if [ -f /etc/docker/daemon.json.backup ]; then
            sudo mv /etc/docker/daemon.json.backup /etc/docker/daemon.json
        else
            sudo rm -f /etc/docker/daemon.json
        fi
        sudo systemctl start docker
        return 1
    }

    # Verify Docker is using the new location
    local actual_root=$(sudo docker info 2>/dev/null | grep "Docker Root Dir" | awk '{print $4}')
    if [ "$actual_root" = "$docker_path" ]; then
        success "Docker configured to use $docker_path"
        log "Docker images and containers will now be stored on your bulk storage drive"
        log "This data will persist across OS reinstalls"
    else
        warning "Docker data-root verification failed"
        warning "Expected: $docker_path, Actual: $actual_root"
    fi

    return 0
}

# Configure Ollama model storage on model tier
# This should be run BEFORE pulling any Ollama models to ensure
# models are stored on the specified drive and survive OS reinstalls
configure_ollama_storage() {
    # Load storage config if available
    load_storage_config 2>/dev/null || true

    local ollama_path="${TIER_C_MOUNT:-/mnt/models}/ollama"

    log "Configuring Ollama model storage location..."

    # Check if mount point exists
    if [ ! -d "${TIER_C_MOUNT:-/mnt/models}" ]; then
        warning "Model storage mount point not found: ${TIER_C_MOUNT:-/mnt/models}"
        warning "Ollama will use default storage location"
        warning "Run storage configuration first to use external drives"
        return 0
    fi

    # Create ollama directory on the target drive
    log "Creating Ollama data directory: $ollama_path"
    mkdir -p "$ollama_path" || {
        error "Failed to create Ollama directory: $ollama_path"
        return 1
    }

    # Check if ollama container is already running with different volume
    if sudo docker ps -a | grep -q ollama; then
        log "Ollama container exists, checking configuration..."

        # Get current volume mount
        local current_mount=$(sudo docker inspect ollama 2>/dev/null | grep -A1 '"Source":' | grep -oP '(?<="Source": ")[^"]+' | head -1 || echo "")

        if [ -n "$current_mount" ] && [ "$current_mount" != "$ollama_path" ]; then
            log "Ollama currently using: $current_mount"

            # Check if there's existing model data to migrate
            if [ -d "$current_mount" ] && [ "$(sudo ls -A $current_mount 2>/dev/null)" ]; then
                # Check if target already has data
                if [ "$(ls -A $ollama_path 2>/dev/null)" ]; then
                    log "Target directory already has model data, preserving existing data"
                else
                    log "Migrating existing Ollama models to new location..."
                    log "This may take a while for large models..."

                    # Stop ollama container before migration
                    sudo docker stop ollama 2>/dev/null || true

                    sudo rsync -aP "$current_mount/" "$ollama_path/" || {
                        warning "Failed to migrate existing Ollama models"
                        warning "Models will need to be re-downloaded"
                    }
                fi
            fi

            # Remove old container to recreate with new volume
            log "Removing old Ollama container to apply new storage location..."
            sudo docker rm -f ollama 2>/dev/null || true
        fi
    fi

    # Update docker-compose.override.yml to use the new path
    # This is handled by update_docker_compose_storage, but we ensure the path is set
    export MODEL_STORAGE_PATH="${TIER_C_MOUNT:-/mnt/models}"

    # Save the path to storage config for later use
    if [ -f "$HOME/.homelab-storage.conf" ]; then
        if ! grep -q "OLLAMA_MODELS_PATH=" "$HOME/.homelab-storage.conf"; then
            echo "" >> "$HOME/.homelab-storage.conf"
            echo "# Ollama models path" >> "$HOME/.homelab-storage.conf"
            echo "export OLLAMA_MODELS_PATH=\"$ollama_path\"" >> "$HOME/.homelab-storage.conf"
        fi
    fi

    success "Ollama model storage configured: $ollama_path"
    log "Ollama models will now be stored on your model storage drive"
    log "This data will persist across OS reinstalls"

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
