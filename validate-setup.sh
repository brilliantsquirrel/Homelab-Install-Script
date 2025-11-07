#!/bin/bash

# Homelab Setup Validation Script
# Run this script before installing to verify system requirements and configuration
# Usage: ./validate-setup.sh

# ========================================
# Module Loading
# ========================================

# Get script directory for module imports
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source logger module (provides log, error, warning, info functions)
if [ -f "$SCRIPT_DIR/lib/logger.sh" ]; then
    source "$SCRIPT_DIR/lib/logger.sh" || {
        echo "ERROR: Failed to source lib/logger.sh"
        exit 1
    }
else
    # Fallback logging if modules not available
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    log() { echo -e "${GREEN}[✓]${NC} $1"; }
    error() { echo -e "${RED}[✗]${NC} $1"; }
    warning() { echo -e "${YELLOW}[!]${NC} $1"; }
    info() { echo -e "${BLUE}[i]${NC} $1"; }
fi

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

# Override logging functions to track check results
_original_log="$( echo "$(type log)" | grep -oP '(?<=\').*' | head -1)"
_original_error="$( echo "$(type error)" | grep -oP '(?<=\').*' | head -1)"
_original_warning="$( echo "$(type warning)" | grep -oP '(?<=\').*' | head -1)"

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

# Header
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Homelab Setup Validation Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# === OS Compatibility ===
echo -e "${BLUE}1. Checking OS Compatibility${NC}"

if [ -f /etc/os-release ]; then
    source /etc/os-release

    case "$ID" in
        ubuntu)
            log "OS is Ubuntu (compatible)"
            # Check version
            major_version="${VERSION_ID%%.*}"
            if [ "$major_version" -ge 20 ]; then
                log "Ubuntu version ${VERSION_ID} is supported"
            else
                error "Ubuntu version ${VERSION_ID} is too old (minimum: 20.04)"
            fi
            ;;
        *)
            warning "OS is $ID (not officially tested, may have issues)"
            ;;
    esac
else
    error "/etc/os-release not found - cannot determine OS"
fi

echo ""

# === System Resources ===
echo -e "${BLUE}2. Checking System Resources${NC}"

# Check RAM
total_ram=$(free -g | awk '/^Mem:/ {print $2}')
if [ "$total_ram" -ge 16 ]; then
    log "RAM: ${total_ram}GB (sufficient)"
elif [ "$total_ram" -ge 8 ]; then
    warning "RAM: ${total_ram}GB (minimum is 16GB, but may work)"
else
    error "RAM: ${total_ram}GB (insufficient, minimum required: 16GB)"
fi

# Check disk space
available_disk=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$available_disk" -ge 50 ]; then
    log "Disk space: ${available_disk}GB available (sufficient)"
elif [ "$available_disk" -ge 30 ]; then
    warning "Disk space: ${available_disk}GB available (minimum recommended: 50GB)"
else
    error "Disk space: ${available_disk}GB available (insufficient)"
fi

# Check CPU cores
cpu_cores=$(nproc)
if [ "$cpu_cores" -ge 4 ]; then
    log "CPU cores: $cpu_cores (sufficient)"
else
    warning "CPU cores: $cpu_cores (recommended: 4+)"
fi

echo ""

# === Required Tools ===
echo -e "${BLUE}3. Checking Required Tools${NC}"

# Check Docker
if command -v docker &> /dev/null; then
    docker_version=$(docker --version)
    log "Docker installed: $docker_version"
else
    error "Docker not installed (will be installed by post-install.sh)"
fi

# Check docker-compose
if command -v docker-compose &> /dev/null; then
    compose_version=$(docker-compose --version)
    log "docker-compose installed: $compose_version"
else
    warning "docker-compose not installed (will be installed by post-install.sh)"
fi

# Check git
if command -v git &> /dev/null; then
    git_version=$(git --version)
    log "Git installed: $git_version"
else
    error "Git not installed (required for version control)"
fi

# Check openssl
if command -v openssl &> /dev/null; then
    openssl_version=$(openssl version)
    log "OpenSSL installed: $openssl_version"
else
    error "OpenSSL not installed (required for encryption)"
fi

# Check curl
if command -v curl &> /dev/null; then
    log "curl installed"
else
    error "curl not installed (required for downloading files)"
fi

echo ""

# === Network Configuration ===
echo -e "${BLUE}4. Checking Network Configuration${NC}"

# Check if script is in repository directory
if [ -f docker-compose.yml ]; then
    log "docker-compose.yml found in current directory"
else
    error "docker-compose.yml not found - make sure you run this from the repository root"
fi

# Check internet connectivity
if ping -c 1 8.8.8.8 &> /dev/null; then
    log "Internet connectivity working"
else
    warning "Cannot reach 8.8.8.8 - check network connectivity"
fi

echo ""

# === File Permissions ===
echo -e "${BLUE}5. Checking File Permissions${NC}"

# Check if script has execute permission
if [ -x ./post-install.sh ]; then
    log "post-install.sh is executable"
else
    error "post-install.sh is not executable (run: chmod +x post-install.sh)"
fi

# Check if this validation script is executable
if [ -x ./validate-setup.sh ]; then
    log "validate-setup.sh is executable"
else
    warning "validate-setup.sh is not executable"
fi

echo ""

# === Environment Configuration ===
echo -e "${BLUE}6. Checking Environment Configuration${NC}"

if [ -f .env ]; then
    log ".env file exists"

    # Check if .env has content
    if [ -s .env ]; then
        # Check for required keys (basic check)
        required_keys=("OLLAMA_API_KEY" "QDRANT_API_KEY" "N8N_ENCRYPTION_KEY")

        for key in "${required_keys[@]}"; do
            if grep -q "^${key}=" .env; then
                # Check if value is not empty
                value=$(grep "^${key}=" .env | cut -d'=' -f2)
                if [ -z "$value" ]; then
                    error "${key} is empty in .env"
                else
                    log "${key} is set in .env"
                fi
            else
                error "${key} not found in .env"
            fi
        done
    else
        error ".env file is empty"
    fi
else
    error ".env file not found"
    error "Create it by running: cp .env.example .env"
    error "Then edit it with your secure values"
fi

# Check if .env has restrictive permissions
if [ -f .env ]; then
    perms=$(stat -c %a .env 2>/dev/null || stat -f %A .env 2>/dev/null)
    if [[ "$perms" == "600" ]]; then
        log ".env file has restrictive permissions (600)"
    else
        warning ".env file permissions are $perms (should be 600: chmod 600 .env)"
    fi
fi

echo ""

# === Nginx Configuration ===
echo -e "${BLUE}7. Checking Nginx Configuration${NC}"

if [ -d nginx/auth ]; then
    log "nginx/auth directory exists"

    if [ -f nginx/auth/.htpasswd ]; then
        log "nginx/auth/.htpasswd file exists"
        if [ -s nginx/auth/.htpasswd ]; then
            log ".htpasswd file has content"
        else
            warning ".htpasswd file is empty (will need to be populated)"
        fi
    else
        warning "nginx/auth/.htpasswd not found (will need to create credentials)"
    fi
else
    info "nginx/auth directory doesn't exist (will be created)"
fi

echo ""

# === Docker Compose Validation ===
echo -e "${BLUE}8. Validating docker-compose.yml${NC}"

if [ -f docker-compose.yml ]; then
    # Try to validate if docker is available
    if command -v docker-compose &> /dev/null; then
        if docker-compose config > /dev/null 2>&1; then
            log "docker-compose.yml is valid"
        else
            error "docker-compose.yml has syntax errors:"
            docker-compose config
        fi
    elif command -v docker &> /dev/null; then
        if docker compose config > /dev/null 2>&1; then
            log "docker-compose.yml is valid (using docker compose)"
        else
            warning "Cannot validate docker-compose.yml (docker compose command not available)"
        fi
    else
        warning "Docker not installed - cannot validate docker-compose.yml syntax"
    fi
else
    error "docker-compose.yml not found"
fi

echo ""

# === Documentation ===
echo -e "${BLUE}9. Checking Documentation${NC}"

required_docs=("README.md" "SECRETS.md" "SECURITY.md" "CODE-REVIEW.md" ".env.example")

for doc in "${required_docs[@]}"; do
    if [ -f "$doc" ]; then
        log "$doc exists"
    else
        warning "$doc not found"
    fi
done

echo ""

# === Summary ===
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Validation Summary${NC}"
echo -e "${BLUE}========================================${NC}"

total_checks=$((CHECKS_PASSED + CHECKS_FAILED + CHECKS_WARNING))

echo -e "${GREEN}Passed:${NC} $CHECKS_PASSED"
echo -e "${RED}Failed:${NC} $CHECKS_FAILED"
echo -e "${YELLOW}Warnings:${NC} $CHECKS_WARNING"
echo -e "Total: $total_checks"

echo ""

if [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All critical checks passed!${NC}"
    echo "You can now run: ./post-install.sh"
    exit 0
else
    echo -e "${RED}Some critical checks failed.${NC}"
    echo "Please fix the errors above before running ./post-install.sh"
    exit 1
fi
