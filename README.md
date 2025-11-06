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

## Usage

```bash
./post-install.sh
```

The script will:
- Prompt for confirmation before proceeding
- Check if each component is already installed
- Continue with remaining steps if non-critical installations fail
- Offer rollback if any failures occur
- Start all Docker services and pull Ollama models

## Service Access

After installation, access services via:
- **Portainer**: `http://<server-ip>:9000`
- **OpenWebUI**: `http://<server-ip>:8080`
- **Ollama API**: `http://<server-ip>:11434`
- **Qdrant Vector DB**: `http://<server-ip>:6333`
- **Qdrant Admin**: `http://<server-ip>:6334`
- **LangChain**: `http://<server-ip>:8000`
- **LangGraph**: `http://<server-ip>:8001`
- **LangFlow**: `http://<server-ip>:7860`
- **n8n**: `http://<server-ip>:5678`

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

This installation includes several security hardening features:

- **Nginx Reverse Proxy**: All services are protected behind nginx with basic authentication
- **SSH Hardening**: Key-based authentication only, root login disabled, password auth disabled
- **API Key Management**: Environment variable-based secret management with `.env` file
- **File Permissions**: Restrictive permissions on databases and sensitive files
- **SSL/TLS Support**: HTTPS with self-signed or custom certificates
- **Rate Limiting**: Built-in rate limiting on API endpoints
- **Security Headers**: Security headers (HSTS, X-Frame-Options, etc.) via nginx

**Important**: Before first use, you must:
1. Copy `.env.example` to `.env` and set strong, random values for all secrets
2. Generate or provide SSL certificates
3. Update nginx basic auth credentials

See [SECRETS.md](SECRETS.md) for detailed setup instructions.

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
