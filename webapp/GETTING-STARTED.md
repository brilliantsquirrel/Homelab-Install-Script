# Getting Started with Homelab ISO Builder

Choose your deployment path based on your experience level and preferences.

## 🚀 Quick Start (Automated - Recommended)

**Best for:** First-time users, quick deployment

**Time:** 15-20 minutes

```bash
cd webapp
./deploy.sh
```

This script will:
1. ✅ Check prerequisites
2. ✅ Create or select GCP project
3. ✅ Enable required APIs
4. ✅ Create GCS buckets
5. ✅ Configure IAM permissions
6. ✅ Deploy to Cloud Run
7. ✅ Test deployment
8. ✅ Open webapp in browser

**No prior GCP experience required!** The script guides you through every step.

---

## 📚 Step-by-Step Guide (Manual)

**Best for:** Learning the deployment process, custom configurations

**Time:** 20-30 minutes

Follow the comprehensive guide: **[QUICKSTART.md](QUICKSTART.md)**

Covers:
- Detailed prerequisites
- GCP project setup
- Manual API enablement
- Bucket creation with lifecycle policies
- IAM configuration
- Multiple deployment options (Cloud Run, App Engine, GKE)
- Testing and verification
- Monitoring setup
- Troubleshooting

---

## 🏗️ Production Deployment

**Best for:** Production environments, CI/CD pipelines

**Time:** 30-45 minutes

See the full deployment guide: **[deployment/DEPLOYMENT.md](deployment/DEPLOYMENT.md)**

Includes:
- Cloud Run deployment (serverless)
- App Engine deployment (managed)
- GKE deployment (Kubernetes)
- CI/CD with Cloud Build
- Custom domain configuration
- Authentication setup
- Security hardening
- Cost optimization
- Monitoring and alerting

---

## 📖 Documentation

### Core Documentation
- **[README.md](README.md)** - Project overview, architecture, API docs
- **[QUICKSTART.md](QUICKSTART.md)** - Zero-to-production guide
- **[IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md)** - Technical details
- **[deployment/DEPLOYMENT.md](deployment/DEPLOYMENT.md)** - Production deployment

### Scripts
- **[deploy.sh](deploy.sh)** - Automated deployment
- **[cleanup.sh](cleanup.sh)** - Remove all resources

### Configuration
- **[backend/config/config.js](backend/config/config.js)** - Service and model definitions
- **[backend/.env.example](backend/.env.example)** - Environment variables template

---

## 🎯 What Gets Deployed

### Cloud Run Service
- Node.js Express API server
- Auto-scaling (0-10 instances)
- 2GB RAM, 2 CPU
- HTTPS endpoint

### GCS Buckets
- **Artifacts bucket** - Cached Docker images and Ollama models
- **Downloads bucket** - Generated ISOs (7-day retention)

### IAM Permissions
- Compute Instance Admin (create VMs)
- Storage Object Admin (read/write buckets)
- Service Account User (run as service account)

---

## 💡 Quick Commands

### View Service URL
```bash
gcloud run services describe iso-builder --region REGION --format="value(status.url)"
```

### View Logs
```bash
gcloud run services logs tail iso-builder --region REGION
```

### Update Environment Variable
```bash
gcloud run services update iso-builder \
  --set-env-vars="KEY=VALUE" \
  --region REGION
```

### Check Costs
```bash
# View billing
gcloud billing accounts list

# Open billing dashboard
open "https://console.cloud.google.com/billing"
```

### Cleanup Everything
```bash
./cleanup.sh
```

---

## 🔍 Pre-Deployment Checklist

Before deploying, ensure you have:

- [ ] Google Cloud account with billing enabled
- [ ] gcloud CLI installed and authenticated
- [ ] Billing account ID (find at console.cloud.google.com/billing)
- [ ] Project ID decided (or let script generate one)
- [ ] Region selected (us-west1, us-central1, etc.)

If you're missing any of these, see **[QUICKSTART.md](QUICKSTART.md)** for detailed setup instructions.

---

## ⚡ Common Tasks

### After Deployment

**Test the webapp:**
```bash
# Get URL
SERVICE_URL=$(gcloud run services describe iso-builder --region REGION --format="value(status.url)")

# Health check
curl $SERVICE_URL/health

# Open in browser
open $SERVICE_URL
```

**Monitor builds:**
```bash
# View recent logs
gcloud run services logs read iso-builder --region REGION --limit 50

# Follow logs in real-time
gcloud run services logs tail iso-builder --region REGION

# Check for errors
gcloud run services logs read iso-builder --region REGION --log-filter="severity>=ERROR"
```

**Check active VMs:**
```bash
# List ISO builder VMs
gcloud compute instances list --filter="labels.purpose=iso-builder"

# Delete stuck VM
gcloud compute instances delete VM_NAME --zone ZONE
```

**View storage usage:**
```bash
# Check bucket sizes
gsutil du -sh gs://PROJECT_ID-artifacts
gsutil du -sh gs://PROJECT_ID-downloads

# List ISOs
gsutil ls -lh gs://PROJECT_ID-downloads
```

---

## 💰 Cost Management

### Expected Costs

**Per ISO Build:** ~$7-8
- VM (n2-standard-16): $0.80-1.60
- Local SSD: $0.24
- Egress: $6.00

**Monthly (10 builds):** ~$70-83
- Builds: $70-80
- Cloud Run: $0-5
- Storage: $2

### Reduce Costs

**Use smaller VMs:**
```bash
gcloud run services update iso-builder \
  --set-env-vars="VM_MACHINE_TYPE=n2-standard-8"
```

**Remove local SSDs:**
```bash
gcloud run services update iso-builder \
  --set-env-vars="VM_LOCAL_SSD_COUNT=0"
```

**Shorter ISO retention:**
```bash
# Edit lifecycle policy for 3-day retention
cat > /tmp/lifecycle-policy.json <<EOF
{
  "lifecycle": {
    "rule": [{"action": {"type": "Delete"}, "condition": {"age": 3}}]
  }
}
EOF
gsutil lifecycle set /tmp/lifecycle-policy.json gs://PROJECT_ID-downloads
```

**Set budget alerts:**
```bash
gcloud billing budgets create \
  --billing-account=BILLING_ACCOUNT_ID \
  --display-name="ISO Builder Budget" \
  --budget-amount=100USD \
  --threshold-rule=percent=50 \
  --threshold-rule=percent=90
```

---

## 🆘 Troubleshooting

### Deployment Fails

**Error: Permission denied**
```bash
# Re-grant IAM permissions
PROJECT_NUMBER=$(gcloud projects describe PROJECT_ID --format="value(projectNumber)")
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/compute.instanceAdmin.v1"
```

**Error: Quota exceeded**
```bash
# Check quotas
gcloud compute project-info describe --project=PROJECT_ID

# Request increase at:
open "https://console.cloud.google.com/iam-admin/quotas?project=PROJECT_ID"
```

**Error: Service unavailable (503)**
```bash
# Check service status
gcloud run services describe iso-builder --region REGION

# View error logs
gcloud run services logs read iso-builder --region REGION --limit 20
```

### Build Fails

**VM creation fails**
```bash
# Check recent VM errors
gcloud logging read "resource.type=gce_instance AND severity>=ERROR" --limit 10

# Try smaller machine type
gcloud run services update iso-builder \
  --set-env-vars="VM_MACHINE_TYPE=n2-standard-8"
```

**ISO download not working**
```bash
# Check bucket permissions
gsutil iam get gs://PROJECT_ID-downloads

# Verify ISO exists
gsutil ls gs://PROJECT_ID-downloads

# Check signed URL expiration
# Default: 1 hour, increase if needed:
gcloud run services update iso-builder \
  --set-env-vars="GCS_SIGNED_URL_EXPIRATION=7200"
```

For more troubleshooting, see **[QUICKSTART.md#troubleshooting](QUICKSTART.md#troubleshooting)**

---

## 🔐 Security

### Default Security

The deployment includes:
- ✅ Rate limiting (10 requests per 15 minutes)
- ✅ CORS restrictions
- ✅ Input validation
- ✅ VM isolation
- ✅ Signed URLs with expiration
- ✅ Automatic ISO cleanup (7 days)
- ✅ Minimal IAM permissions

### Optional Security Enhancements

**Require authentication:**
```bash
gcloud run services update iso-builder \
  --region REGION \
  --no-allow-unauthenticated

# Grant specific user access
gcloud run services add-iam-policy-binding iso-builder \
  --region REGION \
  --member="user:email@example.com" \
  --role="roles/run.invoker"
```

**Enable Cloud IAP:**
```bash
gcloud iap web enable \
  --resource-type=backend-services \
  --service=iso-builder
```

**Use custom domain with SSL:**
```bash
gcloud run domain-mappings create \
  --service iso-builder \
  --domain iso-builder.yourdomain.com \
  --region REGION
```

---

## 📊 Monitoring

### View Metrics

**Cloud Console:**
```bash
# Open metrics dashboard
echo "https://console.cloud.google.com/run/detail/REGION/iso-builder/metrics?project=PROJECT_ID"
```

**Command Line:**
```bash
# Request count (last hour)
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=iso-builder" \
  --limit 100 --format json | jq -r '.[] | .httpRequest.status' | sort | uniq -c

# Error rate
gcloud logging read "resource.type=cloud_run_revision AND severity>=ERROR" \
  --limit 50

# Build success rate
gcloud logging read "resource.labels.service_name=iso-builder AND textPayload=~\"Build.*complete\"" \
  --limit 20
```

### Set Up Alerts

**Uptime check:**
```bash
gcloud monitoring uptime-checks create https iso-builder-health \
  --resource-type=uptime-url \
  --resource-url=https://YOUR_SERVICE_URL/health
```

**Error alert:**
```bash
gcloud alpha monitoring policies create \
  --notification-channels=CHANNEL_ID \
  --display-name="ISO Builder Errors" \
  --condition-threshold-value=5 \
  --condition-threshold-duration=300s
```

---

## 🎓 Learning Resources

### GCP Documentation
- [Cloud Run Quickstart](https://cloud.google.com/run/docs/quickstarts)
- [Cloud Storage Guide](https://cloud.google.com/storage/docs)
- [Compute Engine VMs](https://cloud.google.com/compute/docs)

### Project Documentation
- [Architecture Overview](README.md#architecture)
- [API Documentation](README.md#api-endpoints)
- [Build Process](README.md#build-process)

### Video Tutorials
- [Google Cloud Run Tutorial](https://www.youtube.com/results?search_query=google+cloud+run+tutorial)
- [GCS Basics](https://www.youtube.com/results?search_query=google+cloud+storage+tutorial)

---

## 🤝 Support

### Get Help
- **GitHub Issues:** [Report bugs or request features](https://github.com/brilliantsquirrel/Homelab-Install-Script/issues)
- **Documentation:** Check README.md and QUICKSTART.md
- **GCP Support:** [Google Cloud Console](https://console.cloud.google.com/support)

### Common Questions

**Q: How much does this cost?**
A: ~$7-8 per ISO build. See [Cost Management](#-cost-management) for details.

**Q: How long does a build take?**
A: 60-90 minutes for first build, 30-45 minutes for subsequent builds (with caching).

**Q: Can I customize the services?**
A: Yes! Edit `backend/config/config.js` to add/remove services and models.

**Q: How do I update the deployment?**
A: Run `./deploy.sh` again or use `gcloud run deploy` with new settings.

**Q: How do I delete everything?**
A: Run `./cleanup.sh` to remove all resources.

---

## 🎉 Next Steps

After successful deployment:

1. **Build your first ISO**
   - Open the webapp
   - Select services and models
   - Click "Start Build"
   - Download when complete

2. **Customize configuration**
   - Edit `backend/config/config.js`
   - Add custom services
   - Modify VM resources
   - Adjust retention policies

3. **Set up monitoring**
   - Configure uptime checks
   - Create error alerts
   - Set budget limits

4. **Share with others**
   - Add authentication
   - Configure custom domain
   - Set up usage quotas

---

**Ready to deploy?**

Run `./deploy.sh` to get started! 🚀
