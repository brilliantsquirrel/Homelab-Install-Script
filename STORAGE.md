# Storage Management Guide

This homelab setup includes advanced storage management capabilities to optimize performance and manage large datasets across multiple drives.

## Overview

The installation script allows you to configure custom storage paths for different types of data, enabling you to:
- Use fast storage (SSD/NVMe) for databases and caches
- Use bulk storage (HDD) for media files and user data
- Separate Docker images from application data
- Optimize performance by matching storage tier to workload

## Storage Tiers

### 1. Fast Storage (SSD/NVMe Recommended)
**Purpose**: High-IOPS workloads requiring low latency

**Services**:
- PostgreSQL databases (Nextcloud, LangGraph)
- Redis caches (Nextcloud, LangGraph)
- Qdrant vector database
- SQLite databases (conversations, RAG, workflows, model performance)

**Estimated Size**: 50-100GB for databases, may grow with usage

**Default Path**: `/mnt/fast`

### 2. AI Service Data Storage (SSD Preferred)
**Purpose**: AI/ML application data and working files

**Services**:
- OpenWebUI (chat history, settings)
- n8n (workflows, credentials)
- LangFlow (workflow definitions)
- LangChain (application data)
- Plex configuration and transcoding cache
- Portainer, Homarr, Hoarder, Pi-Hole data

**Estimated Size**: 20-50GB

**Default Path**: `/mnt/ai-data`

### 3. Model Storage (SSD Preferred)
**Purpose**: AI model files (large, frequently accessed)

**Services**:
- Ollama models (20GB+ per large model, 100GB+ total)

**Estimated Size**: 100-500GB depending on models installed

**Default Path**: `/mnt/models`

**Note**: Models benefit significantly from SSD for faster loading

### 4. Bulk Media Storage (HDD Acceptable)
**Purpose**: Large media files with sequential access patterns

**Services**:
- Plex media library (videos, music, photos)

**Estimated Size**: 1TB+ (varies greatly)

**Default Path**: `/mnt/media`

### 5. Nextcloud User Files (HDD Acceptable)
**Purpose**: User documents, uploads, and shared files

**Services**:
- Nextcloud user data

**Estimated Size**: Varies by usage (typically 100GB-1TB+)

**Default Path**: `/mnt/nextcloud`

### 6. Docker Storage
**Purpose**: Container images and layers

**Services**:
- Docker daemon storage

**Estimated Size**: 20-50GB

**Default Path**: `/var/lib/docker` (can be moved to separate drive)

## Configuration

### During Installation

The installation script will prompt you for storage paths after showing recommendations. You can:
- Press Enter to use defaults
- Specify custom paths for each storage tier
- Mix and match storage tiers across different drives

### Example Setup for Dell PowerEdge R630

```
Boot Drive (SSD 250GB):
  - OS and system files
  - /var/lib/docker (optional, can move)

NVMe/SSD 1 (500GB):
  - /mnt/fast → Fast storage (databases, caches)
  - PostgreSQL, Redis, Qdrant, SQLite

NVMe/SSD 2 (500GB):
  - /mnt/ai-data → AI service data
  - /mnt/models → Ollama models

HDD RAID (2TB+):
  - /mnt/media → Plex media library
  - /mnt/nextcloud → Nextcloud user files
```

### Manual Configuration

If you need to reconfigure storage after installation:

1. **Edit storage configuration**:
   ```bash
   nano ~/.homelab-storage.conf
   ```

2. **Update docker-compose override**:
   ```bash
   cd ~/Homelab-Install-Script
   ./post-install.sh
   # Or manually edit docker-compose.override.yml
   ```

3. **Restart containers**:
   ```bash
   docker compose down
   docker compose up -d
   ```

## Storage Configuration File

Storage paths are saved in `~/.homelab-storage.conf`:

```bash
# Homelab Storage Configuration
export DOCKER_STORAGE_PATH="/var/lib/docker"
export FAST_STORAGE_PATH="/mnt/fast"
export AI_STORAGE_PATH="/mnt/ai-data"
export MODEL_STORAGE_PATH="/mnt/models"
export MEDIA_STORAGE_PATH="/mnt/media"
export NEXTCLOUD_STORAGE_PATH="/mnt/nextcloud"
```

## Docker Compose Override

The script generates `docker-compose.override.yml` with custom volume mounts:

```yaml
services:
  ollama:
    volumes:
      - /mnt/models/ollama:/root/.ollama

  qdrant:
    volumes:
      - /mnt/fast/qdrant:/qdrant/storage

  plex:
    volumes:
      - /mnt/ai-data/plex-config:/config
      - /mnt/media:/media
      - /mnt/ai-data/plex-transcode:/transcode
```

## Migrating Existing Data

If you've already installed and want to move data:

### 1. Stop Containers
```bash
docker compose down
```

### 2. Move Data
```bash
# Example: Move Ollama models to new location
sudo rsync -av /var/lib/docker/volumes/ollama_data/_data/ /mnt/models/ollama/

# Example: Move Plex media
sudo rsync -av /var/lib/docker/volumes/plex_media/_data/ /mnt/media/
```

### 3. Update Configuration
```bash
# Edit storage config
nano ~/.homelab-storage.conf

# Regenerate docker-compose.override.yml
cd ~/Homelab-Install-Script
./post-install.sh  # Choose to reconfigure storage
```

### 4. Restart Containers
```bash
docker compose up -d
```

## Performance Optimization

### Database Performance (Fast Storage)
- Use SSD/NVMe for PostgreSQL, Redis, Qdrant
- Enable TRIM for SSDs: `sudo fstrim -av`
- Consider RAID 10 for redundancy + performance

### Model Loading Performance
- Store Ollama models on SSD for 2-3x faster loading
- Use NVMe if available for best performance

### Media Streaming (Bulk Storage)
- HDD is sufficient for Plex streaming (sequential reads)
- RAID 5/6 provides redundancy for large media libraries
- Consider SMR vs CMR drives (CMR preferred)

### Transcoding Performance
- Keep Plex transcode cache on SSD (`/mnt/ai-data/plex-transcode`)
- GPU transcoding is more important than storage speed

## Monitoring Storage Usage

### Check Disk Usage
```bash
# Overall usage
df -h

# Specific paths
du -sh /mnt/fast/*
du -sh /mnt/ai-data/*
du -sh /mnt/models/*
```

### Docker Volume Usage
```bash
# List all volumes and sizes
docker system df -v

# Cleanup unused volumes
docker volume prune
```

### Ollama Model Sizes
```bash
# List models and sizes
docker exec ollama ollama list
```

## Backup Recommendations

### Critical Data (Regular Backups)
- SQLite databases: `/mnt/fast/databases`
- PostgreSQL: Use `pg_dump` (automated in script)
- Configuration files: `~/.homelab-storage.conf`, `.env`

### Large Data (Snapshot/Archive)
- Media files: `/mnt/media` (if replaceable, lower priority)
- Nextcloud: `/mnt/nextcloud` (user data, high priority)
- Ollama models: `/mnt/models` (can re-download, medium priority)

### Backup Script Example
```bash
#!/bin/bash
# Backup critical databases
BACKUP_DIR="/mnt/backup/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# SQLite
cp -r /mnt/fast/databases "$BACKUP_DIR/"

# PostgreSQL
docker exec nextcloud-db pg_dump -U nextcloud nextcloud > "$BACKUP_DIR/nextcloud.sql"
docker exec langgraph-db pg_dump -U langgraph langgraph > "$BACKUP_DIR/langgraph.sql"

# Compress
tar czf "$BACKUP_DIR.tar.gz" "$BACKUP_DIR"
rm -rf "$BACKUP_DIR"
```

## Troubleshooting

### Permission Issues
```bash
# Fix ownership
sudo chown -R $USER:$USER /mnt/fast
sudo chown -R $USER:$USER /mnt/ai-data
sudo chown -R $USER:$USER /mnt/models
```

### Disk Full
```bash
# Find large files
du -ah /mnt/fast | sort -rh | head -20

# Clean Docker
docker system prune -a
docker volume prune
```

### Docker Won't Start After Moving Storage
```bash
# Check Docker daemon config
sudo cat /etc/docker/daemon.json

# Check Docker service status
sudo systemctl status docker

# View logs
sudo journalctl -u docker -n 50
```

### Container Can't Access Volume
```bash
# Check volume mounts
docker inspect <container_name> | grep -A 20 Mounts

# Check file permissions
ls -la /mnt/fast
ls -la /mnt/ai-data
```

## Best Practices

1. **Plan Before Installing**: Review storage requirements and available drives
2. **Use Appropriate Storage Tiers**: Don't waste SSD space on cold data
3. **Monitor Usage**: Set up alerts for disk space (90% full warning)
4. **Regular Backups**: Automate backups of critical data
5. **Test Restores**: Periodically verify backups can be restored
6. **Document Changes**: Note any manual storage path changes
7. **SMART Monitoring**: Enable drive health monitoring (`smartd`)

## Advanced: Offline Docker Image Storage

For installations without internet access, you can pre-download Docker images:

```bash
# On a machine with internet
cd ~/Homelab-Install-Script
docker compose pull
docker save $(docker compose config | grep 'image:' | awk '{print $2}') -o homelab-images.tar

# Transfer homelab-images.tar to target server
# On target server
docker load -i homelab-images.tar
```

## FAQ

**Q: Can I change storage paths after installation?**
A: Yes, edit `~/.homelab-storage.conf` and regenerate `docker-compose.override.yml`, then restart containers.

**Q: Do I need separate drives for each tier?**
A: No, you can use subdirectories on the same drive. Separate drives are recommended for performance.

**Q: What happens if I run out of space?**
A: Services will fail. Monitor disk usage and expand storage proactively.

**Q: Can I use network storage (NAS/NFS)?**
A: Yes, but performance may suffer for databases. Good for media and backups.

**Q: How much space do I really need?**
A: Minimum 100GB fast storage, 500GB for models, 1TB+ for media. See "Storage Tiers" section for details.
