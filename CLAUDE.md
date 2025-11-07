# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Comprehensive homelab automation script for setting up an Ubuntu Server with Docker containers, AI/ML workflows, media services, and network management. Designed for Dell PowerEdge R630 servers (or similar hardware) to create a complete homelab environment with AI services, media streaming, file storage, and network-wide ad blocking. The main executable is `post-install.sh`, which can be integrated into Cubic custom Ubuntu installations. The script is designed to be robust, idempotent, and safe to run multiple times.

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
2. **SSH Server** (non-critical) - Enable remote access with security hardening
3. **SQLite** (non-critical) - Install sqlite3 CLI and create database directory
4. **Cockpit** (non-critical) - Web-based server management interface
5. **Docker Engine** (non-critical) - From official Docker repository
6. **NVIDIA GPU Support** (non-critical) - nvidia-docker for GPU acceleration
7. **Docker Containers** (non-critical) - Starts all services: nginx, Portainer, Ollama, OpenWebUI, LangChain, LangGraph, LangFlow, n8n, Qdrant, Homarr, Hoarder, Plex, Nextcloud (with PostgreSQL and Redis), Pi-Hole
8. **Ollama Models** (non-critical) - Pulls gpt-oss:20b, qwen3-vl:8b, qwen3-coder:30b, qwen3:8b
9. **Git Configuration** (non-critical) - Configure Git with user information
10. **Claude Code Installation** (non-critical) - Install Claude Code CLI globally
11. **Claude Project Setup** (non-critical) - Set up project-specific Claude Code configuration
12. **Utility Packages** (non-critical) - git, vim, htop, tree, unzip, build-essential, net-tools, jq
13. **System Cleanup** (non-critical) - apt autoremove and autoclean

Each step is wrapped in an installation function (e.g., `install_docker()`, `install_ssh()`) that:
- Checks if already installed (idempotency)
- Performs the installation
- Tracks installed packages/repos for rollback
- Returns 1 on failure, 0 on success

### Docker Services

All services are defined in `docker-compose.yml` and orchestrated together. Services are accessed through an nginx reverse proxy with basic authentication for security.

**Management & Infrastructure:**
- **nginx** (ports 80, 443) - Reverse proxy with SSL/TLS and basic authentication
- **docker-socket-proxy** - Security layer restricting Portainer's Docker API access
- **Portainer** - Container management UI (via /portainer)
- **Cockpit** (port 9090) - Web-based server management (direct access, not proxied)

**Homelab Services:**
- **Homarr** - Homelab dashboard and service organizer (via /homarr)
- **Hoarder** - Self-hosted bookmark manager with tagging (via /hoarder)
- **Plex** - Media server with transcoding support (via /plex, optionally port 32400)
- **Nextcloud** - File storage, sync, and collaboration platform (via /nextcloud)
  - **nextcloud-db** - PostgreSQL 16 database for Nextcloud
  - **nextcloud-redis** - Redis cache for Nextcloud performance
- **Pi-Hole** - DNS-based ad blocker (ports 53 UDP/TCP for DNS, web via /pihole)

**AI/ML Services:**
- **Ollama** - LLM runtime with GPU support (via /ollama)
- **OpenWebUI** - Web interface for Ollama (via /openwebui)
- **LangChain** - LLM application framework (via /langchain)
- **LangGraph** - Graph-based workflow engine (via /langgraph)
- **LangFlow** - Visual workflow builder for AI (via /langflow)
- **n8n** - Workflow automation platform (via /n8n)
- **Qdrant** - Vector database for embeddings and semantic search (via /qdrant)

All AI containers are configured with environment variables to connect to Ollama on `http://ollama:11434`.

### Database Services

**SQLite**:
- Installed locally as a package
- Database directory: `~/.local/share/homelab/databases/`
- Useful for storing application data, logs, and metadata
- Can be used by any application on the host or in containers

**Qdrant Vector Database**:
- Runs as a Docker container
- Provides REST API on port 6333
- Admin interface on port 6334
- Stores vector embeddings for semantic search
- Integrates with LLMs for RAG (Retrieval-Augmented Generation)
- Configuration file: `qdrant_config.yaml`

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

### Qdrant Vector Database
Create a collection and manage embeddings:
```bash
# Create a collection (via REST API)
curl -X PUT http://localhost:6333/collections/my-embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": {
      "size": 384,
      "distance": "Cosine"
    }
  }'

# View collections
curl http://localhost:6333/collections

# Delete a collection
curl -X DELETE http://localhost:6333/collections/my-embeddings
```

### SQLite Database Usage
Create and manage local databases:
```bash
# Create a new database
sqlite3 ~/.local/share/homelab/databases/myapp.db

# Execute SQL from shell
sqlite3 ~/.local/share/homelab/databases/myapp.db "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);"

# Connect to database
sqlite3 ~/.local/share/homelab/databases/myapp.db
```

### n8n Workflows
n8n can trigger workflows from HTTP webhooks and integrate with Ollama for AI tasks, Qdrant for embeddings, and SQLite for data storage.

## Homelab Services Usage

### Homarr Dashboard
Homarr is the main dashboard for your homelab. Access at https://<server-ip>/homarr
- Add service cards for all your homelab applications
- Monitor system resources
- Organize services by category
- Create quick-access bookmarks

### Hoarder Bookmark Manager
Self-hosted bookmark manager. Access at https://<server-ip>/hoarder
- Save and organize bookmarks with tags
- Full-text search across saved content
- Import bookmarks from browsers
- Share bookmark collections
- API integration via HOARDER_SECRET_KEY

### Plex Media Server
Media streaming server. Access at https://<server-ip>/plex
- Add media to the plex_media Docker volume
- Enable GPU transcoding by uncommenting GPU config in docker-compose.yml
- Claim your server using PLEX_CLAIM token from https://www.plex.tv/claim/
- Supports hardware transcoding with NVIDIA GPUs

```bash
# Find media volume location
docker volume inspect plex_media

# Or bind mount your media directory
# Edit docker-compose.yml plex service volumes:
#   - /path/to/your/media:/media
```

### Nextcloud File Storage
File sync and collaboration platform. Access at https://<server-ip>/nextcloud
- First-time setup creates admin account
- Uses PostgreSQL database for reliability
- Redis caching for performance
- Upload large files (up to 10GB via nginx config)
- Desktop and mobile sync clients available

```bash
# View Nextcloud logs
docker-compose logs -f nextcloud

# Access Nextcloud CLI (occ)
docker exec -u www-data nextcloud php occ <command>
```

### Pi-Hole DNS Ad Blocker
Network-wide ad blocking. Access at https://<server-ip>/pihole
- Configure devices to use <server-ip> as DNS server
- Or set as router DNS to protect entire network
- Admin password stored in .env file (PIHOLE_PASSWORD)
- Blocks ads, trackers, and malicious domains
- Custom blocklists and whitelists

```bash
# Configure device DNS (example for Linux)
# Edit /etc/resolv.conf or use NetworkManager:
nmcli con mod <connection> ipv4.dns "<server-ip>"
nmcli con up <connection>

# View Pi-Hole logs
docker-compose logs -f pihole

# Update gravity (blocklists)
docker exec pihole pihole -g
```

### Cockpit Server Management
Web-based server administration. Access at https://<server-ip>:9090
- Login with system username/password
- Monitor CPU, memory, disk, network
- Manage systemd services
- View system logs
- Terminal access
- Docker container management (via cockpit-docker plugin)
- Virtual machine management (via cockpit-machines plugin)

## Security Features

### Nginx Reverse Proxy
All services (except Cockpit and Pi-Hole DNS) are accessed through nginx reverse proxy:
- HTTPS with self-signed certificates (replace with Let's Encrypt for production)
- HTTP basic authentication (username: admin, password in .env)
- Rate limiting to prevent abuse (10 req/s for API, 30 req/s for web)
- Security headers (HSTS, X-Frame-Options, CSP, etc.)
- Request size limits (10GB for Nextcloud, 100MB for Plex, 20MB default)

### Docker Socket Proxy
Portainer accesses Docker via socket proxy instead of direct socket mount:
- Restricts API access to read-only operations
- No container start/stop/restart capabilities
- No exec access into containers
- Prevents full system compromise if Portainer is breached

### SSH Hardening
SSH server is automatically hardened:
- Root login disabled
- Password authentication disabled (key-based only)
- Public key authentication required
- X11 forwarding disabled
- Connection timeouts configured
- Original config backed up before changes

## GPU Support

### Ollama GPU Acceleration
Enable GPU for LLM inference:
1. Ensure NVIDIA drivers are installed (script auto-detects and installs nvidia-docker2)
2. Edit docker-compose.yml, uncomment in ollama service:
   ```yaml
   runtime: nvidia
   deploy:
     resources:
       reservations:
         devices:
           - driver: nvidia
             count: 1
             capabilities: [gpu]
   ```
3. Restart containers: `docker-compose up -d`

### Plex GPU Transcoding
Enable GPU for video transcoding:
1. Ensure NVIDIA drivers installed
2. Edit docker-compose.yml, uncomment in plex service:
   ```yaml
   runtime: nvidia
   deploy:
     resources:
       reservations:
         devices:
           - driver: nvidia
             count: 1
             capabilities: [gpu, video, compute, utility]
   ```
3. Restart Plex: `docker-compose restart plex`
4. In Plex settings, enable hardware transcoding

## Network Configuration

### Port Usage
- **53** (TCP/UDP): Pi-Hole DNS
- **80**: HTTP (redirects to HTTPS)
- **443**: HTTPS (nginx reverse proxy)
- **9090**: Cockpit web interface

### Internal Docker Network
All containers communicate on `homelab_network` bridge network:
- Services reference each other by container name
- Example: Ollama is accessible at `http://ollama:11434` from other containers
- Isolated from host network for security

## Backup Recommendations

### Database Backups
```bash
# Nextcloud database
docker exec nextcloud-db pg_dump -U nextcloud nextcloud > nextcloud_backup.sql

# SQLite databases
cp -r ~/.local/share/homelab/databases/ ~/backups/databases_$(date +%F)
```

### Volume Backups
```bash
# Backup all Docker volumes
docker run --rm -v plex_config:/source -v $(pwd):/backup alpine tar czf /backup/plex_config.tar.gz -C /source .
docker run --rm -v nextcloud_data:/source -v $(pwd):/backup alpine tar czf /backup/nextcloud_data.tar.gz -C /source .
docker run --rm -v pihole_etc:/source -v $(pwd):/backup alpine tar czf /backup/pihole_etc.tar.gz -C /source .
```

## Troubleshooting

### Service Not Accessible
1. Check container status: `docker-compose ps`
2. Check nginx logs: `docker-compose logs nginx`
3. Check service logs: `docker-compose logs <service-name>`
4. Verify .env file has all required variables
5. Check nginx basic auth credentials

### Pi-Hole DNS Not Working
1. Verify Pi-Hole is running: `docker-compose ps pihole`
2. Test DNS resolution: `dig @<server-ip> google.com`
3. Check device DNS configuration
4. Verify port 53 is accessible: `sudo netstat -tunlp | grep 53`

### Nextcloud Connection Issues
1. Check trusted domains in config
2. Verify database connection: `docker-compose logs nextcloud-db`
3. Check Redis: `docker-compose logs nextcloud-redis`
4. Ensure OVERWRITEHOST matches your server hostname

### GPU Not Detected
1. Verify NVIDIA drivers: `nvidia-smi`
2. Check nvidia-docker2: `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi`
3. Verify docker-compose.yml GPU config is uncommented
4. Restart Docker daemon: `sudo systemctl restart docker`
