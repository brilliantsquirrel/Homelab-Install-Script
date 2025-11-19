# Docker Secrets Migration Guide

## Overview

This guide documents the migration from environment variables to Docker secrets for sensitive credentials. Docker secrets provide better security by:

1. **Not visible in `docker inspect`** - Secrets are mounted as files, not environment variables
2. **Not visible in process list** - `/proc/1/environ` doesn't contain secrets
3. **Not logged** - Container startup logs don't expose secrets
4. **Encrypted at rest** - Docker stores secrets encrypted in Swarm mode

## Migration Status

**Status:** IMPLEMENTED ✅
**Date:** 2025-11-18
**Impact:** All 13 sensitive credentials migrated to Docker secrets

## What Changed

### Before (Environment Variables)
```yaml
services:
  ollama:
    environment:
      - OLLAMA_API_KEY=${OLLAMA_API_KEY}  # Visible in docker inspect
```

### After (Docker Secrets)
```yaml
services:
  ollama:
    secrets:
      - ollama_api_key
    environment:
      - OLLAMA_API_KEY_FILE=/run/secrets/ollama_api_key

secrets:
  ollama_api_key:
    file: ./secrets/ollama_api_key.txt
```

## Secrets Migrated

| Secret Name | File Location | Used By |
|-------------|---------------|---------|
| `ollama_api_key` | `secrets/ollama_api_key.txt` | ollama, openwebui |
| `webui_secret_key` | `secrets/webui_secret_key.txt` | openwebui |
| `qdrant_api_key` | `secrets/qdrant_api_key.txt` | qdrant |
| `n8n_encryption_key` | `secrets/n8n_encryption_key.txt` | n8n |
| `langchain_api_key` | `secrets/langchain_api_key.txt` | langchain |
| `langgraph_api_key` | `secrets/langgraph_api_key.txt` | langgraph |
| `langgraph_db_password` | `secrets/langgraph_db_password.txt` | langgraph-db |
| `langflow_api_key` | `secrets/langflow_api_key.txt` | langflow |
| `nginx_auth_password` | `secrets/nginx_auth_password.txt` | nginx-proxy |
| `hoarder_secret_key` | `secrets/hoarder_secret_key.txt` | hoarder |
| `nextauth_secret` | `secrets/nextauth_secret.txt` | hoarder |
| `nextcloud_db_password` | `secrets/nextcloud_db_password.txt` | nextcloud, nextcloud-db |
| `pihole_password` | `secrets/pihole_password.txt` | pihole |

## File Structure

```
Homelab-Install-Script/
├── docker-compose.yml          # Updated to use secrets
├── .env                         # Still used for non-secret config
├── secrets/                     # New directory (git-ignored)
│   ├── ollama_api_key.txt
│   ├── webui_secret_key.txt
│   ├── qdrant_api_key.txt
│   ├── n8n_encryption_key.txt
│   ├── langchain_api_key.txt
│   ├── langgraph_api_key.txt
│   ├── langgraph_db_password.txt
│   ├── langflow_api_key.txt
│   ├── nginx_auth_password.txt
│   ├── hoarder_secret_key.txt
│   ├── nextauth_secret.txt
│   ├── nextcloud_db_password.txt
│   └── pihole_password.txt
└── .gitignore                   # Updated to ignore secrets/
```

## Installation Process

The `post-install.sh` script now:

1. Creates `secrets/` directory with `700` permissions
2. Generates secure random keys (same as before)
3. Writes each secret to individual files with `600` permissions
4. Maintains `.env` file for backward compatibility and non-secret config

## Security Improvements

### Before
- ❌ Secrets visible in `docker inspect service_name`
- ❌ Secrets visible in `/proc/1/environ` inside containers
- ❌ Secrets logged in container startup logs
- ❌ Accessible to anyone with Docker socket access

### After
- ✅ Secrets NOT visible in `docker inspect`
- ✅ Secrets NOT in process environment
- ✅ Secrets NOT logged
- ✅ Secrets mounted as read-only files in `/run/secrets/`
- ✅ File permissions: `600` (owner read/write only)
- ✅ Directory permissions: `700` (owner access only)

## Verification

After deployment, verify secrets are secure:

```bash
# Secrets should NOT appear in docker inspect
docker inspect ollama | grep -i "api_key"
# Should show: "OLLAMA_API_KEY_FILE=/run/secrets/ollama_api_key"
# Should NOT show the actual key value

# Verify secret file permissions
ls -la secrets/
# All files should show: -rw------- (600)

# Verify secrets are mounted in container
docker exec ollama ls -la /run/secrets/
# Should show files with restricted permissions

# Verify secret content is correct
docker exec ollama cat /run/secrets/ollama_api_key
# Should show the API key (only accessible from inside container)
```

## Rollback Procedure

If needed, rollback to environment variables:

1. Checkout previous version of `docker-compose.yml`:
   ```bash
   git checkout HEAD~1 docker-compose.yml
   ```

2. Restart services:
   ```bash
   docker compose down
   docker compose up -d
   ```

## Notes

- `.env` file is still used for non-secret configuration (ports, paths, etc.)
- Secrets are NOT checked into git (added to `.gitignore`)
- Each secret is a separate file for granular access control
- Services only get access to secrets they need (principle of least privilege)

## References

- [Docker Secrets Documentation](https://docs.docker.com/engine/swarm/secrets/)
- [Docker Compose Secrets](https://docs.docker.com/compose/use-secrets/)
- [OWASP Secret Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
