# Refactoring Roadmap

This document outlines opportunities for refactoring the Homelab Install Script to improve maintainability, modularity, and code reuse.

## Current State

The script is currently a single ~1500+ line bash script with:
- ✓ Comprehensive error handling
- ✓ Modular function structure
- ✓ Good inline documentation
- ✓ Idempotent operations
- ✓ Rollback capability

## Phase 4: Low-Priority Improvements

These improvements are nice-to-have and don't impact functionality. They should be considered for future iterations.

### 4.1 Extract Logging Module

**Current State**: Logging functions are inline in post-install.sh

```bash
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
```

**Proposed Refactoring**: Create `lib/logger.sh`

```bash
# lib/logger.sh
LOG_FILE="${LOG_FILE:-.homelab-setup.log}"
LOG_LEVEL="${LOG_LEVEL:-info}"

log() { ... }
error() { ... }
warning() { ... }
success() { ... }
debug() { ... }

# Usage in post-install.sh
source lib/logger.sh
log "Message"
```

**Benefits**:
- Reusable across multiple scripts (validate-setup.sh, verify-installation.sh, etc.)
- Easier to modify logging behavior globally
- Can add features like rotating log files, log levels, timestamps
- Can redirect logs to both stdout and file

**Effort**: 2-3 hours

---

### 4.2 Modularize Installation Functions

**Current State**: 1500+ lines of installation functions in single script

**Proposed Structure**:
```
post-install.sh                    # Main orchestrator
├── lib/
│   ├── logger.sh                 # Logging utilities
│   ├── error-handling.sh          # Error handling utilities
│   ├── validation.sh              # Input validation functions
│   ├── tracking.sh                # Rollback tracking
│   └── base/
│       ├── system.sh              # System updates, SSH, basic setup
│       ├── docker.sh              # Docker and container setup
│       ├── gpu.sh                 # NVIDIA GPU support
│       ├── databases.sh           # SQLite and database setup
│       ├── development.sh         # Git and Claude Code setup
│       └── utilities.sh            # Additional utilities
```

**New post-install.sh** (~100 lines):
```bash
#!/bin/bash
source lib/logger.sh
source lib/error-handling.sh
source lib/validation.sh
source lib/tracking.sh
source lib/base/system.sh
source lib/base/docker.sh
# ... etc

# Main orchestration
validate_environment
run_step "System Updates" install_system_updates true
run_step "Docker Engine" install_docker false
# ... etc
```

**Benefits**:
- Easier to test individual components
- Easier to reuse functions in other scripts
- Better separation of concerns
- Easier to maintain and debug
- Functions more discoverable

**Example**: validate-setup.sh could import and reuse environment validation

**Effort**: 8-12 hours (spread across implementation and testing)

---

### 4.3 Extract Configuration Variables

**Current State**: Configuration values scattered throughout script

**Proposed Module**: `lib/config.sh`

```bash
# lib/config.sh - Central configuration
: ${SSH_CONFIG:="/etc/ssh/sshd_config"}
: ${DOCKER_STARTUP_WAIT:=10}
: ${MODEL_PULL_TIMEOUT:=7200}  # 2 hours
: ${OLLAMA_MODELS:=("gpt-oss:20b" "qwen3-vl:8b" "qwen3-coder:30b" "qwen3:8b")}
: ${DATABASE_DIR:="$HOME/.local/share/homelab/databases"}
: ${BACKUP_DIR:="$HOME/.local/share/homelab/backups"}

# Directories
declare -A DIRS=(
    [db]="$DATABASE_DIR"
    [backup]="$BACKUP_DIR"
    [ssh]="/etc/ssh"
    [docker]="/etc/docker"
)

# Timeouts
declare -A TIMEOUTS=(
    [docker_startup]=10
    [model_pull]=7200
    [service_startup]=30
)
```

**Benefits**:
- Single place to change defaults
- Easy to add new configuration options
- Can be sourced by multiple scripts
- Easier to override for different environments (dev/staging/prod)

**Effort**: 2-3 hours

---

### 4.4 Implement Function Naming Convention

**Current State**: Mix of naming styles
- `install_docker()` - installation
- `run_step()` - orchestration
- `validate_environment()` - validation
- `configure_git()` - configuration

**Proposed Convention**:
```
install_*      # Installation functions
configure_*    # Configuration/setup
validate_*     # Input validation
verify_*       # Health checks
check_*        # Status checks
run_*          # Orchestration
track_*        # Tracking/bookkeeping
log_*          # Logging helpers
```

**Example Refactoring**:
```bash
# Before
install_docker_containers()
pull_ollama_models()

# After
install_docker_containers()
install_ollama_models()  # More consistent naming
```

**Effort**: 1 hour

---

### 4.5 Create DEVELOPE Guide for Contributors

**File**: `DEVELOPER.md`

**Content**:
- Script architecture overview
- How to add a new installation step
- Error handling patterns and examples
- Testing guidelines
- Code style guide
- Debugging tips
- Common mistakes to avoid

**Example Section**:
```markdown
### Adding a New Installation Step

1. Create a function:
   ```bash
   install_myservice() {
       # Check if already installed
       if command -v myservice &>/dev/null; then
           log "MyService already installed, skipping"
           return 0
       fi

       # Install
       sudo apt-get install -y myservice || return 1
       track_package "myservice"

       # Configure if needed
       sudo systemctl enable myservice || return 1
       sudo systemctl start myservice || return 1

       success "MyService installed and started"
   }
   ```

2. Add to execution flow:
   ```bash
   run_step "MyService" install_myservice false
   ```

3. Update documentation (README, .env.example if needed)

4. Test on fresh VM
```

**Benefits**:
- Lowers barrier to contribution
- Ensures consistency of new additions
- Reduces review time
- Prevents common mistakes

**Effort**: 3-4 hours

---

## Implementation Priority

If pursuing Phase 4 refactoring, recommended order:

1. **Extract Logging Module** (2-3h)
   - Foundation for other modules
   - Provides quick win
   - Reusable immediately

2. **Extract Configuration** (2-3h)
   - Complements logging module
   - Enables better testing

3. **Create Developer Guide** (3-4h)
   - Documents current patterns
   - Helps with subsequent refactoring

4. **Modularize Installation Functions** (8-12h)
   - Most complex refactoring
   - Greatest long-term benefit
   - Do last when patterns are well-documented

5. **Implement Naming Conventions** (1h)
   - Polish, do last

**Total Effort**: ~20-25 hours of development and testing

---

## Testing Strategy for Refactored Code

### Unit Testing
```bash
# Test individual function with mocked dependencies
source lib/logger.sh
source lib/validation.sh

test_validate_email() {
    validate_email "user@example.com" && echo "PASS" || echo "FAIL"
    validate_email "invalid-email" && echo "FAIL" || echo "PASS"
}

test_validate_email
```

### Integration Testing
```bash
# Test on fresh VM in Docker
docker run -it ubuntu:22.04 bash < test-installation.sh

# Test idempotency
./post-install.sh  # First run
./post-install.sh  # Second run (should skip already-installed)
```

### Manual Testing
- Test on fresh Ubuntu 20.04, 22.04, 24.04
- Test on minimal Ubuntu (no pre-installed packages)
- Test with different hardware configs
- Test partial failure recovery

---

## Backward Compatibility

All refactoring should maintain:
- ✓ Same command-line interface
- ✓ Same behavior (idempotent, error handling)
- ✓ Same configuration file format (.env)
- ✓ Same installation steps and order
- ✓ Same rollback behavior

---

## Future Enhancements (Beyond Phase 4)

- [ ] Python wrapper for better cross-platform support
- [ ] Systemd service for periodic health checks
- [ ] Grafana/Prometheus monitoring dashboard
- [ ] Ansible playbook version for multiple servers
- [ ] Terraform/IaC templates for cloud deployment
- [ ] Container image pre-building for faster setup
- [ ] Helm charts for Kubernetes deployment

---

## Summary

Phase 4 refactoring is **optional but recommended** for projects that expect:
- Multiple contributors
- Future additions/modifications
- Use of installation logic in other scripts
- Production deployment at scale

For simple homelab use, current structure is adequate and fully functional.
