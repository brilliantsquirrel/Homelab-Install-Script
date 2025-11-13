# Homelab ISO USB Flasher

Cross-platform CLI tool for creating bootable USB drives from Homelab custom ISO files.

## Features

- 🖥️ **Cross-platform**: Works on Windows, macOS, and Linux
- 🔍 **Smart Detection**: Automatically detects all connected USB drives
- 📥 **Integrated Download**: Downloads ISO directly from signed URLs
- 📊 **Progress Tracking**: Shows download and write progress in real-time
- ✅ **Safe Operations**: Multiple confirmation prompts to prevent accidents
- 🔒 **Data Protection**: Warns before erasing USB drives
- 🚀 **Fast Writing**: Uses optimal block sizes for quick flashing
- 🔄 **Auto Eject**: Safely ejects USB drive after successful write

## Requirements

- **Node.js** 14 or higher ([Download](https://nodejs.org))
- **Administrator/Root privileges** (required for writing to USB drives)
- **USB flash drive** with at least 8GB capacity

### Platform-Specific Requirements

**Linux:**
- `sudo` access
- `lsblk` command (pre-installed on most distributions)
- Optional: `pv` for better progress indication (`sudo apt install pv`)

**macOS:**
- Administrator account
- `diskutil` command (pre-installed)
- Optional: `pv` for better progress indication (`brew install pv`)

**Windows:**
- Administrator privileges
- **Note**: Automated flashing not yet supported on Windows. The tool will guide you to use Rufus or balenaEtcher instead.

## Installation

### Option 1: Use npx (Recommended - No Installation)

Run directly without installing:

```bash
npx homelab-iso-flasher --url="https://your-iso-download-url"
```

### Option 2: Global Installation

Install globally for repeated use:

```bash
npm install -g homelab-iso-flasher
homelab-iso-flasher --url="https://your-iso-download-url"
```

### Option 3: Local Installation

Clone and run from source:

```bash
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script/webapp/flasher
npm install
npm start -- --url="https://your-iso-download-url"
```

## Usage

### Interactive Mode (Recommended)

Run without arguments for interactive prompts:

```bash
npx homelab-iso-flasher
```

You'll be prompted for:
1. ISO download URL
2. Target USB drive selection
3. Confirmation before writing

### Command Line Mode

Specify options via command line:

```bash
npx homelab-iso-flasher \
  --url="https://storage.googleapis.com/your-iso.iso" \
  --drive="/dev/sdb"
```

### Available Options

| Option | Short | Description | Required |
|--------|-------|-------------|----------|
| `--url <url>` | `-u` | ISO download URL from ISO Builder | Yes* |
| `--drive <path>` | `-d` | Target USB drive path | No |
| `--yes` | `-y` | Skip confirmation prompts (dangerous!) | No |
| `--help` | `-h` | Show help message | No |
| `--version` | `-V` | Show version number | No |

\* If not provided, you'll be prompted interactively

### Examples

**Basic usage with URL:**
```bash
npx homelab-iso-flasher --url="https://example.com/homelab.iso"
```

**Specify target drive (skip drive selection):**
```bash
# Linux
npx homelab-iso-flasher --url="https://example.com/homelab.iso" --drive="/dev/sdb"

# macOS
npx homelab-iso-flasher --url="https://example.com/homelab.iso" --drive="/dev/disk2"
```

**Automated mode (skip all prompts):**
```bash
npx homelab-iso-flasher --url="https://example.com/homelab.iso" --drive="/dev/sdb" --yes
```

⚠️ **Warning**: Using `--yes` will skip all safety prompts. Only use if you're absolutely certain!

## How It Works

1. **Download ISO**: Fetches the ISO file from the provided URL with progress tracking
2. **Detect USB Drives**: Scans for all connected removable USB drives
3. **User Selection**: Presents a list of detected drives for selection
4. **Confirmation**: Shows drive details and requires explicit confirmation
5. **Unmount**: Safely unmounts the target drive
6. **Write ISO**: Writes the ISO to the USB drive using `dd` (Linux/macOS) or instructs on Windows
7. **Verify**: Syncs filesystem to ensure all data is written
8. **Eject**: Safely ejects the USB drive
9. **Cleanup**: Removes temporary downloaded ISO file

## Platform-Specific Notes

### Linux

**Identify USB drives:**
```bash
# List all block devices
lsblk

# Or use the flasher's detection
npx homelab-iso-flasher
```

**Common drive paths:**
- `/dev/sdb` (second drive)
- `/dev/sdc` (third drive)
- **Never use `/dev/sda`** (usually your main system drive!)

**Permissions:**
- The tool will prompt for `sudo` password when needed
- You must have sudo privileges

**Install pv for progress:**
```bash
# Ubuntu/Debian
sudo apt install pv

# Fedora/RHEL
sudo dnf install pv

# Arch Linux
sudo pacman -S pv
```

### macOS

**Identify USB drives:**
```bash
# List all disks
diskutil list

# Or use the flasher's detection
npx homelab-iso-flasher
```

**Common drive paths:**
- `/dev/disk2` (second disk)
- `/dev/disk3` (third disk)
- **Never use `/dev/disk0` or `/dev/disk1`** (usually system disks!)

**Permissions:**
- The tool will prompt for administrator password via `sudo`
- You must be an administrator

**Install pv for progress:**
```bash
brew install pv
```

### Windows

**Current Status:**
Automated flashing is not yet supported on Windows due to the complexity of low-level disk access. The tool will:

1. Download the ISO file
2. Show you the ISO location
3. Provide instructions to use:
   - **Rufus** (recommended): https://rufus.ie/
   - **balenaEtcher**: https://www.balena.io/etcher/
   - **Win32 Disk Imager**: https://sourceforge.net/projects/win32diskimager/

**Using Rufus (Recommended):**
1. Download and run Rufus
2. Select your USB drive in "Device"
3. Click "SELECT" and choose the downloaded ISO
4. Leave all other settings as default
5. Click "START"

## Safety Features

1. **USB Detection Only**: Only shows removable USB drives, not system disks
2. **Multiple Warnings**: Clear warnings before destructive operations
3. **Confirmation Required**: Explicit "yes/no" confirmation before writing
4. **Drive Information**: Shows drive size and model before writing
5. **No Force Option**: Even `--yes` requires correct drive path

## Troubleshooting

### "No USB drives detected"

**Causes:**
- No USB drive inserted
- USB drive not recognized by system
- Insufficient permissions

**Solutions:**
1. Ensure USB drive is properly inserted
2. Run `lsblk` (Linux) or `diskutil list` (macOS) to verify drive is visible
3. Try re-inserting the USB drive
4. Check USB drive is not encrypted or has special formatting

### "Permission denied" errors

**Linux/macOS:**
```bash
# Ensure you run with sudo when prompted
# If issues persist, check your sudo privileges:
sudo -v
```

**Windows:**
- Right-click Command Prompt or PowerShell
- Select "Run as Administrator"

### "dd: command not found" (Linux)

This is extremely rare as `dd` is built into most Linux distributions. If you encounter this:

```bash
# Ubuntu/Debian (shouldn't be needed)
sudo apt install coreutils

# Fedora/RHEL
sudo dnf install coreutils
```

### "diskutil: command not found" (macOS)

`diskutil` is built into macOS. If missing, your system may be corrupted. Try:

```bash
# Reinstall macOS Command Line Tools
xcode-select --install
```

### "Download failed"

**Causes:**
- Invalid URL
- Expired signed URL (valid for 1 hour typically)
- Network issues
- Insufficient disk space for download

**Solutions:**
1. Verify the URL is correct and not expired
2. Generate a new download URL from the ISO Builder
3. Check your internet connection
4. Ensure you have ~5-10GB free disk space in `/tmp`

### "Write failed" or "dd: error writing"

**Causes:**
- USB drive is faulty or full
- Drive was removed during writing
- Filesystem permissions issue
- USB drive is write-protected

**Solutions:**
1. Try a different USB drive
2. Ensure USB drive has enough space (8GB+ recommended)
3. Check USB drive is not physically write-protected
4. Verify drive with: `sudo badblocks -sv /dev/sdX` (replace X)

### ISO boots but installation fails

**Causes:**
- Incomplete write
- Corrupted download
- USB drive issues

**Solutions:**
1. Verify the write completed to 100%
2. Try re-flashing the USB drive
3. Use a different USB drive
4. Re-download the ISO (it may have been corrupted)

## Technical Details

### Block Size Optimization

- **Linux**: 4MB blocks (`bs=4M`) for optimal speed
- **macOS**: 4MB blocks (`bs=4m` - lowercase on macOS)
- Uses `status=progress` (Linux) or `pv` (macOS/Linux) for progress

### Temporary File Handling

- Downloads to: `$TMPDIR/homelab-iso-flasher/` (usually `/tmp/`)
- Automatically cleaned up after successful completion
- Preserved on error for debugging

### USB Detection Logic

**Linux:**
- Uses `lsblk -J` JSON output
- Filters by `hotplug=1` and `type=disk`
- Excludes mounted system partitions

**macOS:**
- Uses `diskutil list external physical`
- Only shows external physical drives
- Excludes internal drives and partitions

**Windows:**
- Uses `node-disk-info` npm package
- Filters by removable flag
- Shows drive letters (C:, D:, etc.)

## Security Considerations

- Never run with `--yes` unless you're absolutely certain of the target drive
- Always verify the drive path before confirming
- The tool requires elevated privileges (sudo/admin) only for the actual write operation
- Downloaded ISOs are stored in system temp directory and cleaned up automatically
- Signed URLs expire after 1 hour for security

## Development

### Building from Source

```bash
git clone https://github.com/brilliantsquirrel/Homelab-Install-Script.git
cd Homelab-Install-Script/webapp/flasher
npm install
```

### Running in Development

```bash
npm start -- --url="https://example.com/test.iso"
```

### Dependencies

- `chalk`: Terminal styling
- `commander`: CLI argument parsing
- `inquirer`: Interactive prompts
- `ora`: Loading spinners
- `axios`: HTTP downloads
- `fs-extra`: Enhanced filesystem operations
- `cli-progress`: Progress bars
- `node-disk-info`: Cross-platform disk detection

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on multiple platforms if possible
5. Submit a pull request

### Areas for Improvement

- [ ] Windows native flashing support (requires elevated COM interop)
- [ ] ISO verification/checksum validation
- [ ] Resume capability for interrupted downloads
- [ ] Bootloader installation verification
- [ ] Multi-ISO support (multiple USBs in parallel)

## License

MIT License - see LICENSE file in repository root

## Support

- **Issues**: https://github.com/brilliantsquirrel/Homelab-Install-Script/issues
- **Documentation**: https://github.com/brilliantsquirrel/Homelab-Install-Script
- **ISO Builder**: Use the web interface to generate custom ISOs

## Related Tools

- **balenaEtcher**: https://www.balena.io/etcher/ (cross-platform GUI)
- **Rufus**: https://rufus.ie/ (Windows GUI)
- **dd**: Built-in Linux/macOS command-line tool
- **Ventoy**: https://www.ventoy.net/ (multi-boot USB solution)

---

**Made with ❤️ for the homelab community**
