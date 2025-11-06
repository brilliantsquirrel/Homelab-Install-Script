# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal post-install automation script for Ubuntu systems. The main executable is `post-install.sh`, which automates common tasks after a fresh Ubuntu installation. The script is designed to be robust, idempotent, and safe to run multiple times.

## Files

- `post-install.sh` - Main bash script that performs all installation tasks
- `spec.txt` - Original requirements specification
- `CLAUDE.md` - This file

## Running the Script

```bash
./post-install.sh
```

The script must be run as a regular user (not root) with sudo privileges. It will:
- Prompt for confirmation before proceeding
- Check if each component is already installed (idempotent)
- Continue with remaining steps if non-critical installations fail
- Offer rollback if any failures occur

## Script Architecture

### Core Components

**Installation Tracking**:
- `INSTALL_STATUS` - Associative array tracking success/failure of each step
- `FAILED_STEPS` - Array of failed installation names
- `INSTALLED_PACKAGES` - Tracks packages installed during this run (for rollback)
- `ADDED_REPOS` - Tracks repositories added during this run (for rollback)

**Key Functions**:
- `run_step(name, function, critical)` - Executes installation steps with error tracking
- `rollback()` - Removes installed packages and repos if failures occur
- `track_package(name)` - Records package installation for potential rollback
- `track_repo(name)` - Records repository addition for potential rollback
- Logging: `log()`, `error()`, `warning()`, `success()`

### Installation Phases

The script executes these steps sequentially:

1. **System Updates** (critical) - apt-get update/upgrade
2. **Graphics Drivers** (non-critical) - ubuntu-drivers autoinstall
3. **Docker Engine** (non-critical) - From official Docker repository
4. **Python** (non-critical) - Auto-detects latest from deadsnakes PPA
5. **Discord** (non-critical) - Downloads and installs .deb package
6. **1Password** (non-critical) - Desktop app with repository setup
7. **Utility Packages** (non-critical) - git, vim, htop, tree, unzip, build-essential
8. **System Cleanup** (non-critical) - apt autoremove and autoclean

Each step is wrapped in an installation function (e.g., `install_docker()`, `install_python()`) that:
- Checks if already installed (idempotency)
- Performs the installation
- Tracks installed packages/repos for rollback
- Returns 1 on failure, 0 on success

## Key Implementation Details

### Error Handling
- Uses `run_step()` wrapper instead of strict `set -e`
- Critical steps (System Updates) abort on failure and trigger rollback
- Non-critical steps log failures but continue execution
- All commands use `|| return 1` pattern to propagate errors
- Optional operations use `|| true` to ignore failures
- Final summary shows all failed steps

### Idempotency
- Each installation function checks if software is already installed
- Safe to run multiple times without reinstalling
- Skips already-installed components with log message

### Rollback Capability
- Tracks all packages and repos added during execution
- On critical failure: automatically offers rollback
- On any failures: offers rollback at end of script
- Removes tracked packages with `apt-get remove`
- Removes tracked repos (PPAs and repository files)
- Interactive confirmation before executing rollback

### Python Version Detection
- Auto-detects latest available Python 3.x from deadsnakes PPA
- Uses `apt-cache search` to find highest version number
- Falls back to Python 3.12 if detection fails
- Checks if detected version already installed before proceeding

### Logging System
- Color-coded output: green (info/success), red (error), yellow (warning), blue (headers)
- Structured messages with `[INFO]`, `[ERROR]`, `[WARNING]`, `[SUCCESS]` tags
- Progress tracking with step names
- Final summary with success/failure report

### User Safety
- Prevents running as root
- Requires explicit confirmation before starting
- Shows complete list of what will be installed
- Prompts before rollback operations
- Displays post-install notes (logout, reboot requirements)

## Modifying the Script

When adding new installation steps:

1. **Create installation function**:
   ```bash
   install_myapp() {
       # Check if already installed
       if command -v myapp &> /dev/null; then
           log "MyApp already installed, skipping"
           return 0
       fi

       # Perform installation
       sudo apt-get install -y myapp || return 1
       track_package "myapp"
   }
   ```

2. **Add to execution flow**:
   ```bash
   run_step "MyApp" install_myapp false  # false = non-critical
   ```

3. **Error handling guidelines**:
   - Use `|| return 1` for critical operations
   - Use `|| true` for genuinely optional operations (cleanup, group add)
   - Use `2>/dev/null || true` to suppress expected errors

4. **Track installations**:
   - Call `track_package("name")` after successful package install
   - Call `track_repo("ppa:..." or "/path/to/list")` after adding repos

5. **Testing**:
   - Test on fresh Ubuntu installation or VM
   - Test idempotency by running twice
   - Test failure handling by simulating errors
   - Verify rollback removes added components