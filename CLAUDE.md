# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Homelab automation script for setting up an Ubuntu Server with Docker containers and AI/ML workflows. The main executable is `post-install.sh`, which can be integrated into Cubic custom Ubuntu installations. The script is designed to be robust, idempotent, and safe to run multiple times.

## Files

- `post-install.sh` - Main bash script that performs all installation tasks
- `docker-compose.yml` - Docker Compose configuration for all services
- `spec.txt` - Original requirements specification
- `CLAUDE.md` - This file

## Running the Script

```bash
./post-install.sh
```

The script must be run as a regular user (not root) with sudo privileges. It will:
- Prompt for confirmation before proceeding
- Check if each component is already installed (idempotent)
- Continue with remaining steps if non-critical installations fail
- Start Docker containers from docker-compose.yml
- Pull AI models into Ollama
- Offer rollback if any failures occur

## Script Architecture

### Core Components

**Installation Tracking**:
- `INSTALL_STATUS` - Associative array tracking success/failure of each step
- `FAILED_STEPS` - Array of failed installation names
- `INSTALLED_PACKAGES` - Tracks packages installed during this run (for rollback)
- `ADDED_REPOS` - Tracks repositories added during this run (for rollback)

**Key Functions**:
- `run_step(name, function, critical)` - Executes installation steps with error tracking
- `rollback()` - Removes installed packages and repos if failures occur
- `track_package(name)` - Records package installation for potential rollback
- `track_repo(name)` - Records repository addition for potential rollback
- Logging: `log()`, `error()`, `warning()`, `success()`

### Installation Phases

The script executes these steps sequentially:

1. **System Updates** (critical) - apt-get update/upgrade
2. **SSH Server** (non-critical) - Enable remote access
3. **Docker Engine** (non-critical) - From official Docker repository
4. **NVIDIA GPU Support** (non-critical) - nvidia-docker for GPU acceleration
5. **Docker Containers** (non-critical) - Starts Portainer, Ollama, OpenWebUI, LangChain, LangGraph, LangFlow, n8n
6. **Ollama Models** (non-critical) - Pulls gpt-oss:20b, qwen3-vl:8b, qwen3-coder:30b, qwen3:8b
7. **Utility Packages** (non-critical) - git, vim, htop, tree, unzip, build-essential, net-tools, jq
8. **System Cleanup** (non-critical) - apt autoremove and autoclean

Each step is wrapped in an installation function (e.g., `install_docker()`, `install_ssh()`) that:
- Checks if already installed (idempotency)
- Performs the installation
- Tracks installed packages/repos for rollback
- Returns 1 on failure, 0 on success

### Docker Services

All services are defined in `docker-compose.yml` and orchestrated together:

- **Portainer** (port 9000) - Container management UI
- **Ollama** (port 11434) - LLM runtime with GPU support
- **OpenWebUI** (port 8080) - Web interface for Ollama
- **LangChain** (port 8000) - LLM application framework
- **LangGraph** (port 8001) - Graph-based workflows
- **LangFlow** (port 7860) - Visual workflow builder
- **n8n** (port 5678) - Workflow automation

All containers are configured with environment variables to connect to Ollama on `http://ollama:11434`.

### Ollama Models

Models are automatically pulled in the following order:
1. `gpt-oss:20b` - 20 billion parameter open-source LLM
2. `qwen3-vl:8b` - 8B multimodal vision-language model
3. `qwen3-coder:30b` - 30B code-specialized model
4. `qwen3:8b` - 8B general-purpose model

Each model pull is wrapped with error handling to continue if one fails.

## Key Implementation Details

### Error Handling
- Uses `run_step()` wrapper instead of strict `set -e`
- Critical steps (System Updates) abort on failure and trigger rollback
- Non-critical steps log failures but continue execution
- All commands use `|| return 1` pattern to propagate errors
- Optional operations use `|| true` to ignore failures
- Final summary shows all failed steps

### Idempotency
- Each installation function checks if software is already installed
- Safe to run multiple times without reinstalling
- Skips already-installed components with log message
- Docker containers are health-checked before pulling models

### Rollback Capability
- Tracks all packages and repos added during execution
- On critical failure: automatically offers rollback
- On any failures: offers rollback at end of script
- Removes tracked packages with `apt-get remove`
- Removes tracked repos (PPAs and repository files)
- Interactive confirmation before executing rollback

### GPU Support
- Detects NVIDIA GPU via `nvidia-smi`
- Installs nvidia-docker2 toolkit if GPU is present
- docker-compose.yml has commented GPU configuration
- Users uncomment `runtime: nvidia` lines to enable GPU

### Logging System
- Color-coded output: green (info/success), red (error), yellow (warning), blue (headers)
- Structured messages with `[INFO]`, `[ERROR]`, `[WARNING]`, `[SUCCESS]` tags
- Progress tracking with step names
- Final summary with success/failure report

### User Safety
- Prevents running as root
- Requires explicit confirmation before starting
- Shows complete list of what will be installed
- Prompts before rollback operations
- Displays post-install notes (service access URLs, important reminders)

## Modifying the Script

When adding new installation steps:

1. **Create installation function**:
   ```bash
   install_myservice() {
       # Check if already installed
       if command -v myservice &> /dev/null; then
           log "MyService already installed, skipping"
           return 0
       fi

       # Perform installation
       sudo apt-get install -y myservice || return 1
       track_package "myservice"
   }
   ```

2. **Add to execution flow**:
   ```bash
   run_step "MyService" install_myservice false  # false = non-critical
   ```

3. **Error handling guidelines**:
   - Use `|| return 1` for critical operations
   - Use `|| true` for genuinely optional operations (cleanup, group add)
   - Use `2>/dev/null || true` to suppress expected errors

4. **Track installations**:
   - Call `track_package("name")` after successful package install
   - Call `track_repo("ppa:..." or "/path/to/list")` after adding repos

5. **Testing**:
   - Test on fresh Ubuntu Server installation or VM
   - Test idempotency by running twice
   - Test failure handling by simulating errors
   - Verify rollback removes added components

## Docker Compose Usage

Manually manage containers:

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# View container logs
docker-compose logs -f

# Restart a specific service
docker-compose restart ollama
```

To enable GPU support, edit `docker-compose.yml` and uncomment the GPU configuration in the ollama service.

## Service Integration

### Ollama Models
Pull additional models into Ollama:
```bash
docker exec ollama ollama pull llama2
docker exec ollama ollama pull mistral
```

### LangChain Integration
LangChain connects to Ollama via environment variable `OLLAMA_BASE_URL=http://ollama:11434`

### n8n Workflows
n8n can trigger workflows from HTTP webhooks and integrate with Ollama for AI tasks.
