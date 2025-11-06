# Secrets Management Guide

This guide explains how to securely manage secrets and environment variables for the Homelab installation.

## Overview

The homelab uses a `.env` file to store sensitive information like API keys, encryption keys, and credentials. This file should **NEVER** be committed to version control.

## Initial Setup

### 1. Create `.env` file

Copy the example and create your actual environment file:

```bash
cp .env.example .env
```

### 2. Generate Strong API Keys

#### OpenWebUI Secret Key
```bash
openssl rand -base64 32
```

#### N8N Encryption Key (minimum 32 characters)
```bash
openssl rand -base64 32
```

#### Qdrant API Key
```bash
openssl rand -base64 24
```

#### Ollama API Key
```bash
openssl rand -base64 20
```

### 3. Generate Nginx Authentication Credentials (Security Critical)

**IMPORTANT**: The Dockerfile no longer includes default credentials. You MUST generate credentials before starting containers.

Generate a secure password and .htpasswd file:

```bash
# Create nginx/auth directory if it doesn't exist
mkdir -p nginx/auth

# Generate a strong random password (store this securely)
NGINX_PASSWORD=$(openssl rand -base64 32)
echo "Generated nginx password: $NGINX_PASSWORD"

# Create .htpasswd file with admin user
docker run --rm nginx:alpine htpasswd -c /dev/stdout admin:$NGINX_PASSWORD > nginx/auth/.htpasswd

# Set restrictive permissions
chmod 600 nginx/auth/.htpasswd

# Verify it was created
cat nginx/auth/.htpasswd
```

**Alternative**: If you want to set it up after containers are running:

```bash
# After docker-compose is running
mkdir -p nginx/auth
touch nginx/auth/.htpasswd
chmod 600 nginx/auth/.htpasswd

# Create credentials (you'll be prompted for password)
docker exec nginx-proxy htpasswd -c /etc/nginx/auth/.htpasswd admin

# Add additional users if needed
docker exec nginx-proxy htpasswd -b /etc/nginx/auth/.htpasswd username newpassword
```

**Security Notes**:
- Never use weak passwords (minimum 12 characters, mixed case, numbers, symbols recommended)
- Store the nginx password securely in your password manager
- Update credentials regularly (at least every 90 days)
- Use different passwords for different environments (dev/staging/prod)

### 4. Fill in `.env` File

Edit `.env` and replace all placeholder values:

```bash
nano .env
```

Key values to configure:
- `OLLAMA_API_KEY` - Secure random string
- `WEBUI_SECRET_KEY` - Secure random string (openssl rand -base64 32)
- `N8N_ENCRYPTION_KEY` - Secure random string, **minimum 32 characters**
- `QDRANT_API_KEY` - Secure random string
- `NGINX_AUTH_PASSWORD` - Strong password for web access
- Other service API keys
- Server hostname
- Backup configuration

### 5. Verify `.env` is Not in Git

Ensure `.env` is properly ignored:

```bash
# Check git will ignore it
git check-ignore .env
# Should output: .env

# Verify it's not already tracked (should be empty)
git ls-files | grep ".env"
```

## Using Environment Variables

The `docker-compose.yml` and scripts use variables from `.env`:

```bash
# Load variables
source .env

# Start services with environment variables
docker-compose --env-file .env up -d

# Or use default loading (automatic)
docker-compose up -d
```

## Security Best Practices

### 1. File Permissions

```bash
# Restrict .env file permissions
chmod 600 .env

# Restrict database directory
chmod 700 ~/.local/share/homelab/databases
```

### 2. Rotating Secrets

Periodically rotate sensitive credentials:

```bash
# Update API keys in .env
nano .env

# Recreate services with new credentials
docker-compose down
docker-compose up -d
```

### 3. SSH Keys

Generate SSH keys for key-based authentication:

```bash
# Generate SSH key pair
ssh-keygen -t ed25519 -C "homelab@example.com"

# Default location: ~/.ssh/id_ed25519
# Add public key to authorized_keys on server
cat ~/.ssh/id_ed25519.pub | ssh user@server "cat >> ~/.ssh/authorized_keys"

# Set proper permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

### 4. Backing Up Secrets

**IMPORTANT**: Back up `.env` securely and separately from the server:

```bash
# Create encrypted backup
tar -czf - .env | gpg --symmetric --output env-backup.tar.gz.gpg

# Restore from backup
gpg --output env-backup.tar.gz env-backup.tar.gz.gpg
tar -xzf env-backup.tar.gz
```

Or use a secrets manager:

```bash
# Install 1Password CLI
# https://developer.1password.com/docs/cli/

# Store secrets in 1Password
op item create --vault Private \
  --title "Homelab Secrets" \
  --category login \
  --generate-password \
  "OLLAMA_API_KEY"

# Retrieve secrets
op read "op://Private/Homelab Secrets/OLLAMA_API_KEY"
```

### 5. Access Control

#### Using Nginx Basic Auth

The nginx reverse proxy enforces basic authentication on all services.

**Default credentials** (from Dockerfile):
- Username: `admin`
- Password: `homelab123`

**Change immediately after setup:**

```bash
# Generate new password
docker exec nginx-proxy htpasswd -b /etc/nginx/auth/.htpasswd admin newpassword

# For new users
docker exec nginx-proxy htpasswd -b /etc/nginx/auth/.htpasswd username password
```

#### Using API Keys

Individual services support API key authentication:

```bash
# Qdrant API key in requests
curl -H "api-key: $QDRANT_API_KEY" http://localhost:6333/health

# Ollama API key (if supported)
curl -H "Authorization: Bearer $OLLAMA_API_KEY" http://localhost:11434/api/tags
```

## Environment Variables Reference

### Critical Secrets (Change These!)

```bash
OLLAMA_API_KEY=your-secure-api-key-here
WEBUI_SECRET_KEY=your-secure-secret-key-here
N8N_ENCRYPTION_KEY=your-32-character-minimum-encryption-key-here
QDRANT_API_KEY=your-secure-qdrant-api-key-here
NGINX_AUTH_PASSWORD=your-secure-password-here
```

### Optional Configuration

```bash
ENABLE_HTTPS=true
ENABLE_GPU=false
LOG_LEVEL=info
ENABLE_BACKUPS=true
BACKUP_RETENTION_DAYS=7
```

## Troubleshooting

### Services Can't Connect to Each Other

Ensure all services can reach each other through the shared network:

```bash
# Check network
docker network ls
docker network inspect homelab_network

# Test connectivity
docker exec ollama curl -f http://qdrant:6333/health
```

### Authentication Failed

Verify nginx credentials:

```bash
# Check if .htpasswd exists
docker exec nginx-proxy cat /etc/nginx/auth/.htpasswd

# Verify credentials format
docker exec nginx-proxy htpasswd -vb /etc/nginx/auth/.htpasswd admin testpassword
```

### Environment Variables Not Loading

Check `.env` file location and format:

```bash
# Verify .env exists in same directory as docker-compose.yml
ls -la .env

# Check syntax (no spaces around =)
grep -E '^[A-Z_]+=.*$' .env

# Use --env-file explicitly
docker-compose --env-file .env config | grep -A5 environment
```

## Advanced: Using Vault or Secrets Manager

For production environments, consider using a dedicated secrets manager:

### HashiCorp Vault

```bash
# Install Vault
curl https://apt.releases.hashicorp.com/gpg | apt-key add -
apt-get install vault

# Start Vault
vault server -dev

# Store secret
vault kv put secret/homelab/ollama api_key="your-key"

# Retrieve secret
vault kv get secret/homelab/ollama
```

### 1Password CLI

```bash
# Authenticate
eval $(op signin)

# Store secret
op item create --vault Private \
  --category login \
  --title "Homelab Ollama" \
  "API Key"

# Use in scripts
OLLAMA_API_KEY=$(op read "op://Private/Homelab Ollama/API Key")
```

### AWS Secrets Manager

```bash
# Store secret
aws secretsmanager create-secret \
  --name homelab/ollama-api-key \
  --secret-string "your-api-key"

# Retrieve in script
aws secretsmanager get-secret-value \
  --secret-id homelab/ollama-api-key
```

## Cleanup and Security

Before deploying to production:

- [ ] Generate strong, random API keys for all services
- [ ] Set `NGINX_AUTH_PASSWORD` to a strong password
- [ ] Generate `N8N_ENCRYPTION_KEY` (minimum 32 chars)
- [ ] Backup `.env` securely and separately
- [ ] Ensure `.env` is in `.gitignore`
- [ ] Set restrictive file permissions (`chmod 600 .env`)
- [ ] Review all API keys and credentials
- [ ] Enable HTTPS with valid SSL certificates
- [ ] Test authentication from external machine
- [ ] Rotate credentials regularly

## See Also

- [SECURITY.md](SECURITY.md) - Security audit and recommendations
- [README.md](README.md) - Installation and usage guide
- [docker-compose.yml](docker-compose.yml) - Service configuration
