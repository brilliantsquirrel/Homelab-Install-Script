// Google Cloud Storage Manager

const { Storage } = require('@google-cloud/storage');
const config = require('../config/config');
const logger = require('./logger');

class GCSManager {
    constructor() {
        this.storage = new Storage({
            projectId: config.gcp.projectId,
        });
        this.artifactsBucket = this.storage.bucket(config.gcs.artifactsBucket);
        this.downloadsBucket = this.storage.bucket(config.gcs.downloadsBucket);
    }

    /**
     * Check if artifacts bucket exists
     */
    async artifactsBucketExists() {
        try {
            const [exists] = await this.artifactsBucket.exists();
            return exists;
        } catch (error) {
            logger.error('Error checking artifacts bucket:', error);
            return false;
        }
    }

    /**
     * Check if downloads bucket exists
     */
    async downloadsBucketExists() {
        try {
            const [exists] = await this.downloadsBucket.exists();
            return exists;
        } catch (error) {
            logger.error('Error checking downloads bucket:', error);
            return false;
        }
    }

    /**
     * Get signed URL for downloading ISO
     * @param {string} isoFilename - ISO filename in bucket
     * @returns {string} Signed URL
     */
    async getSignedDownloadURL(isoFilename) {
        try {
            const file = this.downloadsBucket.file(isoFilename);

            // Security: Check if file exists before generating signed URL
            const [exists] = await file.exists();
            if (!exists) {
                throw new Error(`ISO file not found: ${isoFilename}`);
            }

            // Cloud Run workaround: Use service account email for signing
            const serviceAccount = process.env.GCS_SIGNING_EMAIL ||
                                 '644872244499-compute@developer.gserviceaccount.com';

            const [url] = await file.getSignedUrl({
                version: 'v4',
                action: 'read',
                expires: Date.now() + config.gcs.signedUrlExpiration * 1000,
                signingEndpoint: `https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${serviceAccount}:signBlob`,
            });

            logger.info(`Generated signed URL for ${isoFilename}`);
            return url;
        } catch (error) {
            logger.error(`Error generating signed URL for ${isoFilename}:`, error);
            throw error;
        }
    }

    /**
     * Check if ISO file exists in downloads bucket
     * @param {string} isoFilename - ISO filename
     * @returns {boolean}
     */
    async isoExists(isoFilename) {
        try {
            const file = this.downloadsBucket.file(isoFilename);
            const [exists] = await file.exists();
            return exists;
        } catch (error) {
            logger.error(`Error checking if ISO exists ${isoFilename}:`, error);
            return false;
        }
    }

    /**
     * Get ISO file metadata
     * @param {string} isoFilename - ISO filename
     * @returns {Object} File metadata
     */
    async getISOMetadata(isoFilename) {
        try {
            const file = this.downloadsBucket.file(isoFilename);
            const [metadata] = await file.getMetadata();
            return {
                name: metadata.name,
                size: parseInt(metadata.size),
                created: metadata.timeCreated,
                updated: metadata.updated,
                md5Hash: metadata.md5Hash,
            };
        } catch (error) {
            logger.error(`Error getting ISO metadata ${isoFilename}:`, error);
            throw error;
        }
    }

    /**
     * Delete old ISOs (older than retention period)
     */
    async cleanupOldISOs() {
        try {
            const retentionDate = new Date();
            retentionDate.setDate(retentionDate.getDate() - config.gcs.isoRetentionDays);

            logger.info(`Cleaning up ISOs older than ${retentionDate.toISOString()}`);

            const [files] = await this.downloadsBucket.getFiles();
            let deletedCount = 0;

            for (const file of files) {
                const [metadata] = await file.getMetadata();
                const created = new Date(metadata.timeCreated);

                if (created < retentionDate) {
                    await file.delete();
                    logger.info(`Deleted old ISO: ${file.name}`);
                    deletedCount++;
                }
            }

            logger.info(`Cleaned up ${deletedCount} old ISOs`);
            return deletedCount;
        } catch (error) {
            logger.error('Error cleaning up old ISOs:', error);
            throw error;
        }
    }

    /**
     * List all ISOs in downloads bucket
     */
    async listISOs() {
        try {
            const [files] = await this.downloadsBucket.getFiles();
            return files.map(file => ({
                name: file.name,
                // Additional metadata could be fetched if needed
            }));
        } catch (error) {
            logger.error('Error listing ISOs:', error);
            throw error;
        }
    }

    /**
     * Check if artifact file exists
     * @param {string} artifactPath - Path within artifacts bucket
     * @returns {boolean}
     */
    async artifactExists(artifactPath) {
        try {
            const file = this.artifactsBucket.file(artifactPath);
            const [exists] = await file.exists();
            return exists;
        } catch (error) {
            logger.error(`Error checking artifact ${artifactPath}:`, error);
            return false;
        }
    }

    /**
     * Get list of cached Docker images
     */
    async listCachedDockerImages() {
        try {
            const [files] = await this.artifactsBucket.getFiles({
                prefix: 'docker-images/',
            });
            return files.map(file => file.name);
        } catch (error) {
            logger.error('Error listing cached Docker images:', error);
            return [];
        }
    }

    /**
     * Get list of cached Ollama models
     */
    async listCachedOllamaModels() {
        try {
            const [files] = await this.artifactsBucket.getFiles({
                prefix: 'ollama-models/',
            });
            return files.map(file => file.name);
        } catch (error) {
            logger.error('Error listing cached Ollama models:', error);
            return [];
        }
    }

    /**
     * Download and parse build status file
     * @param {string} statusFilename - Status filename in downloads bucket
     * @returns {Object} Parsed status data
     */
    async downloadStatusFile(statusFilename) {
        try {
            const file = this.downloadsBucket.file(statusFilename);
            const [exists] = await file.exists();

            if (!exists) {
                return null;
            }

            const [contents] = await file.download();
            const statusData = JSON.parse(contents.toString());

            logger.debug(`Downloaded status file ${statusFilename}:`, statusData);
            return statusData;
        } catch (error) {
            logger.debug(`Error downloading status file ${statusFilename}: ${error.message}`);
            return null;
        }
    }

    /**
     * Delete file from downloads bucket
     * @param {string} filename - File to delete
     */
    async deleteFile(filename) {
        try {
            const file = this.downloadsBucket.file(filename);
            const [exists] = await file.exists();

            if (exists) {
                await file.delete();
                logger.info(`Deleted file: ${filename}`);
            }
        } catch (error) {
            logger.error(`Error deleting file ${filename}:`, error);
            throw error;
        }
    }
}

module.exports = new GCSManager();
