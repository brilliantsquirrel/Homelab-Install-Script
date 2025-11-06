# Security Audit Report

This document outlines security considerations, findings, and recommendations for the Homelab Install Script.

## Executive Summary

The script contains several security concerns that should be addressed before deploying to production environments:

1. **Critical**: Use of deprecated `apt-key` for package authentication
2. **High**: All services exposed on local network without authentication
3. **High**: Docker socket mounted to Portainer (full system access)
4. **High**: `latest` image tags used (unpredictable versions)
5. **Medium**: Command substitution without validation
6. **Medium**: Curl commands download scripts without verification

---

## Detailed Security Findings

### 1. ⚠️ CRITICAL: Deprecated `apt-key` Usage (Line 212)

**Location**: `post-install.sh:212`

```bash
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
```

**Issue**:
- `apt-key` is deprecated in Ubuntu 20.04+ and removed in Ubuntu 22.04+
- Adds key to deprecated global keyring
- No verification of GPG key fingerprints
- Vulnerable to MITM attacks

**Recommendation**:
Replace with signed-by parameter using keyring files:

```bash
curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | \
  sudo gpg --dearmor -o /etc/apt/keyrings/nvidia-docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nvidia-docker.gpg] \
  https://nvidia.github.io/nvidia-docker/$distribution stable main" | \
  sudo tee /etc/apt/sources.list.d/nvidia-docker.list > /dev/null
```

---

### 2. ⚠️ CRITICAL: Docker Socket Access in Portainer (Line 12)

**Location**: `docker-compose.yml:12`

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
```

**Issue**:
- Portainer has complete control over Docker daemon
- Can create/modify/delete any container and volume
- Can access host filesystem
- Any vulnerability in Portainer = full system compromise
- No access control within Portainer

**Recommendation**:
1. **For production**: Use `docker-proxy` or `dind` (Docker-in-Docker) instead
2. **At minimum**:
   - Require authentication in Portainer
   - Restrict network access to Portainer (no direct exposure)
   - Use firewall rules to limit who can access port 9000

```yaml
portainer:
  image: portainer/portainer-ce:latest
  ports:
    - "127.0.0.1:9000:9000"  # Listen only on localhost
  # Consider removing docker.sock and using docker-proxy instead
```

---

### 3. ⚠️ HIGH: Unauthenticated Service Exposure

**Location**: `docker-compose.yml:8-10, 22, 42, 56, 68, 80, 94, 111-112`

**Issue**:
All services listen on `0.0.0.0` without authentication:
- **Ollama API** (11434) - Can execute any model
- **OpenWebUI** (8080) - Can chat with models, access conversation history
- **LangChain** (8000) - Can run AI workflows
- **Qdrant** (6333) - Can read/write vector embeddings
- **n8n** (5678) - Can create/execute workflows
- **SQLite** - Not directly exposed but stored data is accessible

**Recommendation**:
1. **Implement authentication**:
   - Add API keys/tokens to each service
   - Use reverse proxy (nginx/Traefik) with authentication
   - Implement OAuth2/OIDC if available

2. **Network isolation**:
```yaml
ports:
  - "127.0.0.1:11434:11434"  # Localhost only
```

3. **Use network policies** if deployed on Kubernetes

4. **Firewall rules**:
```bash
# Allow only from trusted IPs
sudo ufw allow from 192.168.1.0/24 to any port 11434
```

---

### 4. ⚠️ HIGH: Unpinned Container Images

**Location**: `docker-compose.yml` (multiple services)

```yaml
image: ollama/ollama:latest
image: portainer/portainer-ce:latest
```

**Issue**:
- `latest` tag can change unexpectedly
- No version pinning = unpredictable deployments
- Potential breaking changes
- Security patches may introduce bugs
- No reproducibility

**Recommendation**:
Use specific version tags:

```yaml
image: ollama/ollama:0.2.0  # Instead of :latest
image: portainer/portainer-ce:2.18.4
image: ghcr.io/open-webui/open-webui:v0.1.112
```

**Better approach**: Use SHA256 digests for immutability:
```bash
docker pull ollama/ollama:0.2.0
docker inspect --format='{{.RepoDigests}}' ollama/ollama:0.2.0
```

Then reference:
```yaml
image: ollama/ollama@sha256:abc123...
```

---

### 5. ⚠️ HIGH: Unvalidated Command Substitution

**Location**: `post-install.sh:213`

```bash
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
```

**Issue**:
- Sources `/etc/os-release` without validation
- `$ID` and `$VERSION_ID` not quoted
- Could be manipulated if file is writable
- No error checking if variables are empty

**Recommendation**:

```bash
# Validate before use
if [ ! -f /etc/os-release ]; then
    error "Cannot determine OS version"
    return 1
fi

# Source safely with validation
source /etc/os-release
if [ -z "$ID" ] || [ -z "$VERSION_ID" ]; then
    error "Failed to determine OS ID or VERSION_ID"
    return 1
fi

distribution="${ID}${VERSION_ID}"

# Whitelist known distributions
case "$distribution" in
    ubuntu20.04|ubuntu22.04|ubuntu24.04)
        ;;
    *)
        error "Unsupported distribution: $distribution"
        return 1
        ;;
esac
```

---

### 6. ⚠️ MEDIUM: Curl Download Without Verification

**Location**: `post-install.sh:180, 212, 214`

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o ...
```

**Issue**:
- Downloads GPG keys without verification
- Could be compromised if DNS/HTTPS is broken
- No checksum verification
- `-s` flag silently ignores errors

**Recommendation**:

```bash
# Use checksums when available
EXPECTED_SHA256="expected_hash_here"
DOWNLOADED_FILE="/tmp/docker.gpg"

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOWNLOADED_FILE" || return 1

# Verify checksum
echo "$EXPECTED_SHA256  $DOWNLOADED_FILE" | sha256sum -c - || {
    error "GPG key checksum verification failed"
    rm -f "$DOWNLOADED_FILE"
    return 1
}

sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg < "$DOWNLOADED_FILE"
rm -f "$DOWNLOADED_FILE"
```

---

### 7. ⚠️ MEDIUM: Qdrant Configuration File Permissions

**Location**: `docker-compose.yml:115`

```yaml
- ./qdrant_config.yaml:/qdrant/config/config.yaml:ro
```

**Issue**:
- If config contains secrets, they're readable by the host user
- Read-only mount is good, but content isn't encrypted
- No access control on local config file

**Recommendation**:
1. Use environment variables for sensitive config:
```yaml
environment:
  - QDRANT_API_KEY=${QDRANT_API_KEY}
  - QDRANT_ENABLE_API_HTTPS=true
```

2. Set restrictive file permissions:
```bash
chmod 600 qdrant_config.yaml
chown $USER:$USER qdrant_config.yaml
```

3. Don't store in public repositories

---

### 8. ⚠️ MEDIUM: SQLite Database Permissions

**Location**: `post-install.sh:266-267`

```bash
mkdir -p ~/.local/share/homelab/databases || true
```

**Issue**:
- Created with default umask (likely 0755)
- May be world-readable
- SQLite doesn't enforce authentication
- Any user on system can read/write databases

**Recommendation**:

```bash
# Create with restrictive permissions
DBDIR="$HOME/.local/share/homelab/databases"
mkdir -p "$DBDIR"
chmod 700 "$DBDIR"  # Only owner can read/write/execute

log "SQLite database directory created with restricted permissions: $DBDIR"

# When creating databases
sqlite3 "$DBDIR/myapp.db" ".mode list"
chmod 600 "$DBDIR/myapp.db"  # Only owner can access
```

---

### 9. ⚠️ MEDIUM: No Service Restart Policy Validation

**Location**: `docker-compose.yml` (multiple services)

```yaml
restart: always
```

**Issue**:
- Services restart indefinitely on failure
- Could hide security issues
- If service is compromised, restart keeps it running
- No maximum restart attempts

**Recommendation**:

```yaml
restart_policy:
  condition: on-failure
  delay: 5s
  max_attempts: 5
  window: 120s
```

---

### 10. ⚠️ LOW: SSH Key Security Not Mentioned

**Location**: `post-install.sh:190-196`

**Issue**:
- SSH is enabled but no guidance on key-based authentication
- Default SSH config may allow password authentication
- No mention of disabling root login or other hardening

**Recommendation**:

```bash
install_ssh() {
    # ... existing code ...

    # Harden SSH configuration
    sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

    sudo systemctl restart ssh
    log "SSH hardened with key-based auth and root login disabled"
}
```

---

### 11. ⚠️ LOW: No Secret Management

**Issue**:
- No mechanism for managing API keys, tokens, or credentials
- Secrets could leak in logs or docker inspect output
- No encryption at rest

**Recommendation**:
1. Use `.env` file (add to `.gitignore`):
```bash
OLLAMA_API_KEY=your_key_here
QDRANT_API_KEY=your_key_here
N8N_ADMIN_EMAIL=admin@example.com
```

2. Load in docker-compose:
```yaml
env_file: .env
environment:
  - OLLAMA_API_KEY=${OLLAMA_API_KEY}
```

3. Use secrets manager (e.g., HashiCorp Vault, 1Password) in production

---

## Security Checklist

- [ ] Replace `apt-key` with signed-by parameter
- [ ] Add authentication to all services
- [ ] Restrict network exposure (localhost/firewall)
- [ ] Pin container image versions/digests
- [ ] Validate OS version detection
- [ ] Verify GPG key checksums
- [ ] Restrict Qdrant config file permissions (600)
- [ ] Restrict SQLite database directory (700)
- [ ] Configure restart policies with limits
- [ ] Harden SSH configuration
- [ ] Implement secret management (.env file)
- [ ] Create `.gitignore` to exclude secrets
- [ ] Document security setup in README

---

## Deployment Recommendations

### For Home/Lab Use (Current Setup)
- Firewall rules to restrict network access
- Run on trusted network only
- Add authentication layer (reverse proxy)
- Regular updates of container images

### For Production Deployment
- Implement TLS/HTTPS for all services
- Use authentication/authorization (OAuth2, API keys)
- Implement network policies (if Kubernetes)
- Use secret management system
- Regular security audits
- Container image scanning (Trivy, etc.)
- Monitor for vulnerabilities (Dependabot, etc.)
- Log aggregation and monitoring
- Backup strategy for persistent data
- Incident response plan

---

## Resources

- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [OWASP Top 10](https://owasp.org/Top10/)
- [Ubuntu Security](https://ubuntu.com/security)
- [Bash Security](https://mywiki.wooledge.org/BashGuide/Practices#Security)
- [Container Scanning Tools](https://github.com/aquasecurity/trivy)

---

## Conclusion

The script is functional for a homelab environment but requires significant security hardening for production use. Priority should be given to:

1. Fixing deprecated `apt-key` usage
2. Removing Docker socket access from Portainer
3. Adding authentication to services
4. Pinning container versions
5. Restricting network exposure

Please address these issues before deploying to untrusted networks or using with sensitive data.
