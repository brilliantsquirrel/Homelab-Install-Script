# Developer Guide - Homelab Install Script

Welcome to the Homelab Install Script development guide! This document explains the architecture, how to add features, and best practices for contributing to this project.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Project Structure](#project-structure)
3. [Module System](#module-system)
4. [Adding New Installation Steps](#adding-new-installation-steps)
5. [Error Handling Patterns](#error-handling-patterns)
6. [Testing Guidelines](#testing-guidelines)
7. [Code Style](#code-style)
8. [Debugging Tips](#debugging-tips)
9. [Common Mistakes to Avoid](#common-mistakes-to-avoid)

## Architecture Overview

The Homelab Install Script is designed with the following principles:

- **Modularity**: Each functional area (logging, error handling, system setup, Docker, etc.) is in its own module
- **Idempotency**: Functions can be run multiple times without side effects
- **Error Recovery**: Failed steps can be rolled back, and non-critical failures don't stop installation
- **Configurability**: Settings are centralized in `lib/config.sh`
- **Reusability**: Functions are extracted to modules for use in other scripts

### Execution Flow

```
post-install.sh
  ├── Source all modules (logger, error-handling, config, base/*)
  ├── Initialize logger and validate configuration
  ├── Pre-installation checks (root check, user confirmation)
  ├── Environment validation (API keys, .env completeness)
  └── Run installation steps via run_step()
      ├── System Updates (critical step - aborts on failure)
      ├── SSH Server
      ├── SQLite Database
      ├── Docker Engine
      ├── NVIDIA GPU Support
      ├── Docker Containers
      ├── Ollama Models
      ├── Git Configuration
      ├── Claude Code Installation
      ├── Claude Project Setup
      ├── Utility Packages
      └── System Cleanup
```

## Project Structure

```
.
├── post-install.sh                # Main installation orchestrator (~210 lines after refactoring)
├── validate-setup.sh              # Pre-installation validation script
├── verify-installation.sh          # Post-installation verification script
├── docker-compose.yml             # Docker service definitions
├── .env.example                   # Environment variables template
├── Dockerfile                     # nginx reverse proxy container
│
├── lib/                           # Reusable modules
│   ├── logger.sh                  # Logging utilities (log, error, warning, success, debug, info)
│   ├── error-handling.sh          # Error tracking and rollback (run_step, track_package, etc.)
│   ├── config.sh                  # Configuration variables and validation
│   │
│   └── base/                      # Installation modules for specific features
│       ├── system.sh              # System updates, SSH, SQLite installation
│       ├── docker.sh              # Docker Engine, containers, GPU support, Ollama models
│       ├── development.sh         # Git configuration, Claude Code installation
│       └── utilities.sh           # Utility packages, system cleanup, environment validation
│
├── nginx/                         # nginx reverse proxy configuration
│   ├── Dockerfile                 # nginx container definition
│   ├── nginx.conf                 # nginx configuration
│   ├── auth/                      # Authentication files
│   │   └── .htpasswd              # HTTP Basic Auth credentials (generated at runtime)
│   └── certs/                     # SSL/TLS certificates (generated at runtime)
│
├── README.md                      # User documentation
├── CLAUDE.md                      # Project configuration for Claude Code
├── SECRETS.md                     # Secret management guide
├── CODE-REVIEW.md                 # Security audit findings
├── REFACTORING-ROADMAP.md         # Refactoring improvements (Phase 4 details)
└── DEVELOPER.md                   # This file
```

## Module System

### Core Modules

#### logger.sh
Provides centralized logging with configurable log levels and file output.

**Exported Functions:**
- `log(message)` - Info message (green)
- `error(message)` - Error message (red)
- `warning(message)` - Warning message (yellow)
- `success(message)` - Success message (green with SUCCESS tag)
- `debug(message)` - Debug message (blue, only shown if LOG_LEVEL=debug)
- `info(message)` - Info header (blue)
- `print_separator(char, length)` - Print visual separator line

**Variables:**
- `LOG_FILE` - Output log file path (default: .homelab-setup.log)
- `LOG_LEVEL` - Logging level: debug, info, warn, error (default: info)

**Usage in Modules:**
```bash
source lib/logger.sh

log "Normal message"
error "Something went wrong"
warning "This is important"
success "Feature completed"
debug "Detailed debug info"  # Only shown if LOG_LEVEL=debug
```

#### error-handling.sh
Manages step execution, error tracking, and rollback capability.

**Exported Functions:**
- `run_step(name, function, critical)` - Execute installation step with tracking
- `track_package(name)` - Record installed package for rollback
- `track_repo(path)` - Record added repository for rollback
- `rollback()` - Interactively rollback changes
- `get_failed_steps()` - Get array of failed step names
- `print_installation_summary()` - Display final summary
- `get_installed_packages_count()` - Count installed packages
- `get_added_repos_count()` - Count added repositories

**Variables:**
- `INSTALL_STATUS` - Associative array of step → SUCCESS|FAILED
- `FAILED_STEPS` - Array of failed step names
- `INSTALLED_PACKAGES` - Packages installed during this run
- `ADDED_REPOS` - Repositories added during this run

**Key Concept - run_step() Signature:**
```bash
run_step "Installation Name" function_name "critical|false"
```

- If `critical="true"`: Failed step aborts entire installation and triggers rollback
- If `critical="false"`: Failed step logs error but continues with remaining steps

**Usage in Modules:**
```bash
source lib/error-handling.sh

install_myservice() {
    # Check if already installed
    if command -v myservice &>/dev/null; then
        log "MyService already installed, skipping"
        return 0
    fi

    # Install
    sudo apt-get install -y myservice || return 1
    track_package "myservice"

    success "MyService installed"
}

# In post-install.sh main execution
run_step "My Service" install_myservice false
```

#### config.sh
Central configuration with defaults and validation.

**Exported Variables:**
- SSH configuration: `SSH_CONFIG`, `SSH_BACKUP_TIMESTAMP`
- Docker: `DOCKER_STARTUP_WAIT`, `DOCKER_SOCKET_PROXY_IMAGE`
- Timeouts: `MODEL_PULL_TIMEOUT` (7200s = 2 hours), `SERVICE_STARTUP_TIMEOUT`, `DB_MIGRATION_TIMEOUT`
- Paths: `DATABASE_DIR`, `BACKUP_DIR`, `DOCKER_COMPOSE_FILE`, `DOCKER_NETWORK`
- Permissions: `DB_DIR_PERMS` (700), `DB_FILE_PERMS` (600), `ENV_FILE_PERMS` (600), `SSH_CONFIG_PERMS` (600)
- Container images: `CONTAINER_IMAGES` associative array with pinned versions
- Ollama models: `OLLAMA_MODELS` array
- Features: `ENABLE_GPU_SUPPORT`, `ENABLE_AUTO_MODEL_PULL`, `ENABLE_BACKUPS`

**Exported Functions:**
- `get_container_image(service)` - Get full image URI for a service
- `validate_config()` - Validate all critical configuration is set
- `print_config()` - Display current configuration
- `get_ollama_models()` - Get Ollama models array
- `get_ollama_models_count()` - Count Ollama models

**Usage:**
```bash
source lib/config.sh

# Use configuration variables
docker pull "$(get_container_image ollama)"

# Validate before proceeding
if ! validate_config; then
    error "Configuration validation failed"
    exit 1
fi
```

### Base Installation Modules

#### base/system.sh
System updates, SSH hardening, and SQLite setup.

**Exported Functions:**
- `install_system_updates()` - Update and upgrade system packages
- `install_ssh()` - Install/harden SSH with append-only configuration
- `install_sqlite()` - Install SQLite and create database directories

**Key Features:**
- SSH configuration uses timestamp-based backups for recovery
- SSH hardening applies 10 security settings (PermitRootLogin=no, PasswordAuthentication=no, etc.)
- Validates sshd configuration before restarting service
- Creates restrictive database directories (700, 600 permissions)

#### base/docker.sh
Docker Engine, containers, GPU support, and model pulling.

**Exported Functions:**
- `install_docker()` - Install Docker from official repository with GPG verification
- `install_nvidia_gpu_support()` - Install NVIDIA container toolkit with OS version detection
- `install_docker_containers()` - Start containers from docker-compose.yml
- `pull_ollama_models()` - Pull LLM models with timeout protection

**Key Features:**
- Docker installation adds user to docker group (requires logout/login)
- NVIDIA support detects Ubuntu/Debian versions, supports 20.04+
- Container startup waits configurable seconds (default: 10s)
- Model pulling has 2-hour timeout per model, tracks success/failure

#### base/development.sh
Git configuration, Claude Code installation, and project setup.

**Exported Functions:**
- `configure_git()` - Install Git with interactive user/email configuration
- `install_claude_code()` - Install Claude Code CLI from npm
- `setup_claude_project()` - Create project-specific CLAUDE.md configuration

**Key Features:**
- Git user/email validation (length, format, special characters)
- Sets sensible Git defaults (init.defaultBranch=main, pull.rebase=false, core.editor=vim)
- Creates .gitconfig backup with timestamp
- Claude Code installation uses Ubuntu nodejs repo (not remote scripts - more secure)
- Creates global and project-level CLAUDE.md files

#### base/utilities.sh
Utility packages, system cleanup, and environment validation.

**Exported Functions:**
- `install_utilities()` - Install system utilities (vim, htop, tree, jq, etc.)
- `cleanup_system()` - Remove unnecessary packages and cache
- `validate_environment()` - Validate API keys and .env completeness

**Key Features:**
- Environment validation checks 8 required API keys:
  - OLLAMA_API_KEY, WEBUI_SECRET_KEY, QDRANT_API_KEY, N8N_ENCRYPTION_KEY
  - LANGCHAIN_API_KEY, LANGGRAPH_API_KEY, LANGFLOW_API_KEY, NGINX_AUTH_PASSWORD
- Validates N8N_ENCRYPTION_KEY minimum length (32 chars)
- Validates N8N_ADMIN_EMAIL format (email regex)
- Checks for placeholder values (changeme*, your-*)

## Adding New Installation Steps

### Step 1: Create Installation Function

Create a function that:
1. Checks if already installed (idempotency)
2. Performs installation
3. Tracks added packages/repos
4. Returns 0 on success, 1 on failure

**Example - Installing a utility:**
```bash
# Add to lib/base/utilities.sh

install_kubernetes() {
    # Check if already installed
    if command -v kubectl &>/dev/null; then
        log "Kubernetes already installed ($(kubectl version --client --short)), skipping"
        return 0
    fi

    debug "Installing Kubernetes kubectl"

    # Install from Kubernetes repository
    curl -fsSLo /etc/apt/keyrings/kubernetes-apt-keyring.gpg https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key || return 1

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null || return 1
    track_repo "/etc/apt/sources.list.d/kubernetes.list"

    sudo apt-get update || return 1
    sudo apt-get install -y kubectl || return 1
    track_package "kubectl"

    success "Kubernetes kubectl installed"
}
```

### Step 2: Add to Execution Flow

Add the step to the main installation sequence in `post-install.sh`:

```bash
# In post-install.sh, add in appropriate order
run_step "Kubernetes" install_kubernetes false
```

### Step 3: Update Configuration (if needed)

If your installation needs configurable values, add them to `lib/config.sh`:

```bash
# Add to lib/config.sh
: ${KUBERNETES_VERSION:="v1.28"}
: ${K8S_NAMESPACE:="default"}
```

### Step 4: Update Environment Example

Add required environment variables to `.env.example`:

```bash
# Kubernetes Configuration
KUBERNETES_API_KEY="your-api-key-here"
K8S_CLUSTER_URL="https://your-cluster:6443"
```

### Step 5: Update Documentation

1. Add to README.md "Features" section
2. Document environment variables in SECRETS.md
3. Add health check to verify-installation.sh (optional)

### Step 6: Test Thoroughly

```bash
# Test on fresh Ubuntu VM
./validate-setup.sh        # Pre-flight checks
./post-install.sh          # First run
./post-install.sh          # Second run (verify idempotency)
./verify-installation.sh   # Health checks
```

## Error Handling Patterns

### Pattern 1: Critical Command (must not fail)
```bash
install_myservice() {
    sudo apt-get update || return 1  # MUST succeed or function fails
}
```

### Pattern 2: Non-Critical Command (failure acceptable)
```bash
install_myservice() {
    sudo usermod -aG docker "$USER" || true  # Nice to have, failure ignored
}
```

### Pattern 3: Suppress Expected Errors
```bash
install_myservice() {
    # This fails if command doesn't exist, which is fine
    command -v myservice 2>/dev/null || true
}
```

### Pattern 4: Track Installed Packages
```bash
install_myservice() {
    sudo apt-get install -y myservice || return 1
    track_package "myservice"  # Enable rollback capability
}
```

### Pattern 5: Track Added Repositories
```bash
install_myservice() {
    echo "deb ..." | sudo tee /etc/apt/sources.list.d/myservice.list > /dev/null || return 1
    track_repo "/etc/apt/sources.list.d/myservice.list"  # Enable rollback
}
```

### Pattern 6: Validation and Early Return
```bash
install_myservice() {
    # Check if already done
    if is_myservice_installed; then
        log "MyService already installed, skipping"
        return 0
    fi

    # Validate prerequisites
    if ! command -v dependency &>/dev/null; then
        error "Required dependency not found"
        return 1
    fi

    # Install
    sudo apt-get install -y myservice || return 1
    track_package "myservice"

    success "MyService installed"
}
```

## Testing Guidelines

### Unit Testing (Test Individual Functions)

```bash
#!/bin/bash
source lib/logger.sh
source lib/config.sh

test_get_container_image() {
    local image=$(get_container_image "ollama")
    if [[ "$image" == "ollama/ollama:0.6.0" ]]; then
        echo "✓ Container image resolution works"
        return 0
    else
        echo "✗ Expected ollama/ollama:0.6.0 but got $image"
        return 1
    fi
}

test_validate_config() {
    if validate_config; then
        echo "✓ Configuration validation passed"
        return 0
    else
        echo "✗ Configuration validation failed"
        return 1
    fi
}

test_get_container_image
test_validate_config
```

### Integration Testing (Full Script)

```bash
# Test on fresh Ubuntu 22.04 VM
docker run -it --privileged ubuntu:22.04 bash

# Inside container
apt-get update
apt-get install -y sudo curl git

# Copy script into container
COPY post-install.sh /tmp/

# First run
cd /tmp
./post-install.sh

# Second run (verify idempotency)
./post-install.sh
```

### Manual Testing Checklist

- [ ] Test on Ubuntu 20.04 (Focal)
- [ ] Test on Ubuntu 22.04 (Jammy)
- [ ] Test on Ubuntu 24.04 (Noble) if available
- [ ] Test on minimal Ubuntu (no pre-installed packages)
- [ ] Test with different hardware configs (4GB RAM, 32GB RAM, etc.)
- [ ] Test partial failure recovery (simulate error in middle of script)
- [ ] Verify rollback works correctly
- [ ] Verify idempotency (run script twice)
- [ ] Check service health: `./verify-installation.sh`
- [ ] Verify SSH access (key-based auth only)
- [ ] Check Docker containers are running: `docker ps`
- [ ] Test Ollama models: `curl http://localhost:11434/api/tags`

## Code Style

### Shell Script Style Guide

**Variable Names:**
- Use UPPERCASE for constants/config: `SSH_CONFIG`, `MODEL_PULL_TIMEOUT`
- Use lowercase for local variables: `git_name`, `backup_file`
- Use descriptive names: `available_disk` not `disk`

**Function Names:**
- Installation functions: `install_*` (e.g., `install_docker`)
- Configuration functions: `configure_*` (e.g., `configure_git`)
- Validation functions: `validate_*` (e.g., `validate_environment`)
- Verification functions: `verify_*` (e.g., `verify_ssh_config`)
- Tracking functions: `track_*` (e.g., `track_package`)
- Utility functions: descriptive verb + noun (e.g., `get_container_image`)

**Comments:**
```bash
# Use this for section headers
# ========================================
# Section Name
# ========================================

# Single-line comments for non-obvious code
local backup_file="${config}.backup.$(date +%Y%m%d_%H%M%S)"  # Timestamp for uniqueness

# Multi-line comments for complex logic
# This function validates email format using extended regex
# Matches: user@example.com
# Rejects: user@example, user@.com, @example.com
```

**Error Handling:**
```bash
# Prefer explicit error handling over set -e
sudo apt-get update || return 1

# Use optional operations with || true
sudo usermod -aG docker "$USER" 2>/dev/null || true

# Prefer clear variable names in conditionals
if [ -z "$git_email" ]; then
    error "Email not provided"
    return 1
fi
```

**Quoting:**
```bash
# Always quote variables to prevent word splitting
sudo apt-get install -y "$package"

# Use double quotes for variable expansion
echo "Installing $package_name"

# Use single quotes for literal strings
echo 'This is literal text: $no_expansion'
```

## Debugging Tips

### Enable Debug Logging

```bash
# Run script with debug output
LOG_LEVEL=debug ./post-install.sh

# This will show all debug() messages
```

### Check Log File

```bash
# View installation log
cat .homelab-setup.log

# Follow log in real-time during installation
tail -f .homelab-setup.log
```

### Test Individual Module

```bash
# Source and test a single module
source lib/base/system.sh
source lib/logger.sh
source lib/error-handling.sh

# Test specific function
install_ssh
echo "Exit code: $?"
```

### Validate Configuration Files

```bash
# Test SSH configuration syntax
sudo sshd -t

# Test docker-compose.yml syntax
sudo docker-compose config

# Check nginx configuration
sudo docker run --rm -v /path/to/nginx.conf:/etc/nginx/nginx.conf:ro \
    nginx:alpine nginx -t
```

### Check System Requirements

```bash
# Verify prerequisites
command -v docker && echo "Docker: OK"
command -v docker-compose && echo "Docker Compose: OK"
command -v npm && echo "Node.js: OK"
command -v git && echo "Git: OK"

# Check resources
free -h          # Memory
df -h            # Disk space
nproc            # CPU cores
```

## Common Mistakes to Avoid

### ❌ Mistake 1: Forgetting to Check If Already Installed

```bash
# BAD - Installs every time
install_docker() {
    sudo apt-get install -y docker-ce || return 1
}

# GOOD - Checks first
install_docker() {
    if command -v docker &>/dev/null; then
        log "Docker already installed, skipping"
        return 0
    fi
    sudo apt-get install -y docker-ce || return 1
}
```

### ❌ Mistake 2: Forgetting to Track Packages/Repos

```bash
# BAD - Can't rollback
install_myservice() {
    sudo apt-get install -y myservice || return 1
}

# GOOD - Enables rollback
install_myservice() {
    sudo apt-get install -y myservice || return 1
    track_package "myservice"
}
```

### ❌ Mistake 3: Not Validating User Input

```bash
# BAD - No validation
configure_git() {
    read -p "Enter name: " git_name
    git config --global user.name "$git_name"
}

# GOOD - With validation
configure_git() {
    read -p "Enter name: " git_name
    git_name=$(echo "$git_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ ${#git_name} -lt 2 ]; then
        error "Name must be at least 2 characters"
        return 1
    fi

    git config --global user.name "$git_name"
}
```

### ❌ Mistake 4: Using Unquoted Variables

```bash
# BAD - Can cause word splitting
sudo apt-get install -y $package

# GOOD - Proper quoting
sudo apt-get install -y "$package"
```

### ❌ Mistake 5: Ignoring Return Codes of Critical Commands

```bash
# BAD - Ignores failure
sudo apt-get update || true
sudo apt-get install -y docker-ce || true

# GOOD - Fails on critical error
sudo apt-get update || return 1
sudo apt-get install -y docker-ce || return 1
```

### ❌ Mistake 6: Hardcoding API Keys or Passwords

```bash
# BAD - Hardcoded credentials
NGINX_PASSWORD="mypassword123"
OLLAMA_API_KEY="hardcoded-key"

# GOOD - From environment/configuration
NGINX_PASSWORD="${NGINX_AUTH_PASSWORD}"
OLLAMA_API_KEY="${OLLAMA_API_KEY}"  # Must be set in .env
```

### ❌ Mistake 7: Not Using Log Messages

```bash
# BAD - Silent operation
sudo systemctl restart ssh

# GOOD - User visibility
log "Restarting SSH service..."
sudo systemctl restart ssh || {
    error "Failed to restart SSH"
    return 1
}
```

## Contributing

When submitting changes:

1. **Test on fresh Ubuntu VM** - Verify your changes work on clean installation
2. **Test idempotency** - Run script twice, ensure second run doesn't break things
3. **Check for security issues** - No hardcoded credentials, validate all inputs
4. **Update documentation** - README, CLAUDE.md, .env.example as needed
5. **Follow code style** - Use patterns established in codebase
6. **Write descriptive commit messages** - Explain why, not just what

## Questions?

- Check existing functions in `lib/base/*.sh` for examples
- Read error messages carefully - they often explain the issue
- Enable `LOG_LEVEL=debug` for detailed logging
- Review commit history for similar changes: `git log --oneline --grep="keyword"`

---

Happy contributing! 🎉
