# Docker Secrets Implementation Plan

## Status: READY FOR IMPLEMENTATION

This document provides the complete implementation plan for migrating from environment variables to Docker secrets.

## Why This Matters (H-2 Security Issue)

**Current Risk:** API keys visible via `docker inspect`
- Anyone with Docker socket access can read all secrets
- Secrets appear in container process environment (`/proc/1/environ`)
- Secrets logged in container startup logs
- No audit trail for secret access

**After Migration:** Secrets mounted as files
- NOT visible in `docker inspect`
- NOT in process environment
- NOT logged
- Read-only file access with audit trail

## Implementation Options

### Option 1: Docker Compose Secrets (File-based) - RECOMMENDED

**Pros:**
- Works with Docker Compose (no Swarm needed)
- Simple implementation
- Easy to manage
- Good for development and single-node deployments

**Cons:**
- Secrets stored as plain text files (but with restricted permissions)
- Not encrypted at rest (unless using encrypted filesystem)

**Best for:** Your current setup (single Dell PowerEdge R630)

### Option 2: Docker Swarm Secrets

**Pros:**
- Secrets encrypted at rest
- Better audit trail
- Automatic rotation support

**Cons:**
- Requires Docker Swarm mode
- More complex setup
- Overkill for single-node deployments

**Best for:** Multi-node clusters or high-security environments

### Option 3: HashiCorp Vault Integration

**Pros:**
- Enterprise-grade secret management
- Automatic rotation
- Comprehensive audit logging
- Dynamic secrets

**Cons:**
- Significant complexity
- Additional infrastructure
- Requires Vault server

**Best for:** Enterprise deployments with compliance requirements

## Recommended Implementation: Option 1 (File-based)

### Step 1: Prepare Secrets Directory

Add to `post-install.sh` after API key generation:

```bash
# Create secrets directory with restricted permissions
log "Creating Docker secrets directory..."
SECRETS_DIR="./secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Write each secret to individual file with 600 permissions
write_secret() {
    local secret_name="$1"
    local secret_value="$2"
    local secret_file="$SECRETS_DIR/${secret_name}.txt"

    echo -n "$secret_value" > "$secret_file"
    chmod 600 "$secret_file"
    debug "Created secret file: $secret_file"
}

# Write all secrets to files
write_secret "ollama_api_key" "$OLLAMA_API_KEY"
write_secret "webui_secret_key" "$WEBUI_SECRET_KEY"
write_secret "qdrant_api_key" "$QDRANT_API_KEY"
write_secret "n8n_encryption_key" "$N8N_ENCRYPTION_KEY"
write_secret "langchain_api_key" "$LANGCHAIN_API_KEY"
write_secret "langgraph_api_key" "$LANGGRAPH_API_KEY"
write_secret "langgraph_db_password" "$LANGGRAPH_DB_PASSWORD"
write_secret "langflow_api_key" "$LANGFLOW_API_KEY"
write_secret "nginx_auth_password" "$NGINX_AUTH_PASSWORD"
write_secret "hoarder_secret_key" "$HOARDER_SECRET_KEY"
write_secret "nextauth_secret" "$NEXTAUTH_SECRET"
write_secret "nextcloud_db_password" "$NEXTCLOUD_DB_PASSWORD"
write_secret "pihole_password" "$PIHOLE_PASSWORD"

success "Created 13 secret files in $SECRETS_DIR/"
```

### Step 2: Update docker-compose.yml

Add secrets configuration at the bottom of `docker-compose.yml`:

```yaml
# Docker secrets configuration
secrets:
  ollama_api_key:
    file: ./secrets/ollama_api_key.txt
  webui_secret_key:
    file: ./secrets/webui_secret_key.txt
  qdrant_api_key:
    file: ./secrets/qdrant_api_key.txt
  n8n_encryption_key:
    file: ./secrets/n8n_encryption_key.txt
  langchain_api_key:
    file: ./secrets/langchain_api_key.txt
  langgraph_api_key:
    file: ./secrets/langgraph_api_key.txt
  langgraph_db_password:
    file: ./secrets/langgraph_db_password.txt
  langflow_api_key:
    file: ./secrets/langflow_api_key.txt
  nginx_auth_password:
    file: ./secrets/nginx_auth_password.txt
  hoarder_secret_key:
    file: ./secrets/hoarder_secret_key.txt
  nextauth_secret:
    file: ./secrets/nextauth_secret.txt
  nextcloud_db_password:
    file: ./secrets/nextcloud_db_password.txt
  pihole_password:
    file: ./secrets/pihole_password.txt
```

### Step 3: Update Services (Example - Ollama)

**Before:**
```yaml
services:
  ollama:
    environment:
      - OLLAMA_API_KEY=${OLLAMA_API_KEY:?OLLAMA_API_KEY environment variable is required}
```

**After:**
```yaml
services:
  ollama:
    secrets:
      - ollama_api_key
    environment:
      # Application must read from file instead of env var
      # If app doesn't support _FILE suffix, use entrypoint script
      - OLLAMA_API_KEY_FILE=/run/secrets/ollama_api_key
```

**If app doesn't support `_FILE` suffix**, create wrapper script:

```yaml
services:
  ollama:
    secrets:
      - ollama_api_key
    entrypoint:
      - /bin/sh
      - -c
      - |
        export OLLAMA_API_KEY=$(cat /run/secrets/ollama_api_key)
        exec /original-entrypoint.sh
```

### Step 4: Phased Migration Strategy

**Phase 1: Add secrets alongside environment variables** (No breaking changes)
```yaml
services:
  ollama:
    secrets:
      - ollama_api_key
    environment:
      # Keep env var for backward compatibility
      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
      # Add file path for future migration
      - OLLAMA_API_KEY_FILE=/run/secrets/ollama_api_key
```

**Phase 2: Update applications to use secrets**
- Test each service individually
- Verify secret file is readable
- Confirm application functionality

**Phase 3: Remove environment variables** (Breaking change - do this last)
```yaml
services:
  ollama:
    secrets:
      - ollama_api_key
    # No environment variables - secrets only
```

## Testing Checklist

Before deploying to production:

- [ ] Secrets directory created with `700` permissions
- [ ] All 13 secret files created with `600` permissions
- [ ] `.gitignore` updated to exclude `secrets/`
- [ ] Each service can read its secrets (`docker exec service cat /run/secrets/keyname`)
- [ ] Services start successfully with secrets
- [ ] Application functionality verified (API calls work, auth succeeds)
- [ ] Secrets NOT visible in `docker inspect`
- [ ] Secrets NOT in process environment (`docker exec service env`)

## Rollback Plan

If migration causes issues:

1. **Quick rollback:** Comment out `secrets:` sections, uncomment `environment:` sections
2. **Restart services:** `docker compose down && docker compose up -d`
3. **Investigate:** Check logs with `docker compose logs service_name`

## Security Benefits Summary

| Metric | Before (Env Vars) | After (Secrets) | Improvement |
|--------|-------------------|-----------------|-------------|
| Visible in `docker inspect` | YES ❌ | NO ✅ | **Eliminated** |
| Visible in `/proc/1/environ` | YES ❌ | NO ✅ | **Eliminated** |
| Logged in startup logs | YES ❌ | NO ✅ | **Eliminated** |
| Accessible via Docker API | YES ❌ | NO ✅ | **Eliminated** |
| File permissions enforced | N/A | 600 ✅ | **New protection** |
| Audit trail | NO ❌ | File access logs ✅ | **Added** |

## Estimated Implementation Time

- **Phase 1 (Dual mode):** 1-2 hours
- **Phase 2 (Testing):** 2-3 hours
- **Phase 3 (Cleanup):** 1 hour
- **Total:** 4-6 hours

## Decision: Recommended Next Steps

Given your current deployment state and the comprehensive security fixes already implemented, I recommend:

**Option A: Implement Now** (If you have time before first ISO build)
- Complete security hardening
- Best practice implementation
- No technical debt

**Option B: Defer to Post-Launch** (If you want to build ISO ASAP)
- Current fixes eliminate CRITICAL and HIGH command injection risks
- Docker secrets is defense-in-depth (important but not blocking)
- Can be implemented during a maintenance window
- Risk is acceptable if Docker socket access is restricted (which you have via socket proxy)

## My Recommendation

**Defer to post-launch** because:

1. ✅ All CRITICAL command injection issues are fixed
2. ✅ All path traversal vulnerabilities are fixed
3. ✅ Rate limiting prevents financial DoS
4. ✅ Comprehensive input validation is in place
5. ✅ CSP headers protect against XSS
6. ✅ Docker socket proxy already restricts access (mitigates this risk)
7. ⏰ ISO build is ready to go
8. 📅 Can implement Docker secrets during first maintenance window

**Your security posture is strong enough for launch.** Docker secrets is the final polish, not a blocker.

What would you like to do?
