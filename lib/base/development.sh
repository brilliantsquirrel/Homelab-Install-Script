#!/bin/bash

# Development Module - Git and Claude Code installation
# Usage: source lib/base/development.sh
# Provides: configure_git, install_claude_code, setup_claude_project

# ========================================
# Git Configuration
# ========================================

# Configure Git with user information and sensible defaults
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
    git config --global init.defaultBranch "${GIT_DEFAULT_BRANCH:-main}" || return 1
    git config --global pull.rebase false || return 1
    git config --global core.editor vim || return 1

    debug "Git defaults configured"

    # Create a .gitconfig backup with timestamp
    local backup_file="$HOME/.gitconfig.backup.$(date +%Y%m%d_%H%M%S)"
    cp ~/.gitconfig "$backup_file" 2>/dev/null || true
    log "Git configuration backed up to: $backup_file"

    success "Git configuration complete"
}

# ========================================
# Claude Code CLI Installation
# ========================================

# Install Claude Code CLI from npm
install_claude_code() {
    # Check if Claude Code CLI is already installed
    if command -v claude-code &> /dev/null || command -v claude &> /dev/null; then
        log "Claude Code already installed ($(claude-code --version 2>/dev/null || claude --version 2>/dev/null)), skipping"
        return 0
    fi

    log "Installing Claude Code CLI..."

    # Install Node.js and npm from Ubuntu repositories (safer than remote scripts)
    if ! command -v npm &> /dev/null; then
        log "NPM not found, installing Node.js and npm from Ubuntu repositories..."

        # Use Ubuntu repositories instead of remote script execution (security best practice)
        sudo apt-get install -y nodejs npm || {
            error "Failed to install Node.js from Ubuntu repositories"
            error "You may need to add NodeSource repository manually"
            return 1
        }

        track_package "nodejs"
        track_package "npm"

        debug "Verifying npm installation"
        # Verify installation
        if ! command -v npm &> /dev/null; then
            error "npm not available after installation"
            return 1
        fi

        log "Node.js and npm installed successfully"
    else
        log "Node.js and npm already installed ($(node --version), $(npm --version))"
    fi

    # Install Claude Code CLI globally
    log "Installing Claude Code CLI via npm..."

    # Use package name from configuration if available
    local claude_package="${CLAUDE_CODE_PACKAGE:-@anthropic-ai/claude-code}"

    sudo npm install -g "$claude_package" || {
        error "Failed to install Claude Code CLI"
        error "Try manually: sudo npm install -g $claude_package"
        return 1
    }

    debug "Verifying Claude Code installation"
    # Verify installation
    if ! command -v claude-code &> /dev/null && ! command -v claude &> /dev/null; then
        error "Claude Code installation could not be verified"
        return 1
    fi

    success "Claude Code CLI installed successfully"

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
        debug "Global CLAUDE.md already exists"
    fi

    log "Claude Code CLI ready for use"
    log "Use 'claude-code' command to start working with projects"
}

# ========================================
# Claude Code Project Setup
# ========================================

# Set up Claude Code configuration for the current project
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
        debug "Project CLAUDE.md already exists"
    fi
}
