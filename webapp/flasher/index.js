#!/usr/bin/env node

const { program } = require('commander');
const inquirer = require('inquirer');
const chalk = require('chalk');
const ora = require('ora');
const axios = require('axios');
const fs = require('fs-extra');
const path = require('path');
const { exec, spawn } = require('child_process');
const { promisify } = require('util');
const cliProgress = require('cli-progress');
const nodeDiskInfo = require('node-disk-info');

const execAsync = promisify(exec);

const TEMP_DIR = path.join(require('os').tmpdir(), 'homelab-iso-flasher');

// Ensure temp directory exists
fs.ensureDirSync(TEMP_DIR);

program
  .name('homelab-iso-flasher')
  .description('Flash Homelab custom ISO to USB drive')
  .version('1.0.0')
  .option('-u, --url <url>', 'ISO download URL')
  .option('-d, --drive <drive>', 'Target USB drive (e.g., /dev/sdb or D:)')
  .option('-y, --yes', 'Skip confirmation prompts (dangerous!)')
  .parse(process.argv);

const options = program.opts();

// Platform-specific implementations
const platform = process.platform;

/**
 * Get list of removable USB drives
 */
async function getUSBDrives() {
  const spinner = ora('Detecting USB drives...').start();

  try {
    if (platform === 'win32') {
      return await getUSBDrivesWindows();
    } else if (platform === 'darwin') {
      return await getUSBDrivesMacOS();
    } else {
      return await getUSBDrivesLinux();
    }
  } catch (error) {
    spinner.fail('Failed to detect USB drives');
    throw error;
  } finally {
    spinner.stop();
  }
}

async function getUSBDrivesWindows() {
  try {
    const disks = await nodeDiskInfo.getDiskInfo();
    return disks
      .filter(disk => {
        // Filter for removable drives
        return disk.blocks && disk.blocks > 0;
      })
      .map(disk => ({
        device: disk.mounted,
        size: disk.blocks,
        label: disk.filesystem || 'Unknown',
        model: 'USB Drive',
        path: disk.mounted
      }));
  } catch (error) {
    console.error(chalk.red('Error detecting drives. Please run as Administrator.'));
    throw error;
  }
}

async function getUSBDrivesMacOS() {
  try {
    const { stdout } = await execAsync('diskutil list external physical');
    const lines = stdout.split('\n');

    const drives = [];
    let currentDrive = null;

    for (const line of lines) {
      // Match disk identifier lines like "/dev/disk2"
      const diskMatch = line.match(/^\/dev\/(disk\d+)/);
      if (diskMatch) {
        if (currentDrive) {
          drives.push(currentDrive);
        }
        currentDrive = {
          device: `/dev/${diskMatch[1]}`,
          path: `/dev/${diskMatch[1]}`,
          size: 0,
          label: '',
          model: ''
        };
      }

      // Extract size
      const sizeMatch = line.match(/(\d+\.\d+\s+[KMGT]B)/);
      if (sizeMatch && currentDrive) {
        currentDrive.size = sizeMatch[1];
      }

      // Extract disk name
      const nameMatch = line.match(/\d+:\s+(.+?)\s+/);
      if (nameMatch && currentDrive && !currentDrive.label) {
        currentDrive.label = nameMatch[1];
      }
    }

    if (currentDrive) {
      drives.push(currentDrive);
    }

    return drives;
  } catch (error) {
    console.error(chalk.red('Error detecting drives. Please ensure you have permissions.'));
    throw error;
  }
}

async function getUSBDrivesLinux() {
  try {
    const { stdout } = await execAsync('lsblk -J -o NAME,SIZE,TYPE,HOTPLUG,MODEL,MOUNTPOINT');
    const data = JSON.parse(stdout);

    const drives = [];

    for (const device of data.blockdevices) {
      // Filter for removable drives (hotplug=1) and disk type
      if (device.hotplug === '1' && device.type === 'disk') {
        drives.push({
          device: `/dev/${device.name}`,
          path: `/dev/${device.name}`,
          size: device.size,
          label: device.mountpoint || 'Unmounted',
          model: device.model || 'USB Drive'
        });
      }
    }

    return drives;
  } catch (error) {
    console.error(chalk.red('Error detecting drives. Please run with sudo if needed.'));
    throw error;
  }
}

/**
 * Download ISO file with progress bar
 */
async function downloadISO(url) {
  const filename = path.join(TEMP_DIR, `homelab-custom-${Date.now()}.iso`);
  const writer = fs.createWriteStream(filename);

  console.log(chalk.blue('\n📥 Downloading ISO file...'));

  try {
    const response = await axios({
      method: 'get',
      url: url,
      responseType: 'stream',
      onDownloadProgress: (progressEvent) => {
        // Progress handled by stream events below
      }
    });

    const totalLength = response.headers['content-length'];

    const progressBar = new cliProgress.SingleBar({
      format: 'Download |{bar}| {percentage}% | {value}/{total} MB | ETA: {eta}s',
      barCompleteChar: '\u2588',
      barIncompleteChar: '\u2591',
      hideCursor: true
    });

    progressBar.start(Math.round(totalLength / 1024 / 1024), 0);

    let downloaded = 0;

    response.data.on('data', (chunk) => {
      downloaded += chunk.length;
      progressBar.update(Math.round(downloaded / 1024 / 1024));
    });

    response.data.pipe(writer);

    return new Promise((resolve, reject) => {
      writer.on('finish', () => {
        progressBar.stop();
        console.log(chalk.green('✓ Download complete\n'));
        resolve(filename);
      });
      writer.on('error', (err) => {
        progressBar.stop();
        reject(err);
      });
    });
  } catch (error) {
    console.error(chalk.red('Failed to download ISO:'), error.message);
    throw error;
  }
}

/**
 * Unmount/eject drive before flashing
 */
async function unmountDrive(drivePath) {
  const spinner = ora('Unmounting drive...').start();

  try {
    if (platform === 'win32') {
      // Windows - try to remove drive letter assignment
      await execAsync(`mountvol ${drivePath} /d`).catch(() => {
        // Might fail if not mounted, that's okay
      });
    } else if (platform === 'darwin') {
      // macOS - unmount all partitions
      await execAsync(`diskutil unmountDisk ${drivePath}`);
    } else {
      // Linux - unmount all partitions
      await execAsync(`sudo umount ${drivePath}* 2>/dev/null || true`);
    }

    spinner.succeed('Drive unmounted');
  } catch (error) {
    spinner.warn('Could not unmount drive (may already be unmounted)');
  }
}

/**
 * Write ISO to USB drive
 */
async function writeISO(isoPath, drivePath) {
  console.log(chalk.blue('\n💾 Writing ISO to USB drive...'));
  console.log(chalk.yellow('⚠️  This may take 10-30 minutes depending on USB speed\n'));

  try {
    if (platform === 'win32') {
      await writeISOWindows(isoPath, drivePath);
    } else if (platform === 'darwin') {
      await writeISOMacOS(isoPath, drivePath);
    } else {
      await writeISOLinux(isoPath, drivePath);
    }

    console.log(chalk.green('\n✓ ISO written successfully!\n'));
  } catch (error) {
    console.error(chalk.red('Failed to write ISO:'), error.message);
    throw error;
  }
}

async function writeISOWindows(isoPath, drivePath) {
  // Windows requires a 3rd party tool like Rufus or Win32DiskImager
  // For now, provide instructions
  console.log(chalk.yellow('\n⚠️  Windows USB flashing requires administrator privileges'));
  console.log(chalk.blue('\nAutomatic flashing on Windows is not yet supported.'));
  console.log(chalk.blue('Please use one of these tools to flash the ISO:\n'));
  console.log(chalk.white('1. Rufus (Recommended): https://rufus.ie/'));
  console.log(chalk.white('2. balenaEtcher: https://www.balena.io/etcher/'));
  console.log(chalk.white('3. Win32 Disk Imager: https://sourceforge.net/projects/win32diskimager/\n'));
  console.log(chalk.blue(`ISO file location: ${chalk.white(isoPath)}`));
  console.log(chalk.blue(`Target drive: ${chalk.white(drivePath)}\n`));

  throw new Error('Manual flashing required on Windows');
}

async function writeISOMacOS(isoPath, drivePath) {
  console.log(chalk.yellow('This requires administrator privileges. You may be prompted for your password.\n'));

  // Use dd with progress (requires pv if available, otherwise regular dd)
  const hasProgress = await execAsync('which pv').then(() => true).catch(() => false);

  if (hasProgress) {
    // Use pv for progress
    const fileSize = fs.statSync(isoPath).size;
    const command = `sudo sh -c "pv -s ${fileSize} ${isoPath} | dd of=${drivePath} bs=4M"`;

    await new Promise((resolve, reject) => {
      const process = spawn('sh', ['-c', command], { stdio: 'inherit' });
      process.on('close', (code) => {
        if (code === 0) resolve();
        else reject(new Error(`dd exited with code ${code}`));
      });
    });
  } else {
    // Regular dd without progress
    console.log(chalk.yellow('Install "pv" for progress indication: brew install pv\n'));
    await execAsync(`sudo dd if=${isoPath} of=${drivePath} bs=4m`);
  }

  // Sync to ensure all data is written
  await execAsync('sync');
}

async function writeISOLinux(isoPath, drivePath) {
  console.log(chalk.yellow('This requires root privileges. You may be prompted for your password.\n'));

  // Use dd with progress (requires pv if available)
  const hasProgress = await execAsync('which pv').then(() => true).catch(() => false);

  if (hasProgress) {
    // Use pv for progress
    const fileSize = fs.statSync(isoPath).size;
    const command = `sudo sh -c "pv -s ${fileSize} ${isoPath} | dd of=${drivePath} bs=4M status=progress"`;

    await new Promise((resolve, reject) => {
      const process = spawn('sh', ['-c', command], { stdio: 'inherit' });
      process.on('close', (code) => {
        if (code === 0) resolve();
        else reject(new Error(`dd exited with code ${code}`));
      });
    });
  } else {
    // Regular dd with status=progress
    console.log(chalk.yellow('Install "pv" for better progress indication: sudo apt install pv\n'));
    await execAsync(`sudo dd if=${isoPath} of=${drivePath} bs=4M status=progress`);
  }

  // Sync to ensure all data is written
  await execAsync('sync');
}

/**
 * Eject drive safely
 */
async function ejectDrive(drivePath) {
  const spinner = ora('Safely ejecting drive...').start();

  try {
    if (platform === 'win32') {
      // Windows eject not implemented
      spinner.info('Please safely eject the drive from Windows Explorer');
    } else if (platform === 'darwin') {
      await execAsync(`diskutil eject ${drivePath}`);
      spinner.succeed('Drive ejected safely - you can now remove it');
    } else {
      await execAsync(`sudo eject ${drivePath}`);
      spinner.succeed('Drive ejected safely - you can now remove it');
    }
  } catch (error) {
    spinner.warn('Could not eject drive automatically - please eject manually');
  }
}

/**
 * Cleanup temporary files
 */
async function cleanup(isoPath) {
  try {
    if (isoPath && fs.existsSync(isoPath)) {
      await fs.remove(isoPath);
      console.log(chalk.gray('Temporary files cleaned up'));
    }
  } catch (error) {
    console.log(chalk.gray('Could not clean up temporary files'));
  }
}

/**
 * Main execution flow
 */
async function main() {
  console.log(chalk.bold.cyan('\n╔═══════════════════════════════════════╗'));
  console.log(chalk.bold.cyan('║   Homelab ISO USB Flasher v1.0.0    ║'));
  console.log(chalk.bold.cyan('╚═══════════════════════════════════════╝\n'));

  let isoPath = null;

  try {
    // Step 1: Get ISO URL
    let isoUrl = options.url;
    if (!isoUrl) {
      const urlAnswer = await inquirer.prompt([
        {
          type: 'input',
          name: 'url',
          message: 'Enter the ISO download URL:',
          validate: (input) => {
            if (!input) return 'URL is required';
            if (!input.startsWith('http')) return 'Must be a valid HTTP(S) URL';
            return true;
          }
        }
      ]);
      isoUrl = urlAnswer.url;
    }

    // Step 2: Download ISO
    isoPath = await downloadISO(isoUrl);

    // Step 3: Check root/admin permissions
    if (platform !== 'win32' && process.getuid && process.getuid() !== 0) {
      console.log(chalk.yellow('⚠️  This tool needs to run commands with sudo privileges'));
      console.log(chalk.yellow('   You will be prompted for your password when needed\n'));
    }

    // Step 4: List USB drives
    const drives = await getUSBDrives();

    if (drives.length === 0) {
      console.log(chalk.red('\n❌ No USB drives detected!'));
      console.log(chalk.yellow('Please insert a USB drive and try again.\n'));
      process.exit(1);
    }

    console.log(chalk.green(`\n✓ Found ${drives.length} USB drive(s)\n`));

    // Step 5: Select target drive
    let targetDrive = options.drive;
    if (!targetDrive) {
      const driveChoices = drives.map(d => ({
        name: `${d.device} - ${d.size} - ${d.model || d.label}`,
        value: d.path
      }));

      const driveAnswer = await inquirer.prompt([
        {
          type: 'list',
          name: 'drive',
          message: 'Select target USB drive:',
          choices: driveChoices
        }
      ]);
      targetDrive = driveAnswer.drive;
    }

    // Step 6: Confirm (unless -y flag)
    if (!options.yes) {
      console.log(chalk.red.bold('\n⚠️  WARNING: ALL DATA ON THE SELECTED DRIVE WILL BE ERASED! ⚠️\n'));
      console.log(chalk.white(`ISO file: ${path.basename(isoPath)}`));
      console.log(chalk.white(`Target drive: ${targetDrive}\n`));

      const confirmAnswer = await inquirer.prompt([
        {
          type: 'confirm',
          name: 'confirm',
          message: 'Are you absolutely sure you want to continue?',
          default: false
        }
      ]);

      if (!confirmAnswer.confirm) {
        console.log(chalk.yellow('\nOperation cancelled by user\n'));
        await cleanup(isoPath);
        process.exit(0);
      }
    }

    // Step 7: Unmount drive
    await unmountDrive(targetDrive);

    // Step 8: Write ISO
    await writeISO(isoPath, targetDrive);

    // Step 9: Eject drive
    await ejectDrive(targetDrive);

    // Step 10: Cleanup
    await cleanup(isoPath);

    console.log(chalk.green.bold('✓ Successfully created bootable USB drive!\n'));
    console.log(chalk.blue('You can now use this USB drive to install your custom Homelab Ubuntu Server.\n'));

  } catch (error) {
    console.error(chalk.red('\n❌ Error:'), error.message);

    if (isoPath) {
      await cleanup(isoPath);
    }

    process.exit(1);
  }
}

// Run main function
if (require.main === module) {
  main();
}

module.exports = { main };
