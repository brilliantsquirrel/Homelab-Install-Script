# Homelab ISO Builder Web Application

A web-based interface for creating custom Ubuntu ISOs with selectable homelab services and AI models.

## Architecture

### Frontend
- Single-page web application (HTML/CSS/JavaScript)
- Service selection interface with dependency visualization
- AI model selection
- Real-time build progress tracking
- ISO download functionality

### Backend
- Node.js/Express REST API
- GCP VM orchestration for ISO builds
- Google Cloud Storage integration
- Build queue management
- WebSocket for real-time progress updates

### Build Process
1. User selects services and models via web interface
2. Backend creates a GCP VM instance
3. VM downloads selected dependencies from GCS bucket
4. VM builds custom ISO with selected components
5. ISO is uploaded to GCS bucket
6. User downloads ISO from secure link

## Directory Structure

```
webapp/
├── frontend/              # Web interface
│   ├── index.html        # Main page
│   ├── css/
│   │   └── style.css     # Styles
│   └── js/
│       ├── app.js        # Main application logic
│       └── api.js        # API client
├── backend/              # REST API server
│   ├── server.js         # Express server
│   ├── package.json      # Dependencies
│   ├── routes/
│   │   ├── build.js      # Build endpoints
│   │   └── services.js   # Service metadata
│   ├── lib/
│   │   ├── vm-manager.js        # VM lifecycle management
│   │   ├── gcs-manager.js       # Cloud storage operations
│   │   └── build-orchestrator.js # Build coordination
│   └── config/
│       └── config.js     # Configuration
├── scripts/
│   └── iso-prepare-dynamic.sh   # Modified ISO prep script
└── deployment/
    ├── app.yaml          # App Engine config
    └── cloudbuild.yaml   # CI/CD config
```

## Setup

### Prerequisites
- Google Cloud Project with billing enabled
- gcloud CLI installed and configured
- Node.js 18+ installed
- Cloud Storage bucket for artifacts

### Configuration

1. **Create GCS Buckets:**
```bash
# Bucket for Docker images and Ollama models (cached dependencies)
gsutil mb -p YOUR_PROJECT_ID -l us-west1 gs://homelab-iso-artifacts

# Bucket for generated ISOs (user downloads)
gsutil mb -p YOUR_PROJECT_ID -l us-west1 gs://homelab-iso-downloads
```

2. **Set Environment Variables:**
```bash
export GCP_PROJECT_ID="your-project-id"
export GCS_ARTIFACTS_BUCKET="homelab-iso-artifacts"
export GCS_DOWNLOADS_BUCKET="homelab-iso-downloads"
export API_SECRET_KEY="your-random-secret-key"
```

3. **Install Dependencies:**
```bash
cd webapp/backend
npm install
```

### Running Locally

```bash
# Start backend server
cd webapp/backend
npm start

# Server runs on http://localhost:8080
# Frontend accessible at http://localhost:8080
```

### Deploying to Google Cloud

```bash
# Deploy to App Engine
cd webapp/backend
gcloud app deploy

# Deploy to Cloud Run (alternative)
gcloud run deploy iso-builder-webapp \
  --source . \
  --platform managed \
  --region us-west1 \
  --allow-unauthenticated
```

## API Endpoints

### GET /api/services
Get available Docker services and their dependencies.

**Response:**
```json
{
  "services": [
    {
      "name": "ollama",
      "display": "Ollama (LLM Runtime)",
      "description": "Local LLM runtime with GPU support",
      "category": "ai",
      "dependencies": [],
      "required": false
    },
    ...
  ]
}
```

### GET /api/models
Get available Ollama models.

**Response:**
```json
{
  "models": [
    {
      "name": "gpt-oss:20b",
      "size": "12GB",
      "description": "20B parameter open-source LLM"
    },
    ...
  ]
}
```

### POST /api/build
Start a new ISO build.

**Request:**
```json
{
  "services": ["ollama", "openwebui", "nextcloud", "pihole"],
  "models": ["qwen3:8b", "qwen3-coder:30b"],
  "gpu_enabled": true,
  "email": "user@example.com"
}
```

**Response:**
```json
{
  "build_id": "abc123def456",
  "status": "queued",
  "estimated_time_minutes": 90
}
```

### GET /api/build/:buildId/status
Get build status and progress.

**Response:**
```json
{
  "build_id": "abc123def456",
  "status": "building",
  "progress": 45,
  "stage": "creating_iso",
  "logs": [
    "2025-11-11 10:30:00 - VM created",
    "2025-11-11 10:32:00 - Downloading dependencies...",
    "2025-11-11 11:00:00 - Building ISO..."
  ],
  "vm_name": "iso-build-abc123",
  "estimated_completion": "2025-11-11T12:30:00Z"
}
```

### GET /api/build/:buildId/download
Download the completed ISO.

**Response:**
- Redirect to signed GCS URL (valid for 1 hour)
- Or stream ISO file directly

## Build Stages

1. **Queued** (0%) - Build request received
2. **Creating VM** (10%) - Spinning up GCP compute instance
3. **Downloading Dependencies** (20-40%) - Fetching Docker images and models
4. **Building ISO** (40-80%) - Creating custom Ubuntu ISO
5. **Uploading ISO** (80-95%) - Uploading to GCS bucket
6. **Complete** (100%) - ISO ready for download
7. **Cleanup** - VM terminated, temporary files removed

## Security

- API authentication using JWT tokens
- Rate limiting: 3 builds per user per day
- VM auto-cleanup after 4 hours
- Signed URLs for ISO downloads (1 hour expiration)
- CORS restrictions to allowed domains
- Input validation and sanitization

## Cost Optimization

- VMs automatically stopped after build completion
- Aggressive caching of Docker images and models in GCS
- Build queue to prevent resource exhaustion
- Incremental ISO builds (only changed components)

## Monitoring

- Build success/failure metrics
- Average build time tracking
- VM utilization monitoring
- GCS storage usage alerts

## Limitations

- Maximum 3 concurrent builds
- ISOs stored for 7 days, then auto-deleted
- Maximum ISO size: 150GB
- Build timeout: 4 hours

## Development

### Running Tests
```bash
cd webapp/backend
npm test
```

### Local Development with Mock GCP
```bash
# Use local Docker instead of GCP VMs
export USE_LOCAL_DOCKER=true
npm run dev
```

## Support

For issues and feature requests, please open an issue on GitHub:
https://github.com/brilliantsquirrel/Homelab-Install-Script/issues
