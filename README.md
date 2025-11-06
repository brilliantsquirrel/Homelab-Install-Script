# Homelab Install Script

A robust, idempotent post-install automation script for Ubuntu systems.

## Overview

This script automates common tasks after a fresh Ubuntu installation, including system updates, Docker setup, Python installation, and essential utility packages. It's designed to be safe, resilient, and can be run multiple times without causing issues.

## Features

- **Idempotent** - Safe to run multiple times; skips already-installed software
- **Resilient** - Non-critical failures don't stop the script
- **Rollback Support** - Can undo changes if failures occur
- **Smart Defaults** - Auto-detects latest Python version
- **User Safe** - Requires confirmation, prevents root execution, tracks all changes
- **Well Documented** - Comprehensive CLAUDE.md for developers

## What Gets Installed

1. **System Updates** - Latest package updates and upgrades
2. **Graphics Drivers** - Proprietary drivers via ubuntu-drivers
3. **Docker Engine** - Official Docker runtime (not Desktop)
4. **Python** - Latest stable version (auto-detected from deadsnakes PPA)
5. **Discord** - Communication app
6. **1Password** - Password manager
7. **Utility Packages** - git, vim, htop, tree, unzip, build-essential

## Usage

```bash
./post-install.sh
```

The script will:
- Prompt for confirmation before proceeding
- Check if each component is already installed
- Continue with remaining steps if non-critical installations fail
- Offer rollback if any failures occur

## Requirements

- Ubuntu/Debian-based system
- Regular user with sudo privileges
- Internet connection

## Documentation

See [CLAUDE.md](CLAUDE.md) for detailed architecture, implementation details, and guidance on modifying the script.

## License

MIT
