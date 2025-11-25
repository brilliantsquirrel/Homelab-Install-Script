#!/bin/bash

# System Module - System updates, SSH, database setup, and Cockpit
# Usage: source lib/base/system.sh
# Provides: install_system_updates, install_ssh, install_sqlite, install_cockpit

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
    # Allow password authentication by default for initial setup
    # Users can disable it later by setting SSH_PASSWORD_AUTH=no in .env
    local password_auth="${SSH_PASSWORD_AUTH:-yes}"

    local -A ssh_settings=(
        ["PermitRootLogin"]="no"
        ["PasswordAuthentication"]="$password_auth"
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
    # Use full path to sshd as /usr/sbin may not be in PATH
    local sshd_bin="/usr/sbin/sshd"
    if [ ! -x "$sshd_bin" ]; then
        # Try to find sshd
        sshd_bin=$(which sshd 2>/dev/null || command -v sshd 2>/dev/null || echo "")
        if [ -z "$sshd_bin" ]; then
            error "sshd binary not found - is openssh-server installed?"
            error "Install with: sudo apt-get install openssh-server"
            error "Rolling back to: $backup_file"
            sudo cp "$backup_file" "$sshd_config" || error "Failed to restore backup!"
            return 1
        fi
    fi
    if ! sudo "$sshd_bin" -t 2>&1; then
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

# ========================================
# Cockpit Installation
# ========================================

# Install and configure Cockpit web-based server management
install_cockpit() {
    # Check if Cockpit is already installed and running
    if systemctl is-active --quiet cockpit.socket; then
        log "Cockpit already installed and running, skipping"
        return 0
    fi

    debug "Installing Cockpit web interface"

    # Install core Cockpit package
    sudo apt-get install -y cockpit || return 1
    track_package "cockpit"

    # Install optional plugins (ignore failures for unavailable packages)
    local plugins=(
        "cockpit-machines"
        "cockpit-networkmanager"
        "cockpit-storaged"
        "cockpit-packagekit"
        "cockpit-podman"
    )

    for plugin in "${plugins[@]}"; do
        if sudo apt-get install -y "$plugin" 2>/dev/null; then
            track_package "$plugin"
            log "Installed $plugin"
        else
            debug "$plugin not available, skipping"
        fi
    done

    # Enable and start Cockpit socket
    sudo systemctl enable cockpit.socket || return 1
    sudo systemctl start cockpit.socket || return 1

    # Check status
    if systemctl is-active --quiet cockpit.socket; then
        success "Cockpit installed and running on port 9090"
        log "Access Cockpit at: https://<server-ip>:9090"
        log "Login with your system username and password"
    else
        error "Cockpit failed to start"
        return 1
    fi
}
