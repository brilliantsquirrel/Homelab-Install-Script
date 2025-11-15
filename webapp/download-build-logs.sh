#!/bin/bash
# Download build logs from GCS
# Usage: ./download-build-logs.sh [BUILD_ID] [OUTPUT_DIR]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Error: gcloud CLI is not installed${NC}"
    echo "Install it from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Check if gsutil is installed
if ! command -v gsutil &> /dev/null; then
    echo -e "${RED}Error: gsutil is not installed${NC}"
    echo "Install it with: gcloud components install gsutil"
    exit 1
fi

# Load config
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

DOWNLOADS_BUCKET="${GCS_DOWNLOADS_BUCKET:-homelab-iso-downloads}"
BUILD_ID="$1"
OUTPUT_DIR="${2:-.}"

# Function to list all available logs
list_logs() {
    echo -e "${GREEN}Available build logs in gs://${DOWNLOADS_BUCKET}/logs/:${NC}"
    echo ""
    gsutil ls -lh "gs://${DOWNLOADS_BUCKET}/logs/" | grep -v "TOTAL:" || echo "No logs found"
}

# Function to download logs for a specific build
download_build_logs() {
    local build_id="$1"
    local output_dir="$2"

    # Extract short build ID (first 8 chars)
    local build_id_short="${build_id:0:8}"

    echo -e "${GREEN}Searching for logs matching build ID: ${build_id_short}${NC}"

    # Find logs matching the build ID
    local logs=$(gsutil ls "gs://${DOWNLOADS_BUCKET}/logs/" | grep "build-logs-${build_id_short}-" || true)

    if [ -z "$logs" ]; then
        echo -e "${YELLOW}No logs found for build ID: ${build_id_short}${NC}"
        echo ""
        echo "Available logs:"
        list_logs
        return 1
    fi

    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"

    # Download each log file
    for log_path in $logs; do
        local filename=$(basename "$log_path")
        echo -e "${GREEN}Downloading: ${filename}${NC}"
        gsutil cp "$log_path" "$output_dir/$filename"
        echo -e "${GREEN}Saved to: ${output_dir}/${filename}${NC}"
    done

    echo ""
    echo -e "${GREEN}Done! Logs downloaded to: ${output_dir}${NC}"
}

# Function to download the latest log
download_latest_log() {
    local output_dir="$1"

    echo -e "${GREEN}Finding latest build log...${NC}"

    # Get the most recent log file
    local latest_log=$(gsutil ls -l "gs://${DOWNLOADS_BUCKET}/logs/" | grep "build-logs-" | sort -k2 -r | head -n1 | awk '{print $3}')

    if [ -z "$latest_log" ]; then
        echo -e "${YELLOW}No logs found${NC}"
        return 1
    fi

    local filename=$(basename "$latest_log")
    mkdir -p "$output_dir"

    echo -e "${GREEN}Downloading: ${filename}${NC}"
    gsutil cp "$latest_log" "$output_dir/$filename"
    echo -e "${GREEN}Saved to: ${output_dir}/${filename}${NC}"

    # Display log preview
    echo ""
    echo -e "${GREEN}Log preview (last 30 lines):${NC}"
    tail -n 30 "$output_dir/$filename"
}

# Main logic
if [ -z "$BUILD_ID" ]; then
    echo "Usage: $0 [BUILD_ID|--list|--latest] [OUTPUT_DIR]"
    echo ""
    echo "Options:"
    echo "  BUILD_ID    Download logs for a specific build ID"
    echo "  --list      List all available build logs"
    echo "  --latest    Download the most recent build log"
    echo "  OUTPUT_DIR  Directory to save logs (default: current directory)"
    echo ""
    echo "Examples:"
    echo "  $0 --list"
    echo "  $0 --latest"
    echo "  $0 a1b2c3d4"
    echo "  $0 a1b2c3d4-e5f6-g7h8-i9j0-k1l2m3n4o5p6 ./logs"
    exit 1
fi

case "$BUILD_ID" in
    --list)
        list_logs
        ;;
    --latest)
        download_latest_log "$OUTPUT_DIR"
        ;;
    *)
        download_build_logs "$BUILD_ID" "$OUTPUT_DIR"
        ;;
esac
