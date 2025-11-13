# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Comprehensive homelab automation script for setting up an Ubuntu Server with Docker containers, AI/ML workflows, media services, and network management. Designed for Dell PowerEdge R630 servers (or similar hardware) to create a complete homelab environment with AI services, media streaming, file storage, and network-wide ad blocking. The main executable is `post-install.sh`, which can be integrated into Cubic custom Ubuntu installations. The script is designed to be robust, idempotent, and safe to run multiple times.

## Files

- `post-install.sh` - Main bash script that performs all installation tasks
- `docker compose.yml` - Docker Compose configuration for all services
- `spec.txt` - Original requirements specification
- `CLAUDE.md` - This file
- `webapp/` - ISO Builder web application (see [ISO Builder Webapp](#iso-builder-webapp) section below)

## Running the Script

```bash
./post-install.sh
```

The script must be run as a regular user (not root) with sudo privileges. It will:
- Prompt for confirmation before proceeding
- Check if each component is already installed (idempotent)
- Continue with remaining steps if non-critical installations fail
- Start Docker containers from docker compose.yml
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
7. **Pi-Hole DNS Configuration** (non-critical) - Generates custom DNS entries for .home domains
8. **Docker Containers** (non-critical) - Starts all services: nginx, Portainer, Ollama, OpenWebUI, LangChain, LangFlow, n8n, Qdrant, Homarr, Hoarder, Plex, Nextcloud (with PostgreSQL and Redis), Pi-Hole
9. **Ollama Models** (non-critical) - Pulls gpt-oss:20b, qwen3-vl:8b, qwen3-coder:30b, qwen3:8b
10. **Git Configuration** (non-critical) - Configure Git with user information
11. **Claude Code Installation** (non-critical) - Install Claude Code CLI globally
12. **Claude Project Setup** (non-critical) - Set up project-specific Claude Code configuration
13. **Utility Packages** (non-critical) - git, vim, htop, tree, unzip, build-essential, net-tools, jq
14. **System Cleanup** (non-critical) - apt autoremove and autoclean

Each step is wrapped in an installation function (e.g., `install_docker()`, `install_ssh()`) that:
- Checks if already installed (idempotency)
- Performs the installation
- Tracks installed packages/repos for rollback
- Returns 1 on failure, 0 on success

### Docker Services

All services are defined in `docker compose.yml` and orchestrated together. Services are accessed through an nginx reverse proxy with basic authentication for security.

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
- **ComfyUI** - Node-based UI for Stable Diffusion and AI image generation (via /comfyui)
- **LangChain** - LLM application framework (via /langchain)
- **LangGraph** - Graph-based workflow engine (via /langgraph)
- **LangFlow** - Visual workflow builder for AI (via /langflow)
- **n8n** - Workflow automation platform (via /n8n)
- **Qdrant** - Vector database for embeddings and semantic search (via /qdrant)

All AI containers are configured with environment variables to connect to Ollama on `http://ollama:11434`.

### AI Database Stack

The homelab includes a complete database stack optimized for AI/ML workloads, combining vector search (Qdrant) with relational/metadata storage (SQLite).

**Qdrant Vector Database**:
- Docker container for high-performance vector similarity search
- REST API on port 6333, gRPC on port 6334
- Optimized configuration in `qdrant_config.yaml`:
  - HNSW indexing for fast nearest-neighbor search
  - 64MB cache, WAL enabled for durability
  - Supports multiple vector sizes (384, 768, 1536, 3072, 4096)
- Perfect for:
  - RAG (Retrieval-Augmented Generation) with embeddings
  - Semantic search over documents
  - Similarity-based recommendations
  - Document clustering and classification

**SQLite for AI Metadata**:
- Lightweight, serverless relational database
- Database directory: `~/.local/share/homelab/databases/`
- Initialization script: `./sqlite-ai-init.sh`
- Pre-configured databases:
  - `conversations.db` - Chat history and messages
  - `rag.db` - RAG document metadata and chunks (vectors in Qdrant)
  - `workflows.db` - AI workflow execution tracking
  - `model_performance.db` - Model benchmarks and usage stats
- Features:
  - Full-text search (FTS5) for hybrid search with Qdrant
  - WAL mode for concurrent access
  - 64MB cache for performance
  - Optimized indexes for AI workloads

**Integration**:
- **Hybrid RAG**: Store text in SQLite, embeddings in Qdrant
- **Conversation tracking**: Messages in SQLite, semantic search in Qdrant
- **Workflow state**: SQLite tracks execution, Qdrant finds similar workflows
- **Performance monitoring**: SQLite logs model calls, tracks costs and latency

See `ai-stack-examples.md` for complete Python code examples.

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
- docker compose.yml has commented GPU configuration
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
docker compose up -d

# Stop all services
docker compose down

# View container logs
docker compose logs -f

# Restart a specific service
docker compose restart ollama
```

To enable GPU support, edit `docker compose.yml` and uncomment the GPU configuration in the ollama service.

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

### AI Database Stack Usage

Initialize AI-optimized SQLite databases:
```bash
# Run initialization script
./sqlite-ai-init.sh

# This creates:
# - conversations.db: Chat history with full-text search
# - rag.db: Document metadata, chunks, embeddings tracking
# - workflows.db: AI workflow execution state and model calls
# - model_performance.db: Benchmarks, metrics, usage statistics
```

**Hybrid RAG Pattern** (Text in SQLite, Vectors in Qdrant):
```python
# 1. Store document metadata in SQLite
sqlite> INSERT INTO documents (doc_id, title, content_hash)
        VALUES ('doc1', 'AI Guide', 'abc123');

# 2. Store document chunks with Qdrant point IDs
sqlite> INSERT INTO chunks (chunk_id, doc_id, content, qdrant_point_id)
        VALUES ('chunk1', 'doc1', 'LLMs use transformers...', 'vec123');

# 3. Store embedding vector in Qdrant
curl -X PUT 'http://qdrant.home:6333/collections/documents/points' \
  -H 'Content-Type: application/json' \
  -d '{
    "points": [{
      "id": "vec123",
      "vector": [0.1, 0.2, ...],
      "payload": {"chunk_id": "chunk1", "doc_id": "doc1"}
    }]
  }'

# 4. Query: Search Qdrant for similar vectors, retrieve full text from SQLite
```

**Conversation Tracking**:
```bash
# Store chat messages
sqlite3 ~/.local/share/homelab/databases/conversations.db

sqlite> INSERT INTO messages (conversation_id, role, content)
        VALUES ('conv1', 'user', 'Explain transformers');
```

**Workflow Monitoring**:
```bash
# Track n8n/LangChain workflow executions
sqlite3 ~/.local/share/homelab/databases/workflows.db

sqlite> SELECT workflow_name, COUNT(*), AVG(duration_ms)
        FROM workflow_executions
        WHERE status = 'completed'
        GROUP BY workflow_name;
```

**Model Performance Analytics**:
```bash
# Analyze model usage
sqlite3 ~/.local/share/homelab/databases/model_performance.db

sqlite> SELECT model_name, AVG(avg_latency_ms), AVG(throughput_tokens_per_sec)
        FROM benchmarks
        GROUP BY model_name;
```

See `ai-stack-examples.md` for complete Python integration examples with Qdrant, SQLite, Ollama, and LangChain.

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
- Enable GPU transcoding by uncommenting GPU config in docker compose.yml
- Claim your server using PLEX_CLAIM token from https://www.plex.tv/claim/
- Supports hardware transcoding with NVIDIA GPUs

```bash
# Find media volume location
docker volume inspect plex_media

# Or bind mount your media directory
# Edit docker compose.yml plex service volumes:
#   - /path/to/your/media:/media
```

### ComfyUI AI Image Generation
Node-based UI for Stable Diffusion and AI image generation. Access at https://<server-ip>/comfyui
- Powerful workflow-based interface for AI image generation
- Supports Stable Diffusion, SDXL, ControlNet, and custom models
- GPU acceleration strongly recommended (CPU mode is very slow)
- Download models from Hugging Face or Civitai into the comfyui_models volume
- Generated images saved to comfyui_output volume

```bash
# View ComfyUI logs
docker compose logs -f comfyui

# Access ComfyUI models directory
docker volume inspect comfyui_models

# Access generated images
docker volume inspect comfyui_output

# Download models (example: Stable Diffusion 1.5)
# Place model files in: comfyui_models/checkpoints/
# ComfyUI will automatically detect them
```

**GPU Setup:**
ComfyUI requires GPU for practical use. Enable by uncommenting GPU config in docker compose.yml (see GPU Support section).

### Nextcloud File Storage
File sync and collaboration platform. Access at https://<server-ip>/nextcloud
- First-time setup creates admin account
- Uses PostgreSQL database for reliability
- Redis caching for performance
- Upload large files (up to 10GB via nginx config)
- Desktop and mobile sync clients available

```bash
# View Nextcloud logs
docker compose logs -f nextcloud

# Access Nextcloud CLI (occ)
docker exec -u www-data nextcloud php occ <command>
```

### Pi-Hole DNS Ad Blocker
Network-wide ad blocking. Access at https://<server-ip>/pihole or https://pihole.home
- Configure devices to use <server-ip> as DNS server
- Or set as router DNS to protect entire network
- Admin password stored in .env file (PIHOLE_PASSWORD)
- Blocks ads, trackers, and malicious domains
- Custom blocklists and whitelists
- **Provides local DNS resolution for .home domains**

**Custom DNS Entries:**
The installation automatically configures Pi-Hole to resolve the following domains to your server:
- `homarr.home` → Dashboard
- `hoarder.home` → Bookmark Manager
- `plex.home` → Media Server
- `nextcloud.home` → File Storage
- `pihole.home` → Pi-Hole Admin
- `cockpit.home` → Server Management (port 9090)
- `ollama.home`, `openwebui.home`, `comfyui.home`, `langchain.home`, `langgraph.home`, `langflow.home`, `n8n.home` → AI Services
- `portainer.home`, `qdrant.home` → Management Services

**DNS Configuration:**

```bash
# Configure device DNS (example for Linux)
# Edit /etc/resolv.conf or use NetworkManager:
nmcli con mod <connection> ipv4.dns "<server-ip>"
nmcli con up <connection>

# Configure device DNS (example for macOS)
# System Preferences > Network > Advanced > DNS
# Add <server-ip> as DNS server

# Configure device DNS (example for Windows)
# Control Panel > Network > Change adapter settings
# Right-click adapter > Properties > IPv4 > Properties
# Use the following DNS server addresses: <server-ip>

# Router configuration (entire network)
# Access your router admin interface
# Find DNS settings (often under DHCP or LAN settings)
# Set primary DNS to <server-ip>
# Set secondary DNS to 1.1.1.1 or 8.8.8.8 (fallback)
```

**Testing DNS Resolution:**
```bash
# Test from a device with Pi-Hole configured as DNS
nslookup homarr.home
dig homarr.home

# Should return your server's IP address
```

**Pi-Hole Management:**
```bash
# View Pi-Hole logs
docker compose logs -f pihole

# Update gravity (blocklists)
docker exec pihole pihole -g

# Restart Pi-Hole DNS
docker compose restart pihole

# View current DNS entries
cat pihole-custom-dns.conf

# Add custom DNS entries
# Edit pihole-custom-dns.conf and add:
# address=/myservice.home/<server-ip>
# Then restart: docker compose restart pihole
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
2. Edit docker compose.yml, uncomment in ollama service:
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
3. Restart containers: `docker compose up -d`

### Plex GPU Transcoding
Enable GPU for video transcoding:
1. Ensure NVIDIA drivers installed
2. Edit docker compose.yml, uncomment in plex service:
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
3. Restart Plex: `docker compose restart plex`
4. In Plex settings, enable hardware transcoding

### ComfyUI GPU Acceleration
Enable GPU for AI image generation (STRONGLY RECOMMENDED):
1. Ensure NVIDIA drivers installed (script auto-detects and installs nvidia-docker2)
2. Edit docker compose.yml, uncomment in comfyui service:
   ```yaml
   runtime: nvidia
   deploy:
     resources:
       reservations:
         devices:
           - driver: nvidia
             count: 1
             capabilities: [gpu, compute, utility]
   ```
3. Restart ComfyUI: `docker compose restart comfyui`
4. Note: ComfyUI requires GPU for practical use - CPU-only mode is extremely slow

## Network Configuration

### Local DNS Resolution (.home domains)

The homelab automatically configures Pi-Hole to provide local DNS resolution for all services using the `.home` top-level domain. This allows you to access services via memorable names instead of IP addresses.

**Setup:**
1. The installation script automatically detects your server's IP address
2. Pi-Hole is configured with custom DNS entries mapping service names to your server IP
3. Configure your devices or router to use the server as DNS server
4. Access services using friendly URLs like `https://plex.home` or `https://homarr.home`

**Available DNS Names:**
- `homarr.home` - Homelab Dashboard
- `hoarder.home` - Bookmark Manager
- `plex.home` - Media Server
- `nextcloud.home` - File Storage & Collaboration
- `pihole.home` - DNS Ad Blocker Admin
- `cockpit.home:9090` - Server Management
- `ollama.home`, `openwebui.home`, `comfyui.home` - AI Services
- `langchain.home`, `langgraph.home`, `langflow.home`, `n8n.home` - AI Workflows
- `portainer.home` - Container Management
- `qdrant.home` - Vector Database
- `homelab.home` - Alias for main server

**Configuration File:** `pihole-custom-dns.conf`
- Automatically generated during installation
- Can be manually edited to add custom DNS entries
- Restart Pi-Hole after changes: `docker compose restart pihole`

### Port Usage
- **53** (TCP/UDP): Pi-Hole DNS (for .home domain resolution and ad blocking)
- **80**: HTTP (redirects to HTTPS)
- **443**: HTTPS (nginx reverse proxy for all services)
- **9090**: Cockpit web interface (direct access, not proxied)

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
1. Check container status: `docker compose ps`
2. Check nginx logs: `docker compose logs nginx`
3. Check service logs: `docker compose logs <service-name>`
4. Verify .env file has all required variables
5. Check nginx basic auth credentials

### Pi-Hole DNS Not Working
1. Verify Pi-Hole is running: `docker compose ps pihole`
2. Test DNS resolution: `dig @<server-ip> google.com`
3. Check device DNS configuration
4. Verify port 53 is accessible: `sudo netstat -tunlp | grep 53`

### Nextcloud Connection Issues
1. Check trusted domains in config
2. Verify database connection: `docker compose logs nextcloud-db`
3. Check Redis: `docker compose logs nextcloud-redis`
4. Ensure OVERWRITEHOST matches your server hostname

### GPU Not Detected
1. Verify NVIDIA drivers: `nvidia-smi`
2. Check nvidia-docker2: `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi`
3. Verify docker compose.yml GPU config is uncommented
4. Restart Docker daemon: `sudo systemctl restart docker`

---

## ISO Builder Webapp

**Location:** `webapp/`

A complete web-based application for building custom Ubuntu Server ISOs with selectable homelab services and pre-downloaded AI models. Users can choose which Docker services and Ollama models to include via a web interface, initiate the build on Google Cloud Platform, and download the resulting ISO file.

### Overview

The ISO Builder Webapp transforms the manual ISO building process (iso-prepare.sh and create-custom-iso.sh) into a hosted web service. Instead of running scripts locally, users access a web interface to:

1. Select Docker services (Ollama, Nextcloud, Plex, Pi-Hole, etc.)
2. Choose Ollama AI models to pre-download
3. Configure build settings (GPU support, email, ISO name)
4. Monitor real-time build progress
5. Download the completed custom ISO OR flash directly to USB drive

The webapp orchestrates Google Cloud Compute Engine VMs to perform the actual ISO builds, with results stored in Google Cloud Storage.

### Architecture

**Frontend (Single-Page Application):**
- **Location:** `webapp/frontend/`
- **Technology:** HTML5, CSS3, Vanilla JavaScript
- **Features:**
  - 5-step wizard interface (service selection → model selection → configuration → build progress → download)
  - Automatic dependency resolution (e.g., selecting Nextcloud auto-selects PostgreSQL)
  - Real-time build progress tracking with detailed logs
  - Mobile-responsive design with modern card-based UI
  - Size and time estimation based on selections

**Backend (Node.js/Express API):**
- **Location:** `webapp/backend/`
- **Technology:** Node.js 18, Express 4.x, Google Cloud SDKs
- **Components:**
  - `server.js` - Main Express server with security middleware (CORS, Helmet, rate limiting)
  - `config/config.js` - Centralized service and model metadata, VM configuration
  - `lib/gcs-manager.js` - Google Cloud Storage operations (signed URLs, artifact caching)
  - `lib/vm-manager.js` - GCP Compute Engine VM lifecycle management
  - `lib/build-orchestrator.js` - Build queue, status tracking, progress estimation
  - `routes/services.js` - Service/model metadata API endpoints
  - `routes/build.js` - Build management API (start, status, download, cancel)

**Build Scripts:**
- **Location:** `webapp/scripts/`
- `iso-prepare-dynamic.sh` - Modified version that reads `SELECTED_SERVICES` and `SELECTED_MODELS` environment variables
  - Generates custom docker-compose.yml with only selected services
  - Downloads only required Docker images and Ollama models
  - **Automatic GCS artifact caching**: Downloads check GCS first for cached artifacts; newly downloaded artifacts are automatically uploaded to GCS cache in the background for faster subsequent builds
  - Waits for all background cache uploads to complete before finishing
  - Handles GPU configuration automatically

**Deployment Files:**
- **Location:** `webapp/` and `webapp/deployment/`
- `Dockerfile` - Production-ready container image for Cloud Run
- `.gcloudignore` - Excludes large directories (cubic-artifacts, iso-artifacts) from upload
- `deploy.sh` - Automated deployment script (interactive, handles everything from scratch)
- `cleanup.sh` - Complete resource removal script
- `deployment/app.yaml` - App Engine configuration (alternative deployment)
- `deployment/cloudbuild.yaml` - CI/CD pipeline for Cloud Build

**USB Flasher Tool:**
- **Location:** `webapp/flasher/`
- **Technology:** Node.js CLI application with cross-platform support
- **Purpose:** Creates bootable USB drives directly from ISO download URLs
- **Features:**
  - Cross-platform USB drive detection (Windows, macOS, Linux)
  - Integrated ISO download with progress tracking
  - Interactive drive selection with safety confirmations
  - Automatic unmounting and safe ejection
  - Progress indicators during write operations
  - Temporary file cleanup
- **Usage:**
  ```bash
  # Run directly with npx (no installation required)
  npx homelab-iso-flasher --url="<iso-download-url>"

  # Or install globally
  npm install -g homelab-iso-flasher
  homelab-iso-flasher --url="<iso-download-url>"
  ```
- **Platform Support:**
  - **Linux**: Full automated flashing support (requires sudo)
  - **macOS**: Full automated flashing support (requires admin password)
  - **Windows**: Downloads ISO and provides instructions for Rufus/balenaEtcher (automated flashing coming soon)
- **Documentation:** See `webapp/flasher/README.md` for detailed usage instructions

### Deployment

The webapp is designed for zero-resource deployment on Google Cloud Platform. Use the automated deployment script for the easiest setup:

```bash
cd webapp
./deploy.sh
```

The deployment script handles:
1. Google Cloud authentication check
2. Project creation or selection
3. Region selection
4. API enablement (Compute, Storage, Cloud Build, Cloud Run, etc.)
5. GCS bucket creation (artifacts and downloads)
6. IAM permission configuration
7. Cloud Run deployment
8. Health check and verification
9. Opening webapp in browser

**Expected costs per ISO build:** ~$7-8 (VM: $0.80-1.60, Local SSD: $0.24, Egress: $6.00)

**Alternative deployment options:**
- **Manual Cloud Run deployment:** See `webapp/QUICKSTART.md`
- **App Engine deployment:** See `webapp/deployment/DEPLOYMENT.md`
- **GKE deployment:** See `webapp/deployment/DEPLOYMENT.md`
- **CI/CD with Cloud Build:** Use `webapp/deployment/cloudbuild.yaml`

### API Endpoints

**Service Metadata:**
- `GET /api/services` - Available Docker services with dependencies, sizes, categories
- `GET /api/models` - Available Ollama models with sizes
- `GET /api/config` - Public configuration (rate limits, timeouts, etc.)

**Build Management:**
- `POST /api/build` - Start new ISO build (requires: services, models, gpu_enabled, email, iso_name)
- `GET /api/build/:buildId/status` - Get build progress and logs
- `GET /api/build/:buildId/download` - Get signed download URL for completed ISO
- `DELETE /api/build/:buildId` - Cancel running build

**Health Check:**
- `GET /health` - Service health status

### Build Process

1. **Queued** (0%) - Build request received and validated
2. **Creating VM** (10%) - GCP Compute Engine VM being provisioned (n2-standard-16 with 2x local SSD)
3. **Downloading Dependencies** (20-40%) - VM downloads Docker images and Ollama models (uses GCS cache)
4. **Building ISO** (40-80%) - Custom Ubuntu ISO creation with selected services
5. **Uploading ISO** (80-95%) - ISO uploaded to GCS downloads bucket
6. **Complete** (100%) - ISO ready for download via signed URL (1 hour expiration)
7. **Cleanup** - VM automatically terminated, temporary files removed

**Build time:** 30-90 minutes depending on selections and cache hits

### Security Features

- **Rate limiting:** 10 requests per 15 minutes per IP
- **Input validation:** All user inputs validated (services, models, ISO name)
- **VM isolation:** Each build runs in isolated VM with minimal IAM permissions
- **Signed URLs:** Downloads use signed URLs with 1-hour expiration
- **Automatic cleanup:** ISOs deleted after 7 days (GCS lifecycle policy)
- **CORS restrictions:** API access limited to allowed origins
- **Security headers:** Helmet.js provides comprehensive HTTP security headers
- **Build limits:** Maximum 3 concurrent builds, 3 per user per day

### Configuration

**Environment Variables (backend/.env):**
```bash
# GCP Configuration
GCP_PROJECT_ID=your-project-id
GCP_ZONE=us-west1-a
GCP_REGION=us-west1

# GCS Buckets
GCS_ARTIFACTS_BUCKET=project-id-artifacts
GCS_DOWNLOADS_BUCKET=project-id-downloads

# VM Configuration
VM_MACHINE_TYPE=n2-standard-16
VM_BOOT_DISK_SIZE=500
VM_LOCAL_SSD_COUNT=2

# Build Configuration
MAX_CONCURRENT_BUILDS=3
BUILD_TIMEOUT_HOURS=4
VM_AUTO_CLEANUP=true

# Security
API_SECRET_KEY=random-secret-key
LOG_LEVEL=info
```

**Service Configuration:**
All service metadata is defined in `backend/config/config.js`:
- Service names, display names, descriptions
- Categories (AI, Homelab, Infrastructure)
- Docker image mappings
- Dependencies (e.g., Nextcloud requires PostgreSQL and Redis)
- Size estimates

**Model Configuration:**
All Ollama model metadata is defined in `backend/config/config.js`:
- Model names, display names, descriptions
- Size in GB
- Compatible with Ollama 0.12.9+

### Documentation

- **README.md** - Complete project overview, architecture, API docs, deployment options
- **GETTING-STARTED.md** - User-friendly navigation hub for all documentation
- **QUICKSTART.md** - Step-by-step zero-to-production deployment guide (30+ pages)
- **IMPLEMENTATION_SUMMARY.md** - Technical implementation details, file descriptions
- **deployment/DEPLOYMENT.md** - Production deployment guide (Cloud Run, App Engine, GKE)

### Recent Changes and Bug Fixes

**2025-11-11: JSON Parsing Error Fix**
- **Issue:** Frontend error "Unexpected token 'T', "Too many r"... is not valid JSON" when rate limited
- **Root cause:** Rate limiter returned plain text, but frontend always tried to parse as JSON
- **Fix:**
  - Frontend: Check Content-Type header, handle both JSON and text responses
  - Backend: Rate limiter now returns JSON with `{error: "...", retryAfter: seconds}`
  - Added logging for rate limit violations with request context
- **Files modified:** `webapp/frontend/js/api.js`, `webapp/backend/server.js`

**2025-11-11: Enhanced Logging System**
- **Feature:** Comprehensive logging with context tracking and performance metrics
- **Enhancements:**
  - Request ID tracking across all components (format: `[req:12345678]`)
  - Build ID context in all build-related operations (format: `[build:12345678]`)
  - Component-based logging (format: `[VMManager]`, `[BuildOrchestrator]`)
  - Performance metrics for VM operations and API requests
  - Slow request detection (>1000ms) with warnings
  - Structured error logging with stack traces and context
  - Log rotation (10MB max, multiple files)
  - Request/response logging middleware
  - Detailed VM operation polling with progress updates
- **Files added:** `webapp/backend/middleware/request-logger.js`
- **Files modified:** `webapp/backend/lib/logger.js`, `webapp/backend/lib/vm-manager.js`, `webapp/backend/server.js`
- **Log format example:** `2025-11-11 14:23:45.123 [info] [req:a1b2c3d4] [build:e5f6g7h8] [VMManager]: VM created successfully {"duration":"45230ms","vmName":"iso-builder-e5f6g7h8"}`

**2025-11-11: VM Manager API Fix**
- **Issue:** Runtime error "this.instancesClient.wait is not a function" when creating VMs
- **Root cause:** InstancesClient doesn't have a wait() method in @google-cloud/compute library
- **Fix:** Import and use ZoneOperationsClient for polling operation status
  - Added `ZoneOperationsClient` import from `@google-cloud/compute`
  - Initialize `operationsClient` in constructor
  - Changed `waitForOperation()` to use `operationsClient.get()` instead of non-existent `instancesClient.wait()`
- **Files modified:** `webapp/backend/lib/vm-manager.js`

**2025-11-11: ISO Name Validation Fix**
- **Issue:** Default ISO name `ubuntu-24.04.3-homelab-custom` was rejected by validation
- **Root cause:** Regex `/^[a-zA-Z0-9-_]+$/` in `build-orchestrator.js:272` didn't allow periods
- **Fix:** Changed regex to `/^[a-zA-Z0-9._-]+$/` to allow periods, hyphens, underscores
- **Files modified:** `webapp/backend/lib/build-orchestrator.js`

**2025-11-11: Deployment Fixes**
- **Issue:** npm ci failed during Docker build (no package-lock.json)
- **Fix:** Changed Dockerfile to use `npm install --only=production` instead of `npm ci`
- **Issue:** 53GB upload during Cloud Build (cubic-artifacts directory)
- **Fix:** Created `.gcloudignore` to exclude large directories
- **Result:** Reduced upload size from 53.1 GiB to 764.8 KiB
- **Issue:** deploy.sh used Buildpacks instead of Dockerfile
- **Fix:** Updated deploy.sh to use two-step process: `gcloud builds submit` then `gcloud run deploy --image`

### Integration with Homelab Scripts

The ISO Builder Webapp builds custom ISOs that, when installed, will run the main `post-install.sh` script with pre-downloaded dependencies. The relationship:

1. **Webapp builds ISO** → Custom Ubuntu Server ISO with selected services
2. **ISO includes:**
   - Pre-downloaded Docker images (saved as .tar archives)
   - Pre-downloaded Ollama models
   - Custom docker-compose.yml with only selected services
   - All homelab scripts (post-install.sh, etc.)
3. **User installs ISO** → Ubuntu Server installed with homelab files in `/opt/homelab`
4. **post-install.sh runs** → Loads pre-downloaded images, starts selected services

**Benefit:** First boot is much faster because Docker images and AI models don't need to be downloaded from the internet.

### Troubleshooting

**Viewing Logs:**
```bash
# View real-time logs from Cloud Run
gcloud run services logs tail iso-builder --region us-west1 --project cloud-ai-server

# View logs for specific request (using request ID from error)
gcloud run services logs read iso-builder --region us-west1 --project cloud-ai-server --filter="req:a1b2c3d4"

# View logs for specific build
gcloud run services logs read iso-builder --region us-west1 --project cloud-ai-server --filter="build:e5f6g7h8"

# View only errors
gcloud run services logs read iso-builder --region us-west1 --project cloud-ai-server --filter="severity>=ERROR"

# View performance logs (slow requests)
gcloud run services logs read iso-builder --region us-west1 --project cloud-ai-server --filter="Slow request detected"

# View VM operation logs
gcloud run services logs read iso-builder --region us-west1 --project cloud-ai-server --filter="VMManager"
```

**Log Format:**
Logs include context identifiers for easy filtering:
- `[req:12345678]` - Request ID (first 8 chars of UUID)
- `[build:12345678]` - Build ID (first 8 chars)
- `[VMManager]`, `[BuildOrchestrator]` - Component name
- Timestamps include milliseconds for precise timing
- Performance metrics show operation duration

**Webapp deployment fails:**
```bash
# Check Cloud Build logs
gcloud builds list --limit 5
gcloud builds log BUILD_ID

# Check service status
gcloud run services describe iso-builder --region REGION

# View service logs
gcloud run services logs tail iso-builder --region REGION
```

**Build fails or gets stuck:**
```bash
# Check VM status
gcloud compute instances list --filter="labels.purpose=iso-builder"

# View VM serial port output
gcloud compute instances get-serial-port-output VM_NAME --zone ZONE

# Manually delete stuck VM
gcloud compute instances delete VM_NAME --zone ZONE
```

**ISO download not working:**
```bash
# Check if ISO exists in bucket
gsutil ls gs://PROJECT_ID-downloads/

# Verify bucket permissions
gsutil iam get gs://PROJECT_ID-downloads

# Check signed URL expiration (default: 1 hour)
```

**USB flasher issues:**
```bash
# No USB drives detected
# - Ensure USB drive is inserted and recognized by system
# - Check with: lsblk (Linux) or diskutil list (macOS)
# - Try re-inserting the USB drive

# Permission denied errors
# - Linux/macOS: Run with sudo when prompted
# - Windows: Run terminal as Administrator

# Download failed
# - Verify URL is not expired (signed URLs valid for 1 hour)
# - Generate new download URL from webapp
# - Check internet connection and disk space

# Write failed
# - Try different USB drive
# - Ensure USB drive has 8GB+ capacity
# - Check drive is not write-protected
# - Verify with: sudo badblocks -sv /dev/sdX (Linux)

# For detailed troubleshooting, see webapp/flasher/README.md
```

**Cost monitoring:**
```bash
# View current costs
gcloud billing accounts list
open "https://console.cloud.google.com/billing"

# Set up budget alerts
gcloud billing budgets create \
  --billing-account=BILLING_ACCOUNT_ID \
  --display-name="ISO Builder Budget" \
  --budget-amount=100USD \
  --threshold-rule=percent=50 \
  --threshold-rule=percent=90
```

### Cleanup

To completely remove all webapp resources:
```bash
cd webapp
./cleanup.sh
```

This removes:
- Cloud Run service
- All ISO builder VMs
- GCS buckets (artifacts and downloads)
- Container images
- Deployment info file

The GCP project itself is not deleted (manual step if desired).
