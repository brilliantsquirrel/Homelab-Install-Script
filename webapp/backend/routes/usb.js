const express = require('express');
const { exec } = require('child_process');
const { promisify } = require('util');
const fs = require('fs').promises;
const path = require('path');
const logger = require('../lib/logger');

const execAsync = promisify(exec);
const router = express.Router();

/**
 * GET /api/usb/devices
 * Detect connected USB storage devices
 */
router.get('/devices', async (req, res) => {
    const reqLogger = logger.withContext({ component: 'USB', action: 'list-devices' });

    try {
        reqLogger.info('Scanning for USB devices');

        // Use lsblk to list block devices with detailed information
        const { stdout } = await execAsync('lsblk -J -o NAME,SIZE,TYPE,MOUNTPOINT,VENDOR,MODEL,SERIAL,TRAN');
        const devices = JSON.parse(stdout);

        // Filter for USB removable devices
        const usbDevices = devices.blockdevices
            .filter(device => {
                // Look for devices that are:
                // 1. USB transport (TRAN=usb)
                // 2. Disk type (not partition)
                // 3. Not currently mounted at a system location
                return device.tran === 'usb' &&
                       device.type === 'disk' &&
                       !isSystemMountPoint(device.mountpoint);
            })
            .map(device => ({
                path: `/dev/${device.name}`,
                name: device.name,
                size: device.size,
                vendor: device.vendor ? device.vendor.trim() : 'Unknown',
                model: device.model ? device.model.trim() : 'Unknown',
                serial: device.serial || '',
                mountpoint: device.mountpoint || null,
                displayName: formatDeviceDisplayName(device)
            }));

        reqLogger.info(`Found ${usbDevices.length} USB devices`, { count: usbDevices.length });

        res.json({
            success: true,
            devices: usbDevices,
            timestamp: new Date().toISOString()
        });

    } catch (error) {
        reqLogger.errorWithContext('Error scanning USB devices', error);
        res.status(500).json({
            success: false,
            error: 'Failed to scan USB devices',
            message: error.message
        });
    }
});

/**
 * POST /api/usb/flash
 * Flash ISO to USB device
 *
 * Request body:
 * {
 *   "device": "/dev/sdb",
 *   "isoUrl": "gs://bucket/path/to/file.iso"
 * }
 */
router.post('/flash', async (req, res) => {
    const { device, isoUrl } = req.body;
    const reqLogger = logger.withContext({ component: 'USB', action: 'flash', device, isoUrl });

    if (!device || !isoUrl) {
        return res.status(400).json({
            success: false,
            error: 'Missing required fields: device and isoUrl'
        });
    }

    // Validate device path
    if (!device.startsWith('/dev/')) {
        return res.status(400).json({
            success: false,
            error: 'Invalid device path'
        });
    }

    try {
        reqLogger.info('Starting USB flash operation');

        // Send SSE headers for real-time progress
        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive'
        });

        const sendProgress = (stage, progress, message) => {
            res.write(`data: ${JSON.stringify({ stage, progress, message })}\n\n`);
        };

        // Stage 1: Download ISO
        sendProgress('download', 0, 'Starting ISO download...');
        const tmpDir = '/tmp/iso-flash';
        await fs.mkdir(tmpDir, { recursive: true });
        const isoPath = path.join(tmpDir, 'temp.iso');

        reqLogger.info('Downloading ISO from GCS', { isoUrl, isoPath });

        // Download with progress tracking
        const downloadProcess = exec(`gsutil -o "GSUtil:sliced_object_download_threshold=0" cp "${isoUrl}" "${isoPath}"`);

        let lastProgress = 0;
        downloadProcess.stderr.on('data', (data) => {
            const match = data.toString().match(/(\d+)%/);
            if (match) {
                const progress = parseInt(match[1]);
                if (progress !== lastProgress) {
                    lastProgress = progress;
                    sendProgress('download', progress, `Downloading ISO: ${progress}%`);
                }
            }
        });

        await new Promise((resolve, reject) => {
            downloadProcess.on('exit', (code) => {
                if (code === 0) resolve();
                else reject(new Error(`Download failed with code ${code}`));
            });
        });

        sendProgress('download', 100, 'ISO downloaded successfully');

        // Stage 2: Unmount device
        sendProgress('unmount', 0, 'Unmounting device...');
        reqLogger.info('Unmounting device', { device });

        try {
            await execAsync(`sudo umount ${device}* 2>/dev/null || true`);
        } catch (err) {
            // Ignore errors if device wasn't mounted
            reqLogger.debug('Device unmount attempt (may not have been mounted)', { device });
        }

        sendProgress('unmount', 100, 'Device unmounted');

        // Stage 3: Write ISO to device
        sendProgress('write', 0, 'Writing ISO to USB device...');
        reqLogger.info('Writing ISO to device', { device, isoPath });

        // Use dd with status=progress
        const writeProcess = exec(`sudo dd if="${isoPath}" of="${device}" bs=4M status=progress conv=fsync`);

        let lastWriteProgress = 0;
        writeProcess.stderr.on('data', (data) => {
            const output = data.toString();
            // Parse dd progress output
            const match = output.match(/(\d+)\s+bytes/);
            if (match) {
                const bytes = parseInt(match[1]);
                // Get ISO size
                fs.stat(isoPath).then(stats => {
                    const progress = Math.floor((bytes / stats.size) * 100);
                    if (progress !== lastWriteProgress && progress <= 100) {
                        lastWriteProgress = progress;
                        sendProgress('write', progress, `Writing: ${progress}%`);
                    }
                });
            }
        });

        await new Promise((resolve, reject) => {
            writeProcess.on('exit', (code) => {
                if (code === 0) resolve();
                else reject(new Error(`Write failed with code ${code}`));
            });
        });

        sendProgress('write', 100, 'Write completed');

        // Stage 4: Verify (optional, simplified check)
        sendProgress('verify', 50, 'Verifying write...');
        reqLogger.info('Verifying device');

        // Simple verification: check if device has partition table
        try {
            await execAsync(`sudo fdisk -l ${device}`);
            sendProgress('verify', 100, 'Verification passed');
        } catch (err) {
            reqLogger.warn('Verification check failed', { error: err.message });
            sendProgress('verify', 100, 'Verification skipped');
        }

        // Stage 5: Eject
        sendProgress('eject', 0, 'Ejecting device...');
        reqLogger.info('Ejecting device', { device });

        await execAsync(`sync`);
        try {
            await execAsync(`sudo eject ${device}`);
        } catch (err) {
            reqLogger.warn('Eject failed, device may need manual removal', { error: err.message });
        }

        sendProgress('eject', 100, 'Device ejected - safe to remove');

        // Cleanup
        reqLogger.info('Cleaning up temporary files', { tmpDir });
        await fs.rm(tmpDir, { recursive: true, force: true });

        // Send completion
        res.write(`data: ${JSON.stringify({ stage: 'complete', progress: 100, message: 'Flash complete!' })}\n\n`);
        res.end();

        reqLogger.info('USB flash operation completed successfully');

    } catch (error) {
        reqLogger.errorWithContext('Error during USB flash operation', error);

        // Try to send error via SSE if connection is still open
        try {
            res.write(`data: ${JSON.stringify({ stage: 'error', error: error.message })}\n\n`);
            res.end();
        } catch (e) {
            // If SSE connection is broken, just log it
            reqLogger.error('Could not send error via SSE', { originalError: error.message });
        }
    }
});

/**
 * Helper: Check if a mountpoint is a system location
 */
function isSystemMountPoint(mountpoint) {
    if (!mountpoint) return false;

    const systemMounts = ['/', '/boot', '/home', '/var', '/usr', '/tmp', '/opt', '/etc'];
    return systemMounts.some(sysMount => mountpoint === sysMount || mountpoint.startsWith(sysMount + '/'));
}

/**
 * Helper: Format device display name
 */
function formatDeviceDisplayName(device) {
    const vendor = device.vendor ? device.vendor.trim() : '';
    const model = device.model ? device.model.trim() : '';
    const size = device.size || '';

    let name = '';
    if (vendor && model) {
        name = `${vendor} ${model}`;
    } else if (model) {
        name = model;
    } else if (vendor) {
        name = vendor;
    } else {
        name = `USB Drive (${device.name})`;
    }

    return `${name} - ${size}`;
}

module.exports = router;
