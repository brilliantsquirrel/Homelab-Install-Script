#!/bin/bash

# Homelab Post-Installation Verification Script
# Run this script after installation to verify all services are running and healthy
# Usage: ./verify-installation.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

# Logging functions
log() {
    echo -e "${GREEN}[✓]${NC} $1"
    ((CHECKS_PASSED++))
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    ((CHECKS_FAILED++))
}

warning() {
    echo -e "${YELLOW}[!]${NC} $1"
    ((CHECKS_WARNING++))
}

info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Header
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Homelab Post-Installation Verification${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# === Docker Status ===
echo -e "${BLUE}1. Docker Status${NC}"

if command -v docker &> /dev/null; then
    log "Docker command available"

    if sudo systemctl is-active --quiet docker; then
        log "Docker daemon running"
    else
        error "Docker daemon not running"
    fi

    # Check docker-compose
    if command -v docker-compose &> /dev/null; then
        log "docker-compose available"
    else
        error "docker-compose not available"
    fi
else
    error "Docker not installed"
fi

echo ""

# === Container Status ===
echo -e "${BLUE}2. Container Status${NC}"

# List of expected containers
containers=("nginx-proxy" "ollama" "openwebui" "portainer" "qdrant" "n8n" "langchain" "langgraph" "langflow" "docker-socket-proxy")

for container in "${containers[@]}"; do
    if sudo docker ps | grep -q "$container"; then
        log "Container running: $container"
    else
        if sudo docker ps -a | grep -q "$container"; then
            warning "Container exists but not running: $container"
        else
            error "Container not found: $container"
        fi
    fi
done

echo ""

# === Service Health Checks ===
echo -e "${BLUE}3. Service Health Checks${NC}"

# Ollama health check
if sudo docker exec ollama curl -f http://localhost:11434/api/tags &>/dev/null; then
    log "Ollama API responding"
else
    warning "Ollama API not responding (may still be initializing)"
fi

# OpenWebUI health check
if sudo docker exec openwebui curl -f http://localhost:8080/health &>/dev/null 2>&1; then
    log "OpenWebUI API responding"
else
    warning "OpenWebUI API not responding"
fi

# Qdrant health check
api_key=$(grep "QDRANT_API_KEY" .env 2>/dev/null | cut -d'=' -f2)
if [ -n "$api_key" ]; then
    if sudo docker exec qdrant curl -f -H "api-key: $api_key" http://localhost:6333/health &>/dev/null; then
        log "Qdrant API responding"
    else
        warning "Qdrant API not responding"
    fi
fi

# n8n health check
if sudo docker exec n8n curl -f http://localhost:5678 &>/dev/null 2>&1; then
    log "n8n API responding"
else
    warning "n8n API not responding"
fi

echo ""

# === Volume Status ===
echo -e "${BLUE}4. Volume Status${NC}"

volumes=("ollama_data" "portainer_data" "openwebui_data" "qdrant_data" "n8n_data" "langflow_data" "nginx_certs" "nginx_auth")

for volume in "${volumes[@]}"; do
    if sudo docker volume ls | grep -q "$volume"; then
        log "Volume exists: $volume"
    else
        warning "Volume not found: $volume"
    fi
done

echo ""

# === Network Status ===
echo -e "${BLUE}5. Network Status${NC}"

if sudo docker network ls | grep -q "homelab_network"; then
    log "homelab_network exists"

    # Check network connectivity
    if sudo docker run --rm --network homelab_network alpine ping -c 1 ollama &>/dev/null; then
        log "Network connectivity working (tested with ollama)"
    else
        warning "Network connectivity issue detected"
    fi
else
    error "homelab_network not found"
fi

echo ""

# === File and Permission Checks ===
echo -e "${BLUE}6. File and Permission Checks${NC}"

# Check .env file
if [ -f .env ]; then
    log ".env file exists"

    perms=$(stat -c %a .env 2>/dev/null || stat -f %A .env 2>/dev/null)
    if [[ "$perms" == "600" ]]; then
        log ".env has correct permissions (600)"
    else
        warning ".env permissions are $perms (should be 600)"
    fi
else
    error ".env file not found"
fi

# Check docker-compose.yml
if [ -f docker-compose.yml ]; then
    log "docker-compose.yml exists"

    if sudo docker-compose config > /dev/null 2>&1; then
        log "docker-compose.yml is valid"
    else
        error "docker-compose.yml is invalid"
    fi
else
    error "docker-compose.yml not found"
fi

# Check nginx auth
if [ -f nginx/auth/.htpasswd ]; then
    log "nginx auth credentials exist"
else
    warning "nginx auth credentials not found"
fi

echo ""

# === Git and Development Tools ===
echo -e "${BLUE}7. Development Tools${NC}"

if command -v git &> /dev/null; then
    log "Git installed"

    # Check Git configuration
    if git config --global user.name &>/dev/null; then
        git_user=$(git config --global user.name)
        log "Git user configured: $git_user"
    else
        warning "Git user not configured"
    fi

    if git config --global user.email &>/dev/null; then
        git_email=$(git config --global user.email)
        log "Git email configured: $git_email"
    else
        warning "Git email not configured"
    fi
else
    warning "Git not installed"
fi

# Check Claude Code
if command -v claude-code &> /dev/null || command -v claude &> /dev/null; then
    log "Claude Code CLI installed"
else
    warning "Claude Code CLI not installed"
fi

echo ""

# === Storage and Database ===
echo -e "${BLUE}8. Storage and Database Status${NC}"

# Check SQLite
if command -v sqlite3 &> /dev/null; then
    log "SQLite installed"

    dbdir="$HOME/.local/share/homelab/databases"
    if [ -d "$dbdir" ]; then
        log "SQLite database directory exists: $dbdir"

        perms=$(stat -c %a "$dbdir" 2>/dev/null || stat -f %A "$dbdir" 2>/dev/null)
        if [[ "$perms" == "700" ]]; then
            log "Database directory has correct permissions (700)"
        else
            warning "Database directory permissions are $perms (should be 700)"
        fi
    else
        warning "SQLite database directory not found: $dbdir"
    fi
else
    warning "SQLite not installed"
fi

echo ""

# === Summary ===
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Verification Summary${NC}"
echo -e "${BLUE}========================================${NC}"

total_checks=$((CHECKS_PASSED + CHECKS_FAILED + CHECKS_WARNING))

echo -e "${GREEN}Passed:${NC} $CHECKS_PASSED"
echo -e "${RED}Failed:${NC} $CHECKS_FAILED"
echo -e "${YELLOW}Warnings:${NC} $CHECKS_WARNING"
echo -e "Total: $total_checks"

echo ""

if [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${GREEN}Installation verification successful!${NC}"

    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Access nginx reverse proxy: https://<server-ip>/"
    echo "   Username: admin"
    echo "   Password: (from NGINX_AUTH_PASSWORD in .env)"
    echo ""
    echo "2. Individual service URLs:"
    echo "   - OpenWebUI: https://<server-ip>/openwebui"
    echo "   - Ollama: https://<server-ip>/ollama"
    echo "   - Qdrant: https://<server-ip>/qdrant"
    echo "   - n8n: https://<server-ip>/n8n"
    echo "   - Portainer: https://<server-ip>/portainer"
    echo ""
    echo "3. Pull additional Ollama models (if not done during installation):"
    echo "   sudo docker exec ollama ollama pull <model-name>"
    echo ""
    echo "4. Find your server IP:"
    echo "   hostname -I"
    echo ""
    exit 0
else
    echo -e "${RED}Installation verification found issues.${NC}"
    echo "Please check the errors above and troubleshoot as needed."
    echo ""
    echo -e "${BLUE}Troubleshooting Tips:${NC}"
    echo "1. Check Docker logs: sudo docker-compose logs <service-name>"
    echo "2. Validate config: sudo docker-compose config"
    echo "3. Restart services: sudo docker-compose restart"
    echo "4. Check system resources: free -h (RAM), df -h (disk)"
    echo ""
    exit 1
fi
