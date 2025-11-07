#!/bin/bash

# System Module - System updates, SSH, and database setup
# Usage: source lib/base/system.sh
# Provides: install_system_updates, install_ssh, install_sqlite

# ========================================
# System Updates
# ========================================

# Update system packages
install_system_updates() {
    sudo apt-get update && sudo apt-get upgrade -y || return 1
}

# ========================================
# SSH Configuration
# ========================================

# Install and harden SSH server
install_ssh() {
    # Check if SSH is already installed and running
    if sudo systemctl is-active --quiet ssh; then
        debug "SSH already installed and running"
        # Apply hardening to existing SSH even if already installed
    else
        debug "Installing SSH server"
        sudo apt-get install -y openssh-server openssh-client || return 1
        sudo systemctl enable ssh || return 1
        sudo systemctl start ssh || return 1
        track_package "openssh-server"
    fi

    # Harden SSH configuration
    log "Applying SSH security hardening..."

    local sshd_config="${SSH_CONFIG:-/etc/ssh/sshd_config}"
    local backup_file="${sshd_config}.backup.$(date +%Y%m%d_%H%M%S)"

    # Backup original sshd_config with unique timestamp
    sudo cp "$sshd_config" "$backup_file" || return 1
    log "SSH config backed up to: $backup_file"

    # Create temporary file for modifications
    local temp_config=$(mktemp) || return 1
    trap "rm -f $temp_config" RETURN

    # Copy original config
    sudo cat "$sshd_config" > "$temp_config" || return 1

    # Function to safely set SSH configuration option
    # Removes all existing instances of the key and adds new one
    set_ssh_option() {
        local key="$1"
        local value="$2"
        local config_file="$3"

        # Comment out any existing instances (preserve for reference)
        sed -i "s/^${key} /#${key} /" "$config_file" 2>/dev/null || true
        sed -i "s/^#${key} /#${key} /" "$config_file" 2>/dev/null || true
    }

    # Apply settings using temporary file approach
    log "Configuring SSH security settings..."

    # Define desired SSH settings
    local -A ssh_settings=(
        ["PermitRootLogin"]="no"
        ["PasswordAuthentication"]="no"
        ["PubkeyAuthentication"]="yes"
        ["PermitEmptyPasswords"]="no"
        ["X11Forwarding"]="no"
        ["LoginGraceTime"]="1m"
        ["MaxStartups"]="5:30:10"
        ["ClientAliveInterval"]="300"
        ["ClientAliveCountMax"]="2"
        ["Protocol"]="2"
    )

    # Apply each setting
    for key in "${!ssh_settings[@]}"; do
        value="${ssh_settings[$key]}"
        # Comment out existing instances
        sudo sed -i "s/^${key} /#${key} /" "$sshd_config" 2>/dev/null || true
        sudo sed -i "s/^#${key} /#${key} /" "$sshd_config" 2>/dev/null || true
    done

    # Append new security settings section
    {
        echo ""
        echo "# SSH Security Hardening - Applied by homelab setup"
        echo "# Applied: $(date)"
        for key in "${!ssh_settings[@]}"; do
            echo "${key} ${ssh_settings[$key]}"
        done
    } | sudo tee -a "$sshd_config" > /dev/null || return 1

    log "SSH settings applied"

    # Validate sshd_config before restarting
    log "Validating SSH configuration..."
    if ! sudo sshd -t 2>&1; then
        error "SSH configuration validation failed"
        error "Rolling back to: $backup_file"
        sudo cp "$backup_file" "$sshd_config" || error "Failed to restore backup!"
        return 1
    fi
    success "SSH configuration is valid"

    # Restart SSH with new configuration
    log "Restarting SSH service..."
    sudo systemctl restart ssh || {
        error "Failed to restart SSH, rolling back"
        sudo cp "$backup_file" "$sshd_config"
        sudo systemctl restart ssh
        return 1
    }

    success "SSH hardened: Root login disabled, key-based auth only, password auth disabled"
    warning "IMPORTANT: Ensure you have SSH keys set up before disconnecting!"
    warning "Test SSH access in another terminal before closing this one!"
    warning "If you lose SSH access, you may need physical access to restore:"
    warning "  sudo cp $backup_file $sshd_config"
    warning "  sudo systemctl restart ssh"
}

# ========================================
# SQLite Installation
# ========================================

# Install SQLite and create database directory
install_sqlite() {
    # Check if SQLite is already installed
    if command -v sqlite3 &> /dev/null; then
        log "SQLite already installed ($(sqlite3 --version | head -1)), skipping"
        return 0
    fi

    debug "Installing SQLite"
    sudo apt-get install -y sqlite3 || return 1
    track_package "sqlite3"

    # Create SQLite database directory with restrictive permissions
    local DBDIR="${DATABASE_DIR:-$HOME/.local/share/homelab/databases}"
    mkdir -p "$DBDIR" || return 1

    # Set restrictive permissions (owner only)
    chmod "${DB_DIR_PERMS:-700}" "$DBDIR" || return 1

    # Create a default .env.local file for database credentials
    cat > "$DBDIR/.env" << 'EOF'
# SQLite Database Credentials
# Place actual passwords here, keep this file secret
SQLITE_BACKUP_ENABLED=true
SQLITE_BACKUP_PATH=$HOME/.local/share/homelab/backups
EOF

    chmod "${DB_FILE_PERMS:-600}" "$DBDIR/.env" || return 1

    log "SQLite database directory created with restricted permissions (${DB_DIR_PERMS:-700}): $DBDIR"
    debug "Creating backups directory for database backups"

    local BACKUPDIR="${BACKUP_DIR:-$HOME/.local/share/homelab/backups}"
    mkdir -p "$BACKUPDIR"
    chmod "${DB_DIR_PERMS:-700}" "$BACKUPDIR"

    success "SQLite installed and database directories created"
}
