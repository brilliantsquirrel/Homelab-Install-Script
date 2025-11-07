#!/bin/bash

# Logger Module - Centralized logging for Homelab installation scripts
# Usage: source lib/logger.sh
# Provides: log, error, warning, success, debug functions

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
LOG_FILE="${LOG_FILE:-.homelab-setup.log}"
LOG_LEVEL="${LOG_LEVEL:-info}"  # debug, info, warn, error

# Track if logging is initialized
_LOGGER_INITIALIZED=1

# Initialize logging (creates log file if it doesn't exist)
init_logger() {
    if [ -n "$LOG_FILE" ] && [ "$LOG_FILE" != "/dev/null" ]; then
        touch "$LOG_FILE" 2>/dev/null || true
        _log_internal "debug" "Logging initialized to: $LOG_FILE"
    fi
}

# Internal logging function (writes to file and stdout)
_log_internal() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Write to log file if configured
    if [ -n "$LOG_FILE" ] && [ "$LOG_FILE" != "/dev/null" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Log info message (green)
# Usage: log "Installation started"
log() {
    local message="$1"
    echo -e "${GREEN}[INFO]${NC} $message"
    _log_internal "info" "$message"
}

# Log error message (red)
# Usage: error "Installation failed"
error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
    _log_internal "error" "$message"
}

# Log warning message (yellow)
# Usage: warning "This may cause issues"
warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message"
    _log_internal "warn" "$message"
}

# Log success message (green with SUCCESS tag)
# Usage: success "Installation completed"
success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $message"
    _log_internal "info" "SUCCESS: $message"
}

# Log debug message (blue) - only if LOG_LEVEL=debug
# Usage: debug "Variable x = $x"
debug() {
    local message="$1"

    if [ "$LOG_LEVEL" = "debug" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $message"
    fi

    _log_internal "debug" "$message"
}

# Log informational message with header (blue)
# Usage: info "=== Section Title ==="
info() {
    local message="$1"
    echo -e "${BLUE}[i]${NC} $message"
    _log_internal "info" "$message"
}

# Print separator line for visual clarity
print_separator() {
    local char="${1:-=}"
    local length="${2:-40}"
    printf '%s\n' "$(printf '%s' "$char"'%.0s' {1..$length})"
}

# Get the log file name
get_log_file() {
    echo "$LOG_FILE"
}

# Set the log file
set_log_file() {
    local file="$1"
    LOG_FILE="$file"
    init_logger
}

# Set the log level
set_log_level() {
    local level="$1"
    case "$level" in
        debug|info|warn|error)
            LOG_LEVEL="$level"
            debug "Log level set to: $LOG_LEVEL"
            ;;
        *)
            error "Invalid log level: $level (valid: debug, info, warn, error)"
            return 1
            ;;
    esac
}

# Initialize logging on module load
init_logger
