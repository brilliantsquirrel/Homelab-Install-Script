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
echo "  - Git (with user configuration)"
echo "  - Claude Code (with project configuration)"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

log "Starting homelab setup..."

# First, validate environment variables before proceeding
# This is a critical step - fail fast if configuration is missing
if ! validate_environment; then
    error "Environment validation failed. Cannot proceed with installation."
    error "Please fix the errors above and try again."
    exit 1
fi

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
    local compose_file="$(pwd)/docker-compose.yml"

    # Validate docker-compose.yml exists
    if [ ! -f "$compose_file" ]; then
        error "docker-compose.yml not found in current directory: $(pwd)"
        error "Make sure you run this script from the homelab repository directory"
        return 1
    fi

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

    log "Waiting for services to be ready..."
    sleep 10

    log "Docker containers started successfully"
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

configure_git() {
    # Check if Git is already installed
    if ! command -v git &> /dev/null; then
        log "Git not found, installing..."
        sudo apt-get install -y git || return 1
        track_package "git"
    else
        log "Git already installed ($(git --version)), skipping install"
    fi

    # Check if git user.name is configured
    if ! git config --global user.name &> /dev/null; then
        log "Configuring Git user information..."

        local git_name=""
        local git_email=""

        # Prompt for name - validate input
        while [ -z "$git_name" ]; do
            read -p "Enter your Git user name: " git_name

            # Trim whitespace
            git_name=$(echo "$git_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            # Validate length
            if [ ${#git_name} -lt 2 ]; then
                error "Git name must be at least 2 characters"
                git_name=""
                continue
            fi

            if [ ${#git_name} -gt 100 ]; then
                error "Git name must be less than 100 characters"
                git_name=""
                continue
            fi

            # Remove potentially problematic characters
            git_name=$(echo "$git_name" | sed "s/['\`\"\\\\]//g")
        done

        # Prompt for email - validate input
        while [ -z "$git_email" ]; do
            read -p "Enter your Git email: " git_email

            # Trim whitespace
            git_email=$(echo "$git_email" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            # Validate email format
            if ! [[ "$git_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                error "Invalid email format. Please enter a valid email address."
                git_email=""
                continue
            fi
        done

        # Configure Git globally
        git config --global user.name "$git_name" || return 1
        git config --global user.email "$git_email" || return 1

        success "Git configured: $git_name <$git_email>"
    else
        log "Git already configured as: $(git config --global user.name) <$(git config --global user.email)>"
    fi

    # Set sensible Git defaults
    git config --global init.defaultBranch main || return 1
    git config --global pull.rebase false || return 1
    git config --global core.editor vim || return 1

    # Create a .gitconfig backup with timestamp
    local backup_file="$HOME/.gitconfig.backup.$(date +%Y%m%d_%H%M%S)"
    cp ~/.gitconfig "$backup_file" 2>/dev/null || true
    log "Git configuration backed up to: $backup_file"

    log "Git configuration complete"
}

install_claude_code() {
    # Check if Claude Code CLI is already installed
    if command -v claude-code &> /dev/null || command -v claude &> /dev/null; then
        log "Claude Code already installed ($(claude-code --version 2>/dev/null || claude --version 2>/dev/null)), skipping"
        return 0
    fi

    log "Installing Claude Code CLI..."

    # Install Claude Code from official source
    # Claude Code is distributed via npm package manager
    if ! command -v npm &> /dev/null; then
        log "NPM not found, installing Node.js and npm..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - || return 1
        sudo apt-get install -y nodejs || return 1
        track_package "nodejs"
    fi

    # Install Claude Code CLI globally
    sudo npm install -g @anthropic-ai/claude-code || return 1

    # Create .claude directory for project configuration
    mkdir -p "$HOME/.claude" || return 1

    # Create global CLAUDE.md if it doesn't exist
    if [ ! -f "$HOME/.claude/CLAUDE.md" ]; then
        cat > "$HOME/.claude/CLAUDE.md" << 'EOF'
# CLAUDE.md - Global Claude Code Configuration

This file provides global guidance to Claude Code across all projects.

## General Settings

- **Editor**: vim
- **Default Branch**: main
- **Pull Strategy**: merge (not rebase)

## Security Defaults

- **Never Commit Secrets**: .env, .env.local, *.key, *.pem files
- **Validate URLs**: Only use URLs from official sources
- **Check Permissions**: Ensure sensitive files have restrictive permissions (600 for files, 700 for directories)

## Code Style

- Use meaningful variable and function names
- Add comments for complex logic
- Follow existing code patterns in the repository
- Run linters and formatters before committing

## Testing Requirements

- Write tests for new functionality
- Run full test suite before committing
- Document test coverage in pull requests

## Git Best Practices

- Write clear, descriptive commit messages
- Reference issue numbers in commit messages
- Create feature branches for new work
- Use semantic versioning for releases

## Documentation

- Update README when adding features
- Include examples in code comments
- Document breaking changes
- Maintain CHANGELOG.md

## Contact & Support

- Report issues via GitHub Issues
- Use GitHub Discussions for questions
- Check existing issues before creating new ones
EOF
        chmod 644 "$HOME/.claude/CLAUDE.md"
        success "Global CLAUDE.md configuration created at ~/.claude/CLAUDE.md"
    else
        log "Global CLAUDE.md already exists"
    fi

    log "Claude Code CLI installed successfully"
    log "Use 'claude-code' command to start working with projects"
}

setup_claude_project() {
    # Create .claude directory for current project if it doesn't exist
    local project_claude_dir="$(pwd)/.claude"

    if [ ! -d "$project_claude_dir" ]; then
        mkdir -p "$project_claude_dir" || return 1
        log "Created .claude directory for project configuration"
    fi

    # Create project-specific CLAUDE.md if it doesn't exist
    if [ ! -f "$project_claude_dir/CLAUDE.md" ]; then
        cat > "$project_claude_dir/CLAUDE.md" << 'EOF'
# CLAUDE.md - Homelab Install Script Project Configuration

This file provides guidance to Claude Code when working on the Homelab Install Script.

## Project Overview

Homelab automation script for setting up an Ubuntu Server with Docker containers, AI/ML workflows, Git, and Claude Code integration.

## Key Files

- `post-install.sh` - Main installation script
- `docker-compose.yml` - Docker service definitions
- `.env.example` - Environment variables template
- `SECURITY.md` - Security audit and recommendations
- `SECRETS.md` - Secret management guide
- `CLAUDE.md` - This file

## Common Commands

```bash
# Run the installation script
./post-install.sh

# Configure Git user
git config --global user.name "Your Name"
git config --global user.email "your@email.com"

# Start Claude Code session
claude-code

# Start Docker services
docker-compose up -d

# View logs
docker-compose logs -f

# Validate docker-compose
docker-compose config
```

## Important Security Notes

- **Never commit secrets**: .env, API keys, passwords
- **Always use .env.example**: As a template for new deployments
- **Validate changes**: Run security checks before committing
- **Review permissions**: Ensure restrictive file permissions

## Testing Guidelines

- Test on fresh Ubuntu Server installation or VM
- Test idempotency by running script twice
- Verify all services start correctly
- Check container logs for errors
- Test SSH access with key-based auth only

## Documentation Standards

- Update README.md for user-facing changes
- Update CLAUDE.md for development guidance
- Include examples in code comments
- Document new environment variables in .env.example

## Git Workflow

1. Create feature branch: `git checkout -b feature/your-feature`
2. Make changes and test thoroughly
3. Commit with clear messages: `git commit -m "description"`
4. Push to origin: `git push origin feature/your-feature`
5. Create pull request on GitHub

## Performance Considerations

- Minimize external API calls
- Use Docker volumes for persistent data
- Enable database backups
- Monitor disk usage in databases

## Debugging Tips

- Check docker-compose logs: `docker-compose logs service-name`
- Validate shell scripts: `bash -n script.sh`
- Test curl commands: `curl -v https://endpoint`
- Review sshd configuration: `sudo sshd -T`
EOF
        chmod 644 "$project_claude_dir/CLAUDE.md"
        success "Project CLAUDE.md created at ./.claude/CLAUDE.md"
    else
        log "Project CLAUDE.md already exists"
    fi
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

# Validate API keys and critical environment variables
validate_environment() {
    log "Validating environment configuration..."

    # Check if .env file exists
    if [ ! -f .env ]; then
        error ".env file not found"
        error "Please copy .env.example to .env and set all required values:"
        error "  cp .env.example .env"
        error "  nano .env"
        return 1
    fi

    # Load environment variables
    set -a
    source .env
    set +a

    local missing_keys=()
    local invalid_keys=()

    # Check for required API keys (must not be empty or placeholder values)
    local required_keys=(
        "OLLAMA_API_KEY"
        "WEBUI_SECRET_KEY"
        "QDRANT_API_KEY"
        "N8N_ENCRYPTION_KEY"
        "LANGCHAIN_API_KEY"
        "LANGGRAPH_API_KEY"
        "LANGFLOW_API_KEY"
        "NGINX_AUTH_PASSWORD"
    )

    for key in "${required_keys[@]}"; do
        local value="${!key}"

        # Check if key is empty
        if [ -z "$value" ]; then
            missing_keys+=("$key")
            continue
        fi

        # Check if still using placeholder values
        if [[ "$value" == "changeme"* ]] || [[ "$value" == "your-"* ]]; then
            invalid_keys+=("$key")
            continue
        fi
    done

    # Check N8N_ENCRYPTION_KEY minimum length
    if [ -n "${N8N_ENCRYPTION_KEY}" ] && [ ${#N8N_ENCRYPTION_KEY} -lt 32 ]; then
        invalid_keys+=("N8N_ENCRYPTION_KEY (less than 32 characters)")
    fi

    # Validate email if N8N_ADMIN_EMAIL is set
    if [ -n "${N8N_ADMIN_EMAIL}" ]; then
        if ! [[ "${N8N_ADMIN_EMAIL}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            invalid_keys+=("N8N_ADMIN_EMAIL (invalid format)")
        fi
    fi

    # Report missing keys
    if [ ${#missing_keys[@]} -gt 0 ]; then
        error "Missing required environment variables:"
        for key in "${missing_keys[@]}"; do
            echo "  - $key (not set, cannot be empty)"
        done
        return 1
    fi

    # Report invalid keys
    if [ ${#invalid_keys[@]} -gt 0 ]; then
        error "Invalid or placeholder environment variables:"
        for key in "${invalid_keys[@]}"; do
            echo "  - $key (must be set to a real value)"
        done
        error "Generate secure values with: openssl rand -base64 32"
        return 1
    fi

    success "Environment variables validated successfully"
    return 0
}

# Run installation steps
run_step "System Updates" install_system_updates true
run_step "SSH Server" install_ssh false
run_step "SQLite" install_sqlite false
run_step "Docker Engine" install_docker false
run_step "NVIDIA GPU Support" install_nvidia_gpu_support false
run_step "Docker Containers" install_docker_containers false
run_step "Ollama Models" pull_ollama_models false
run_step "Git Configuration" configure_git false
run_step "Claude Code Installation" install_claude_code false
run_step "Claude Project Setup" setup_claude_project false
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
echo "  - SSH is now enabled for remote access (key-based auth only)"
echo "  - Git is configured with your user information"
echo "  - Claude Code is installed globally and ready to use"
echo "  - Project-specific Claude Code configuration at: ./.claude/CLAUDE.md"
echo "  - Global Claude Code configuration at: ~/.claude/CLAUDE.md"
echo "  - Ollama models are being pulled in the background (may take 1-2 hours)"
echo "  - GPU support requires NVIDIA drivers and docker runtime configuration"
echo "  - Find your server IP with: hostname -I"
echo "  - SQLite databases location: ~/.local/share/homelab/databases/"
echo ""
log "For GPU support, uncomment the runtime: nvidia lines in docker-compose.yml"
log "To start using Claude Code: claude-code"
log "Consider rebooting your system to ensure all changes take effect."
