# Homelab Install Script

A robust automation script for setting up an Ubuntu Server homelab with Docker containers and AI/ML workflows.

## Overview

This script automates the setup of a homelab server for general utility and AI workflows. It installs Docker, configures container services (Portainer, Ollama, OpenWebUI, LangChain, LangGraph, LangFlow, n8n), pulls AI models, and sets up network access for all services.

Designed to be used with customized Ubuntu Server installations via Cubic, this script is idempotent, resilient, and can be run multiple times safely.

## Features

- **Idempotent** - Safe to run multiple times; skips already-installed software
- **Resilient** - Non-critical failures don't stop the script
- **Rollback Support** - Can undo changes if failures occur
- **GPU Support** - Ollama configured with GPU access
- **Network Accessible** - All services accessible on local network via URLs
- **User Safe** - Requires confirmation, prevents root execution, tracks all changes
- **Well Documented** - Comprehensive CLAUDE.md for developers

## What Gets Installed

### System Setup
1. **System Updates** - Latest package updates and upgrades
2. **SSH** - Remote access to the server
3. **SQLite** - Lightweight relational database (local)
4. **Docker Engine** - Official Docker runtime with compose plugin
5. **NVIDIA GPU Support** - For Ollama GPU acceleration (if available)

### Docker Containers
1. **Portainer** - Container management UI
2. **Ollama** - Local LLM runtime with GPU support
3. **OpenWebUI** - Web interface for Ollama
4. **LangChain** - Framework for LLM applications
5. **LangGraph** - Graph-based language workflows
6. **LangFlow** - Visual LLM workflow builder
7. **n8n** - Workflow automation platform
8. **Qdrant** - Vector database for embeddings and semantic search

### Development Tools
1. **Git** - Version control with automated user configuration
2. **Claude Code** - CLI tool for AI-assisted development with project configuration

### AI Models (auto-pulled by Ollama)
- `gpt-oss:20b` - Open-source LLM (20 billion parameters)
- `qwen3-vl:8b` - Multimodal model (8B, vision-language)
- `qwen3-coder:30b` - Code-specialized model (30B)
- `qwen3:8b` - General-purpose model (8B)

## Quick Start

### On a Fresh Ubuntu Server Installation

After Ubuntu Server installs and you log in for the first time:

```bash
# 1. Clone the repository
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script

# 2. Run the installation script
./post-install.sh
```

The script will:
- Auto-generate secure API keys if `.env` doesn't exist
- Prompt for your n8n admin email
- Show what will be installed and confirm
- Check if each component is already installed
- Continue with remaining steps if non-critical installations fail
- Offer rollback if any failures occur
- Start all Docker services and pull Ollama models

**Installation Time**: 30-60 minutes (plus 1-2 hours for Ollama model pulling)

### On an Existing Ubuntu Server (Rerun)

The script is **idempotent** - safe to run multiple times:

```bash
cd Homelab-Install-Script
./post-install.sh
```

It will skip already-installed components and only install missing pieces.

## Service Access

All services are protected behind an authenticated nginx reverse proxy for security.

### Secure Access (Recommended - All Services)
All services are accessed through the nginx reverse proxy with basic authentication:

```
https://<server-ip>/
```

You'll be prompted for authentication credentials (username/password).

Individual service URLs (access through nginx reverse proxy):
- **Portainer**: `https://<server-ip>/portainer` (requires auth)
- **OpenWebUI**: `https://<server-ip>/openwebui` (requires auth)
- **Ollama API**: `https://<server-ip>/ollama` (requires auth)
- **Qdrant**: `https://<server-ip>/qdrant` (requires auth)
- **LangChain**: `https://<server-ip>/langchain` (requires auth)
- **LangGraph**: `https://<server-ip>/langgraph` (requires auth)
- **LangFlow**: `https://<server-ip>/langflow` (requires auth)
- **n8n**: `https://<server-ip>/n8n` (requires auth)

### Database Access

- **SQLite**: Local databases at `~/.local/share/homelab/databases/`
- **Qdrant Collections**: REST API at `http://<server-ip>:6333/collections`

### Development Tools Setup

After installation, Git and Claude Code are configured:

- **Git Configuration**: User name and email are set globally during installation
- **Claude Code**: Installed globally with development guidance in `~/.claude/CLAUDE.md`
- **Project Configuration**: Project-specific guidance in `./.claude/CLAUDE.md`

To start using Claude Code:
```bash
claude-code
```

View your Git configuration:
```bash
git config --global --list
```

## Requirements

- Ubuntu Server 20.04+ (or custom Cubic build)
- Regular user with sudo privileges
- Internet connection
- GPU (optional, but recommended for Ollama)
- Minimum 16GB RAM (32GB recommended for larger models)

## Security Features

This installation includes comprehensive security hardening:

### Phase 1 - Critical Security (Implemented)
- **No Hardcoded Credentials**: Dockerfile no longer includes default credentials
- **Docker Socket Protection**: Portainer uses restricted docker-socket-proxy instead of direct socket access
- **Service Isolation**: All services hidden behind authenticated nginx reverse proxy
- **API Key Requirements**: All API keys must be explicitly set (no defaults)
- **Mandatory Credential Generation**: Setup requires generating strong credentials before deployment

### Standard Security Features
- **Nginx Reverse Proxy**: All services protected behind nginx with basic authentication
- **SSH Hardening**: Key-based authentication only, root login disabled, password auth disabled
- **API Key Management**: Environment variable-based secret management with `.env` file
- **File Permissions**: Restrictive permissions on databases and sensitive files (700/600)
- **SSL/TLS Support**: HTTPS with self-signed or custom certificates
- **Rate Limiting**: Built-in rate limiting on API endpoints
- **Security Headers**: Security headers (HSTS, X-Frame-Options, etc.) via nginx

### Before First Use (REQUIRED)
1. **Generate Nginx Credentials** - Must create `.htpasswd` with strong password
   ```bash
   # Create nginx auth directory
   mkdir -p nginx/auth

   # Generate credentials (use strong password)
   NGINX_PASSWORD=$(openssl rand -base64 32)
   docker run --rm nginx:alpine htpasswd -c /dev/stdout admin:$NGINX_PASSWORD > nginx/auth/.htpasswd
   chmod 600 nginx/auth/.htpasswd
   ```

2. **Configure `.env` File** - Copy `.env.example` to `.env` and set strong, random values:
   ```bash
   cp .env.example .env
   # Edit with your secure values:
   # - OLLAMA_API_KEY (generate: openssl rand -base64 32)
   # - WEBUI_SECRET_KEY (generate: openssl rand -base64 32)
   # - QDRANT_API_KEY (generate: openssl rand -base64 32)
   # - N8N_ENCRYPTION_KEY (generate: openssl rand -base64 32, minimum 32 chars)
   # - LANGCHAIN_API_KEY (generate: openssl rand -base64 32)
   # - LANGGRAPH_API_KEY (generate: openssl rand -base64 32)
   # - LANGFLOW_API_KEY (generate: openssl rand -base64 32)
   nano .env
   chmod 600 .env
   ```

3. **Generate or Provide SSL Certificates**
   - Self-signed certificates are auto-generated (suitable for internal networks)
   - For external access, use valid certificates

See [SECRETS.md](SECRETS.md) for detailed setup instructions and [CODE-REVIEW.md](CODE-REVIEW.md) for security audit details.

## Security Audit

A comprehensive security audit has been performed. See [SECURITY.md](SECURITY.md) for:
- Identified vulnerabilities and fixes
- Security best practices
- Deployment recommendations
- Security checklist

## Getting Started

### Quick Setup

```bash
# 1. Clone or download the repository
cd homelab-install-script

# 2. Copy and configure environment variables
cp .env.example .env
nano .env  # Edit with your secure values

# 3. Run the installation script
./post-install.sh

# 4. Change nginx credentials after installation
docker exec nginx-proxy htpasswd -c /etc/nginx/auth/.htpasswd admin
```

### Access Services

After installation, all services are available at:

```
https://<server-ip>/       (nginx reverse proxy)
```

You'll be prompted for nginx basic auth credentials.

Individual service URLs:
- OpenWebUI: `https://<server-ip>/openwebui`
- Qdrant: `https://<server-ip>/qdrant`
- Portainer: `https://<server-ip>/portainer`
- n8n: `https://<server-ip>/n8n`
- etc.

## Documentation

- [README.md](README.md) - This file
- [CLAUDE.md](CLAUDE.md) - Architecture, implementation details, and modification guide
- [SECURITY.md](SECURITY.md) - Security audit, vulnerabilities, and recommendations
- [SECRETS.md](SECRETS.md) - Secret management and setup guide
- [.env.example](.env.example) - Environment variables reference

## License

MIT
