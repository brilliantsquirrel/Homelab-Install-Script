#!/bin/bash

# Error Handling Module - Manages installation step tracking and rollback
# Usage: source lib/error-handling.sh
# Provides: run_step, track_package, track_repo, rollback, get_failed_steps

# Track installation results
declare -A INSTALL_STATUS
FAILED_STEPS=()
INSTALLED_PACKAGES=()
ADDED_REPOS=()

# Track what was installed for potential rollback
# Parameters:
#   $1 - package name to track
track_package() {
    local package="$1"
    INSTALLED_PACKAGES+=("$package")
    debug "Tracked package for rollback: $package"
}

# Track repository that was added
# Parameters:
#   $1 - repository path or PPA (e.g., "ppa:example/ppa" or "/etc/apt/sources.list.d/example.list")
track_repo() {
    local repo="$1"
    ADDED_REPOS+=("$repo")
    debug "Tracked repository for rollback: $repo"
}

# Rollback changes made during installation
# Interactively asks user before rolling back
# Removes packages and repositories that were added
rollback() {
    echo ""
    warning "Would you like to rollback the changes made during this installation? (y/N)"
    read -p "> " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Rollback cancelled."
        return 0
    fi

    error "Rolling back changes..."

    # Remove installed packages
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        log "Removing installed packages: ${INSTALLED_PACKAGES[*]}"
        sudo apt-get remove -y "${INSTALLED_PACKAGES[@]}" 2>/dev/null || true
    fi

    # Remove added repositories
    if [ ${#ADDED_REPOS[@]} -gt 0 ]; then
        for repo in "${ADDED_REPOS[@]}"; do
            log "Removing repository: $repo"
            if [[ "$repo" == "ppa:"* ]]; then
                sudo add-apt-repository --remove -y "$repo" 2>/dev/null || true
            else
                sudo rm -f "$repo" 2>/dev/null || true
            fi
        done
    fi

    # Clean up any temporary files
    rm -f /tmp/discord.deb 2>/dev/null || true

    log "Rollback completed. Some manual cleanup may be required."
}

# Execute a step and track its status
# Parameters:
#   $1 - step_name: Descriptive name of the installation step (e.g., "Docker Engine")
#   $2 - step_function: Name of the function to execute (e.g., install_docker)
#   $3 - critical: "true" to abort on failure, "false" to continue (default: false)
#
# Behavior:
#   - Critical step failure: Logs error, triggers rollback, exits with code 1
#   - Non-critical step failure: Logs error, continues with remaining steps
#   - Success: Logs success message and continues
#
# Example:
#   run_step "Docker Engine" install_docker false
#   run_step "System Updates" install_system_updates true
run_step() {
    local step_name="$1"
    local step_function="$2"
    local critical="${3:-false}"

    log "Starting: $step_name"

    if $step_function; then
        INSTALL_STATUS["$step_name"]="SUCCESS"
        success "$step_name completed"
        return 0
    else
        INSTALL_STATUS["$step_name"]="FAILED"
        FAILED_STEPS+=("$step_name")
        error "$step_name failed"

        if [[ "$critical" == "true" ]]; then
            error "Critical step failed. Aborting installation."
            rollback
            exit 1
        fi
        return 1
    fi
}

# Get array of failed steps
# Usage: failed_steps=$(get_failed_steps)
get_failed_steps() {
    printf '%s\n' "${FAILED_STEPS[@]}"
}

# Get count of failed steps
# Usage: failed_count=$(get_failed_steps_count)
get_failed_steps_count() {
    echo ${#FAILED_STEPS[@]}
}

# Get status of a specific step
# Parameters:
#   $1 - step name
# Returns: SUCCESS or FAILED or UNKNOWN
get_step_status() {
    local step_name="$1"
    echo "${INSTALL_STATUS[$step_name]:-UNKNOWN}"
}

# Print installation summary
# Shows all steps and their status
print_installation_summary() {
    echo ""
    info "=========================================="
    info "Installation Summary"
    info "=========================================="

    local passed=0
    local failed=0

    for step in "${!INSTALL_STATUS[@]}"; do
        local status="${INSTALL_STATUS[$step]}"
        if [ "$status" = "SUCCESS" ]; then
            echo -e "  ${GREEN}✓${NC} $step"
            ((passed++))
        else
            echo -e "  ${RED}✗${NC} $step"
            ((failed++))
        fi
    done

    echo ""
    echo -e "Passed: ${GREEN}$passed${NC}"
    echo -e "Failed: ${RED}$failed${NC}"
    echo ""

    if [ $failed -eq 0 ]; then
        success "All steps completed successfully!"
        return 0
    else
        error "Some steps failed. See above for details."
        return 1
    fi
}

# Get count of installed packages
get_installed_packages_count() {
    echo ${#INSTALLED_PACKAGES[@]}
}

# Get count of added repositories
get_added_repos_count() {
    echo ${#ADDED_REPOS[@]}
}
