# Deployment Cheatsheet

> Quick reference for every command in this tutorial.
> **Note:** this stack uses **Compute Engine VMs**, not GKE. GKE equivalents are sketched at the bottom.

Conventions used below:
- `<name>`       — your app/project prefix (used for VM names, VPC, repo, etc.)
- `<project>`    — your GCP project ID
- `<region>`     — e.g. `europe-west4`
- `<zone>`       — e.g. `europe-west4-a`
- `<sha>`        — short git SHA used as image tag
- `<cidr>`       — your subnet range, e.g. `10.10.0.0/24`
- `<github-org>/<repo>` — your GitHub repo path

---

## 1. Local development

```bash
# First time
cp .env.example .env                       # then edit POSTGRES_PASSWORD + DATABASE_URL to match

# Build + run everything
docker compose up --build                  # http://localhost:3000

# Background / foreground
docker compose up -d                       # detached
docker compose ps                          # what's running
docker compose logs -f <service>           # tail one service
docker compose down                        # stop, KEEP db volume
docker compose down -v                     # stop, DELETE db volume (clean slate)

# Iterate fast on UI only
docker compose up -d db                    # just Postgres
cd backend && uvicorn app.main:app --reload   # native FastAPI on :8000
cd frontend && npm run dev                    # Vite on :5173

# Poke the DB
docker compose exec db psql -U <db-user> -d <db-name>
```

If you change `POSTGRES_PASSWORD`, also update it inside `DATABASE_URL`, then `docker compose down -v` to wipe the old volume.

---

## 2. Docker — images and containers

```bash
# Build / inspect
docker build -t <name>-backend ./backend
docker images                              # list images
docker history <image>                     # see every layer (debug fat images)
docker image ls                            # alias

# Run / debug
docker run --rm -p 8000:8000 <image>
docker ps                                  # running
docker ps -a                               # incl. stopped
docker exec -it <container> bash           # shell into a running container
docker logs --tail=100 <container>         # last 100 log lines

# Clean up
docker rm <id>                             # remove container
docker rmi <id>                            # remove image
docker system prune                        # dangling only
# WARNING: docker system prune -a -f --volumes   # nukes images + volumes too
```

Multi-stage build mantra: **`COPY requirements.txt` BEFORE `COPY app/`** so cache survives source edits.

---

## 3. gcloud — one-time setup

```bash
gcloud auth login                          # human login
gcloud projects create <project> --name="<Display Name>"
gcloud config set project <project>
gcloud config set compute/region <region>
gcloud config set compute/zone  <zone>
gcloud config list                         # sanity check

# Enable the APIs this tutorial uses
gcloud services enable \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  secretmanager.googleapis.com
```

---

## 4. VPC + subnet

```bash
gcloud compute networks create <name>-vpc \
  --subnet-mode=custom --bgp-routing-mode=regional

gcloud compute networks subnets create <subnet-name> \
  --network=<name>-vpc \
  --region=<region> \
  --range=<cidr>

# Inspect
gcloud compute networks list
gcloud compute networks subnets list --filter="network~<name>-vpc"
gcloud compute routes list                 --filter="network=<name>-vpc"
gcloud compute firewall-rules list         --filter="network=<name>-vpc"
```

---

## 5. Firewall rules

```bash
# SSH ONLY via Google's IAP range (no public 22)
gcloud compute firewall-rules create allow-ssh-from-iap \
  --network=<name>-vpc --direction=INGRESS --action=ALLOW \
  --rules=tcp:22 --source-ranges=35.235.240.0/20 \
  --target-tags=app,db

# Public HTTP/HTTPS → only VMs tagged `app`
gcloud compute firewall-rules create allow-http-public \
  --network=<name>-vpc --direction=INGRESS --action=ALLOW \
  --rules=tcp:80,tcp:443 --source-ranges=0.0.0.0/0 \
  --target-tags=app

# Postgres reachable ONLY from inside the subnet
gcloud compute firewall-rules create allow-internal-db \
  --network=<name>-vpc --direction=INGRESS --action=ALLOW \
  --rules=tcp:5432 --source-ranges=<cidr> \
  --target-tags=db
```

---

## 6. Compute Engine VMs

```bash
# DB VM — no public IP
gcloud compute instances create <name>-db \
  --machine-type=e2-small \
  --image-family=debian-12 --image-project=debian-cloud \
  --subnet=<subnet-name> --no-address --tags=db \
  --metadata-from-file=startup-script=scripts/startup-db.sh

# App VM — public IP
gcloud compute instances create <name>-app \
  --machine-type=e2-small \
  --image-family=debian-12 --image-project=debian-cloud \
  --subnet=<subnet-name> --tags=app \
  --metadata-from-file=startup-script=scripts/startup-app.sh

# Inspect
gcloud compute instances list
gcloud compute instances describe <name>-app

# Lifecycle
gcloud compute instances stop  <name>-app <name>-db   # pause (saves compute, not disk)
gcloud compute instances start <name>-app <name>-db
gcloud compute instances reset <name>-db              # reboot (startup script runs ONCE per VM, not on reset)
gcloud compute instances delete <name>-app <name>-db  # delete (saves everything)

# Metadata (e.g. inject the DB password BEFORE first boot)
gcloud compute instances add-metadata <name>-db \
  --metadata=db-password='<strong-password>'
```

### SSH (always via IAP — never expose port 22)

```bash
gcloud compute ssh <name>-app --tunnel-through-iap
gcloud compute ssh <name>-db  --tunnel-through-iap
gcloud compute ssh <name>-app --tunnel-through-iap --troubleshoot   # diagnose hangs

# One-shot remote command
gcloud compute ssh <name>-app --tunnel-through-iap -- \
  "sudo docker ps; sudo docker logs --tail=100 <name>-backend"
```

If you get an IAP IAM error:
```bash
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
  --member="user:<YOUR_EMAIL>" --role="roles/iap.tunnelResourceAccessor"
```

---

## 7. Artifact Registry

```bash
# Create the repo (once)
gcloud artifacts repositories create <repo-name> \
  --repository-format=docker \
  --location=$(gcloud config get-value compute/region) \
  --description="<description>"

# Auth docker on this machine
gcloud auth configure-docker <region>-docker.pkg.dev

# Tag + push
IMAGE=<region>-docker.pkg.dev/<project>/<repo-name>/<service>:<sha>
docker build -t "$IMAGE" ./<service>
docker push "$IMAGE"

# List / clean up
gcloud artifacts docker images list <region>-docker.pkg.dev/<project>/<repo-name>
gcloud artifacts docker images delete <full-tag> --delete-tags --quiet
```

Tag every image with the **git SHA** (immutable, rollbackable). Avoid `:latest` alone in production.

---

## 8. Secret Manager

```bash
# Create
echo -n "<value>" | gcloud secrets create <secret-name> \
  --replication-policy=automatic --data-file=-

# Read latest
gcloud secrets versions access latest --secret=<secret-name>

# Rotate (creates version 2, 3, …)
echo -n "<new-value>" | gcloud secrets versions add <secret-name> --data-file=-
```

---

## 9. Workload Identity Federation (CI/CD without JSON keys)

```bash
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
POOL=<pool-name>            # e.g. github-pool
PROVIDER=<provider-name>    # e.g. github
REPO=<github-org>/<repo>
SA=<sa-name>                # e.g. github-deployer

# 1) Service account
gcloud iam service-accounts create $SA --display-name="<display name>"

# 2) Least-privilege roles
for role in roles/artifactregistry.writer roles/compute.instanceAdmin.v1 \
            roles/iap.tunnelResourceAccessor roles/iam.serviceAccountUser \
            roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="$role"
done

# 3) Pool + provider, restricted to YOUR repo
gcloud iam workload-identity-pools create $POOL --location=global --display-name="<display name>"
gcloud iam workload-identity-pools providers create-oidc $PROVIDER \
  --location=global --workload-identity-pool=$POOL \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == '${REPO}'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# 4) Let GitHub impersonate the SA
gcloud iam service-accounts add-iam-policy-binding "${SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

# 5) Value for the GCP_WIF_PROVIDER GitHub secret
echo "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
```

### Required GitHub Secrets

| Secret              | Example                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------- |
| `GCP_PROJECT_ID`    | `<project>`                                                                              |
| `GCP_REGION`        | `<region>`                                                                               |
| `GCP_ZONE`          | `<zone>`                                                                                 |
| `GCP_WIF_PROVIDER`  | `projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<provider>`   |
| `GCP_DEPLOYER_SA`   | `<sa-name>@<project>.iam.gserviceaccount.com`                                            |
| `ARTIFACT_REPO`     | `<repo-name>`                                                                            |
| `APP_VM_NAME`       | `<name>-app`                                                                             |
| `DB_HOSTNAME`       | `<name>-db`                                                                              |

---

## 10. Logging + monitoring

```bash
# Read recent logs from the app VM
gcloud logging read \
  'resource.type="gce_instance" AND resource.labels.instance_id="<APP_VM_ID>"' \
  --limit=10 --format=json

# Tail in near real time
gcloud logging tail 'resource.type="gce_instance"'

# Find blocked packets
gcloud logging read \
  'resource.type="gce_subnetwork" AND jsonPayload.disposition="DENIED"' \
  --limit 5 --format='value(timestamp,jsonPayload.connection)'

# Audit log (who did what)
gcloud logging read 'protoPayload.@type="type.googleapis.com/google.cloud.audit.AuditLog"' --limit 5

# Uptime check
EXT_IP=$(gcloud compute instances describe <name>-app \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
gcloud monitoring uptime create <name>-healthz \
  --resource-type=uptime-url \
  --resource-labels=host=${EXT_IP},project_id=$(gcloud config get-value project) \
  --path="/healthz" --period=1
```

---

## 11. Rollback

```bash
# Method A: re-run a previous green workflow in the GitHub Actions UI.

# Method B: pin an older image on the VM
PREV_SHA=<known-good-short-sha>
BASE=<region>-docker.pkg.dev/<project>/<repo-name>
sudo docker pull "${BASE}/<service>:${PREV_SHA}"
sudo docker rm -f <name>-<service>
sudo docker run -d --name <name>-<service> ... "${BASE}/<service>:${PREV_SHA}"
```

This is why every image is tagged with the git SHA.

---

## 12. Troubleshooting one-liners

```bash
# What's actually running + last 100 log lines (single best command)
gcloud compute ssh <name>-app --tunnel-through-iap -- \
  "sudo docker ps; sudo docker logs --tail=100 <name>-backend; sudo docker logs --tail=100 <name>-frontend"

# Did the startup script run?
sudo cat /var/log/startup-complete.log
sudo journalctl -u google-startup-scripts.service -e

# Test DB reachability from the app VM
sudo apt-get install -y netcat-openbsd postgresql-client
nc -vz <name>-db 5432
psql "postgresql://<db-user>:<password>@<name>-db:5432/<db-name>" -c "\l"

# Internal DNS check
getent hosts <name>-db

# Local "port already allocated"
lsof -iTCP:3000 -sTCP:LISTEN          # macOS / Linux
Get-NetTCPConnection -LocalPort 3000  # PowerShell
```

---

## 13. Cleanup (cost control)

```bash
# Soft pause — stops compute charges, disk still bills
gcloud compute instances stop <name>-app <name>-db

# Full teardown (also see scripts/cleanup.sh)
gcloud compute instances delete <name>-app <name>-db --zone=<zone> --quiet
for r in allow-ssh-from-iap allow-http-public allow-internal-db; do
  gcloud compute firewall-rules delete "$r" --quiet
done
gcloud compute networks subnets delete <subnet-name> --region=<region> --quiet
gcloud compute networks delete <name>-vpc --quiet
gcloud artifacts repositories delete <repo-name> --location=<region> --quiet

# Orphans worth checking
gcloud compute disks list
gcloud compute addresses list --filter="status:RESERVED AND -users:*"

# Nuclear option
gcloud projects delete $(gcloud config get-value project)
```

Set a **billing budget alert** early — Cloud Console → Billing → Budgets & alerts.

---

## 14. GKE equivalents (for when you graduate)

You're not running GKE here, but if you migrate, these are the rough analogues:

| This tutorial (GCE)                              | GKE equivalent                                                |
| ------------------------------------------------ | ------------------------------------------------------------- |
| `gcloud compute instances create …`              | `gcloud container clusters create-auto <cluster>` (Autopilot) |
| `docker run …` on a VM                           | `kubectl apply -f deployment.yaml`                            |
| `sudo docker ps`                                 | `kubectl get pods`                                            |
| `sudo docker logs <name>`                        | `kubectl logs <pod>` / `kubectl logs -f -l app=<service>`     |
| `gcloud compute ssh … -- "<cmd>"`                | `kubectl exec -it <pod> -- bash`                              |
| Firewall rule on `target-tags=app`               | `NetworkPolicy` + Service of type `LoadBalancer`              |
| Manual `docker pull` + `docker run` deploy       | `kubectl set image deploy/<service> <service>=<image>:<sha>`  |
| Rollback via SHA tag on VM                       | `kubectl rollout undo deploy/<service>`                       |
| Secret Manager → env var on `docker run`         | Secret Manager CSI driver, or `kubectl create secret`         |
| Cloud Logging via VM agent                       | Same — GKE ships pod stdout/stderr to Cloud Logging automatically |

Useful GKE starter commands:

```bash
gcloud container clusters create-auto <cluster> --region=<region>
gcloud container clusters get-credentials <cluster> --region=<region>
kubectl get nodes
kubectl get pods -A
kubectl apply -f k8s/
kubectl rollout status deploy/<service>
kubectl rollout undo   deploy/<service>
```

For one or two services, **stay on Compute Engine + good CI/CD**. GKE earns its complexity at ~10 services or when you need autoscaling on queue depth.
