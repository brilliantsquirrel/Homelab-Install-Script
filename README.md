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
3. **Docker Engine** - Official Docker runtime with compose plugin
4. **NVIDIA GPU Support** - For Ollama GPU acceleration (if available)

### Docker Containers
1. **Portainer** - Container management UI
2. **Ollama** - Local LLM runtime with GPU support
3. **OpenWebUI** - Web interface for Ollama
4. **LangChain** - Framework for LLM applications
5. **LangGraph** - Graph-based language workflows
6. **LangFlow** - Visual LLM workflow builder
7. **n8n** - Workflow automation platform

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
- **LangChain**: `http://<server-ip>:8000`
- **LangGraph**: `http://<server-ip>:8001`
- **LangFlow**: `http://<server-ip>:7860`
- **n8n**: `http://<server-ip>:5678`

## Requirements

- Ubuntu Server 20.04+ (or custom Cubic build)
- Regular user with sudo privileges
- Internet connection
- GPU (optional, but recommended for Ollama)
- Minimum 16GB RAM (32GB recommended for larger models)

## Documentation

See [CLAUDE.md](CLAUDE.md) for detailed architecture, implementation details, and guidance on modifying the script.

## License

MIT
