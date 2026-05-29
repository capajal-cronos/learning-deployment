# Deployment Cheatsheet

> Quick reference for every command in this tutorial.
> **Note:** this stack uses **Compute Engine VMs**, not GKE. GKE equivalents are sketched at the bottom.

Conventions used below:
- `<name>`       — your app/project prefix (used for VM names, VPC, repo, etc.)
- `<project>`    — your GCP project ID
- `<region>`     — e.g. `europe-west1`
- `<zone>`       — e.g. `europe-west1-a`
- `<sha>`        — short git SHA used as image tag
- `<cidr>`       — your subnet range, e.g. `10.10.0.0/24`
- `<vm>`         — any VM name, e.g. `<name>-app` or `<name>-db`. Most `gcloud compute instances …` subcommands accept multiple `<vm>` arguments to act on several VMs at once.
- `<github-org>/<repo>` — your GitHub repo path

### Where do I run these commands?

| Command shape | Run it on |
|---|---|
| `gcloud …`                                  | **Your laptop** (talks to the GCP API over HTTPS) |
| `docker build`, `docker push` (GCP image)   | **Your laptop** |
| `gcloud compute ssh … -- "<cmd>"`           | **Your laptop** — `gcloud` opens the SSH tunnel and runs `<cmd>` remotely for you |
| `sudo docker ps/logs/run …`                 | **Inside the VM** (after `gcloud compute ssh …`) |
| `sudo journalctl …`, `sudo cat /var/log/…`  | **Inside the VM** |
| `nc -vz <name>-db 5432`, `psql … <name>-db` | **Inside the VM** (internal DNS like `<name>-db` only resolves from inside the VPC) |
| `getent hosts <name>-db`                    | **Inside the VM** |

If you see a command that uses an internal hostname (`<name>-db`) or `sudo`, assume it's "inside the VM" unless the surrounding text says otherwise.

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

### "Where am I?" — sanity checks

When a `404` or empty list surprises you, it's almost always wrong project or wrong account. Check first, panic later.

```bash
# Which account + project is active right now?
gcloud config get-value account
gcloud config get-value project
gcloud auth list                           # all logged-in accounts, * marks active
gcloud projects list                       # every project the active account can see

# Switch account / project
gcloud config set account <email>
gcloud config set project  <project>

# Resources in the active project
gcloud compute instances list              # ALL zones in active project (empty = none)
gcloud compute instances list --zones=<zone>

# Hunt for VMs across EVERY project the active account can see
for p in $(gcloud projects list --format="value(projectId)"); do
  echo "=== $p ==="
  gcloud compute instances list --project="$p" 2>/dev/null
done

# Was something deleted? Who deleted it, and when?
gcloud logging read 'protoPayload.methodName="v1.compute.instances.delete"' \
  --limit=10 \
  --format="value(timestamp, protoPayload.resourceName, protoPayload.authenticationInfo.principalEmail)"
```

Stopping a VM (`instances stop`) ≠ deleting it. Stopped VMs still show up in `instances list` with status `TERMINATED`. If `list` is empty, the VM is gone — or you're looking in the wrong place.

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
gcloud compute routes list --filter="network=<name>-vpc"
gcloud compute firewall-rules list --filter="network=<name>-vpc" --format=json
```

### Cloud NAT (outbound internet for `--no-address` VMs)

Without this, private VMs can't reach apt repos and startup scripts that install packages will fail.

```bash
# Router + NAT (must exist BEFORE you create the DB VM)
gcloud compute routers create <name>-router \
  --network=<name>-vpc --region=<region>

gcloud compute routers nats create <name>-nat \
  --router=<name>-router --region=<region> \
  --nat-all-subnet-ip-ranges --auto-allocate-nat-external-ips

# Inspect
gcloud compute routers nats list --router=<name>-router --region=<region>

# Teardown (during cleanup)
gcloud compute routers nats   delete <name>-nat    --router=<name>-router --region=<region> --quiet
gcloud compute routers        delete <name>-router --region=<region> --quiet
```

---

## 5. Firewall rules

### Generic shape

```bash
gcloud compute firewall-rules create <rule-name> \
  --network=<vpc> \
  --direction=INGRESS \          # or EGRESS
  --action=ALLOW \               # or DENY
  --rules=<proto>:<port> \       # e.g. tcp:22 | tcp:80,tcp:443 | tcp:5432 | tcp (all TCP) | icmp
  --source-ranges=<cidr> \       # 0.0.0.0/0 (anywhere) | <subnet-cidr> | 35.235.240.0/20 (Google IAP)
  --target-tags=<tag>            # VMs with this network tag receive the rule; comma-separated for multiple
```

Names are **project-global** (not per-VPC), so two rules can't share a name even across networks.

### Useful source ranges to remember

| Source | What it means |
|---|---|
| `0.0.0.0/0` | The entire public internet — use sparingly, only for genuine public-facing ports. |
| `<your-subnet-cidr>` (e.g. `10.10.0.0/24`) | Only traffic that originates inside your VPC subnet — typical for internal DBs/caches. |
| `35.235.240.0/20` | Google's IAP tunnel range — only authenticated `gcloud compute ssh --tunnel-through-iap` sessions arrive from here. |
| `<office-public-ip>/32` | A single specific IP (e.g. your office or VPN). |

### Inspect / list / find

```bash
# All rules in a VPC (note the ~ for substring match — = doesn't work, network field is a URL)
gcloud compute firewall-rules list --filter="network~<vpc>"

# Just the rules touching a specific port
gcloud compute firewall-rules list \
  --filter="allowed.ports:22" \
  --format="table(name, network.basename(), sourceRanges.list():label=SRC_RANGES, targetTags.list():label=TARGET_TAGS)"

# Show every field of one rule
gcloud compute firewall-rules describe <rule-name>

# Just the fields that matter (compact one-liner)
gcloud compute firewall-rules describe <rule-name> \
  --format='value(network.basename(), direction, allowed, sourceRanges, targetTags)'

# Sweep through several rules and check their current state
for r in <rule-name-1> <rule-name-2> <rule-name-3>; do
  echo "=== $r ==="
  gcloud compute firewall-rules describe "$r" \
    --format='value(network.basename(), direction, sourceRanges, allowed, targetTags)' 2>/dev/null \
    || echo "(does not exist)"
done
```

### Update (in-place) and delete

```bash
# Edit specific fields without recreating. NOTE: --network can NOT be changed; delete+recreate for that.
gcloud compute firewall-rules update <rule-name> --source-ranges=<new-cidr>
gcloud compute firewall-rules update <rule-name> --rules=tcp:443
gcloud compute firewall-rules update <rule-name> --target-tags=<tag-a>,<tag-b>
gcloud compute firewall-rules update <rule-name> --disabled       # turn the rule off (kept for re-enable)
gcloud compute firewall-rules update <rule-name> --no-disabled    # turn it back on

# Delete a rule (single or multiple names)
gcloud compute firewall-rules delete <rule-name> --quiet
gcloud compute firewall-rules delete <rule-1> <rule-2> <rule-3> --quiet

# Bulk-delete by prefix
for r in $(gcloud compute firewall-rules list --filter="name~^<prefix>-" --format='value(name)'); do
  gcloud compute firewall-rules delete "$r" --quiet
done
```

### Debug a blocked / leaking packet

```bash
# Recent DENIED packets in the VPC (requires firewall logging enabled on the rule)
gcloud logging read 'resource.type="gce_subnetwork" AND jsonPayload.disposition="DENIED"' \
  --limit=10 --format='value(timestamp, jsonPayload.connection)'

# Enable / disable logging on an existing rule
gcloud compute firewall-rules update <rule-name> --enable-logging
gcloud compute firewall-rules update <rule-name> --no-enable-logging

# From the source VM (run inside the VM), confirm it can actually reach the target port:
nc -vz <target-internal-ip-or-hostname> <port>
```

### Project-specific rules in this tutorial

For reference, the three rules we create:

```bash
# SSH only via Google's IAP range (no public 22)
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
```

### Inspect + lifecycle

```bash
# Inspect
gcloud compute instances list
gcloud compute instances describe <vm>

# Lifecycle — pass multiple <vm> names to act on several at once,
# e.g. `gcloud compute instances stop <name>-app <name>-db`
gcloud compute instances stop   <vm>   # pause (saves compute, not disk)
gcloud compute instances start  <vm>
gcloud compute instances reset  <vm>   # reboot (startup script runs ONCE per VM, not on reset)
gcloud compute instances delete <vm>   # delete (frees everything)

# Metadata (e.g. inject the DB password BEFORE first boot)
gcloud compute instances add-metadata <vm> \
  --metadata=db-password='<strong-password>'
```

### SSH (always via IAP — never expose port 22)

```bash
gcloud compute ssh <vm> --tunnel-through-iap
gcloud compute ssh <vm> --tunnel-through-iap --troubleshoot   # diagnose hangs

# One-shot remote command (runs on <vm>, output back on your laptop)
gcloud compute ssh <vm> --tunnel-through-iap -- \
  "sudo docker ps; sudo docker logs --tail=100 <name>-backend"
```

If you get an IAP IAM error:
```bash
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
  --member="user:<YOUR_EMAIL>" --role="roles/iap.tunnelResourceAccessor"
```

### Find IPs and other quick lookups

```bash
# External IP (only VMs created without --no-address have one)
gcloud compute instances describe <vm> \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'

# Internal IP (every VM has one, on the subnet CIDR)
gcloud compute instances describe <vm> \
  --format='get(networkInterfaces[0].networkIP)'

# Both IPs + status for every VM, as a clean table
gcloud compute instances list \
  --format='table(name, zone.basename(), status, networkInterfaces[0].networkIP:label=INTERNAL, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL)'

# Just the status (RUNNING / TERMINATED / STOPPING / …)
gcloud compute instances describe <vm> --format='get(status)'

# Tags (decide which firewall rules apply)
gcloud compute instances describe <vm> --format='get(tags.items)'

# Boot-disk size + type
gcloud compute instances describe <vm> \
  --format='get(disks[0].diskSizeGb, disks[0].type.basename())'

# All custom metadata keys
gcloud compute instances describe <vm> \
  --format='value(metadata.items.key)'

# Read one specific metadata value
gcloud compute instances describe <vm> \
  --format='value(metadata.items.filter("key:db-password").extract(value))'
```

### When the VM won't boot or SSH hangs

```bash
# Serial console output — shows the boot sequence BEFORE SSH is available
gcloud compute instances get-serial-port-output <vm>

# Tail the last 200 lines (most recent boot)
gcloud compute instances get-serial-port-output <vm> | tail -200

# Live serial console (Ctrl-] to exit)
gcloud compute connect-to-serial-port <vm>
```

The serial console is your friend when SSH itself is broken — startup script crashed, networking misconfigured, disk full, etc.

### Resize / rescale a VM

```bash
# Change machine type (VM must be STOPPED first)
gcloud compute instances stop <vm>
gcloud compute instances set-machine-type <vm> --machine-type=e2-medium
gcloud compute instances start <vm>

# Grow the boot disk (online — no stop needed; filesystem resizes on next boot)
gcloud compute disks resize <vm> --size=30GB
```

### Discoverability helpers

```bash
gcloud compute zones list                              # all zones
gcloud compute regions list                            # all regions
gcloud compute machine-types list --zones=<zone>       # what VM sizes are available
gcloud compute images list --filter="family~debian"    # find image families
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

Secret Manager is **general-purpose** — any value your app shouldn't see in code or env files belongs here: API keys (Stripe, OpenAI, SendGrid…), DB passwords, JWT signing keys, webhook signing keys, third-party OAuth client secrets, SSH private keys, TLS certs. Treat it as the project-wide vault.

```bash
# One-time: enable the API in this project
gcloud services enable secretmanager.googleapis.com

# List all secrets in the project (start here when you forget what exists)
gcloud secrets list

# Create
echo -n "<value>" | gcloud secrets create <secret-name> \
  --replication-policy=automatic --data-file=-

# Describe one (created/updated timestamps, replication, labels)
gcloud secrets describe <secret-name>

# List all versions of a secret (ENABLED / DISABLED / DESTROYED)
gcloud secrets versions list <secret-name>

# Read latest value
gcloud secrets versions access latest --secret=<secret-name>

# Read a specific version
gcloud secrets versions access 2 --secret=<secret-name>

# Rotate (creates version 2, 3, …)
echo -n "<new-value>" | gcloud secrets versions add <secret-name> --data-file=-

# Disable / re-enable a version (without deleting it)
gcloud secrets versions disable 1 --secret=<secret-name>
gcloud secrets versions enable  1 --secret=<secret-name>

# Permanently destroy a version (irreversible — value is gone)
gcloud secrets versions destroy 1 --secret=<secret-name>

# Grant a service account read access
gcloud secrets add-iam-policy-binding <secret-name> \
  --member="serviceAccount:<sa>@<project>.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Who currently has access?
gcloud secrets get-iam-policy <secret-name>

# Delete the whole secret (all versions, irreversible)
gcloud secrets delete <secret-name>
```

---

## 9. Workload Identity Federation (CI/CD without JSON keys)

**Windows / PowerShell:** use the ready-made script (handles SA propagation lag + retries):

```powershell
.\scripts\setup-wif.ps1 -Repo "<github-org>/<repo>"
```

**macOS / Linux / WSL:** the bash recipe below does the same thing. After SA creation, give it ~10s before the role bindings, or be ready to retry the first one — IAM propagation is eventual.

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
# ↓ run on VM (after: gcloud compute ssh <name>-app --tunnel-through-iap)
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
# local — what's actually running + last 100 log lines (single best command)
gcloud compute ssh <name>-app --tunnel-through-iap -- \
  "sudo docker ps; sudo docker logs --tail=100 <name>-backend; sudo docker logs --tail=100 <name>-frontend"

# on VM — did the startup script run?
sudo cat /var/log/startup-complete.log
sudo journalctl -u google-startup-scripts.service -e

# on VM (app VM) — test DB reachability over the internal network
sudo apt-get install -y netcat-openbsd postgresql-client
nc -vz <name>-db 5432
psql "postgresql://<db-user>:<password>@<name>-db:5432/<db-name>" -c "\l"

# on VM — internal DNS check
getent hosts <name>-db

# local — "port already allocated" on your laptop
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
# NAT must go BEFORE the router; router BEFORE the subnet/VPC.
gcloud compute routers nats delete <name>-nat --router=<name>-router --region=<region> --quiet
gcloud compute routers      delete <name>-router --region=<region> --quiet
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
