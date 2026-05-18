# Chapter 06 — Compute Engine deployment

In this chapter we **rent two VMs** from Google: one for the app, one for the database. We put both inside the VPC from chapter 05 and run the containers we built in chapter 03. By the end you'll have a working URL that returns the React app.

We use plain VMs instead of Kubernetes on purpose: you'll *see* every moving part, instead of letting an orchestrator hide them.

> If you're curious about GKE, we explain when to pick it over Compute Engine in chapter 13. Spoiler: not for one-day learning projects.

---

## 1. What is Compute Engine?

A VM (virtual machine) is a slice of a physical server, isolated by a hypervisor. You SSH in like any Linux box. You pay by the hour.

Key terms:

| Term         | Meaning                                                                  |
| ------------ | ------------------------------------------------------------------------ |
| **Machine type** | The CPU/RAM size. `e2-small` = 2 vCPU shared, 2 GB RAM. Cheap.       |
| **Image**    | The disk image to boot from. We use `debian-12`.                          |
| **Disk**     | Persistent storage attached to the VM. Default 10 GB.                     |
| **Metadata** | Key/value pairs attached to a VM (or to the project). Used for startup scripts. |
| **Startup script** | A shell script GCP runs the first time the VM boots. Magical.      |

---

## 2. Plan first

We are going to create:

1. A **service account** for the VMs (so they have their own identity, not yours).
2. A **firewall rule** allowing SSH via Google's Identity-Aware Proxy (no public port 22).
3. A **firewall rule** allowing HTTP/HTTPS from the internet to a tagged VM.
4. A **firewall rule** allowing port 5432 inside the VPC to a tagged VM.
5. A **DB VM** (tag: `db`, internal IP only).
6. An **app VM** (tag: `app`, external IP, runs both containers).

We'll do (1)–(3) in chapter 08. This chapter focuses on the VMs themselves and the startup scripts that install Docker on them. We'll come back to lock the firewall down properly.

For now, we'll *temporarily* allow SSH from your IP and HTTP from the world.

---

## 3. The application VM's startup script

A **startup script** is a shell script that runs the first time a VM boots. We use it to install Docker. Save this file locally; we'll pass it to the `gcloud` command:

`scripts/startup-app.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Update & install docker.io (the Debian-packaged Docker engine).
apt-get update -y
apt-get install -y docker.io ca-certificates

# Enable Docker on boot.
systemctl enable --now docker

# Create a marker so we can confirm the script ran.
date -Iseconds > /var/log/startup-complete.log
```

A few notes:

- `set -euo pipefail` — fail loud and early on any error.
- Startup scripts run as **root**. No `sudo` needed.
- This script is intentionally **idempotent and tiny**. In chapter 09 we'll add the step that pulls our app image and starts the container.

The DB VM's script is similar but also installs and configures Postgres (we'll see it in chapter 07).

---

## 4. Create the VMs

> Before running these commands, make sure you completed chapter 05 (VPC + subnet exist) and chapter 04 (region/zone defaults set).

### 4a. DB VM (internal only)

```bash
gcloud compute instances create taskboard-db \
  --machine-type=e2-small \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --subnet=app-subnet \
  --no-address                     `# ← no external IP` \
  --tags=db \
  --metadata-from-file=startup-script=scripts/startup-db.sh
```

What each flag means:

- `--no-address` — **no external IP**. The DB is unreachable from the internet.
- `--subnet=app-subnet` — placed inside our VPC.
- `--tags=db` — used by firewall rules later.
- `--metadata-from-file=startup-script=…` — runs on first boot.

### 4b. App VM (public)

```bash
gcloud compute instances create taskboard-app \
  --machine-type=e2-small \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --subnet=app-subnet \
  --tags=app \
  --metadata-from-file=startup-script=scripts/startup-app.sh
```

Notice we **don't** pass `--no-address`, so GCP attaches an external IP automatically.

Check:

```bash
gcloud compute instances list
```

Expected output (abridged):

```
NAME           ZONE              MACHINE_TYPE  INTERNAL_IP   EXTERNAL_IP     STATUS
taskboard-app  europe-west4-a    e2-small      10.10.0.5     35.x.x.x        RUNNING
taskboard-db   europe-west4-a    e2-small      10.10.0.6     <none>          RUNNING
```

That `<none>` next to the DB is the security property we wanted.

---

## 5. SSH the safe way (no public port 22)

Don't open port 22 to the internet. Instead, use **Identity-Aware Proxy (IAP) tunneling**, which lets you SSH **through Google's authenticated proxy**.

First, add an IAP firewall rule (we will redo this more carefully in chapter 08, but a temporary version is fine):

```bash
gcloud compute firewall-rules create allow-ssh-from-iap \
  --network=taskboard-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20   `# Google's IAP CIDR` \
  --target-tags=app,db
```

Then SSH using the IAP tunnel:

```bash
gcloud compute ssh taskboard-app --tunnel-through-iap
gcloud compute ssh taskboard-db  --tunnel-through-iap
```

Behind the scenes: gcloud opens an authenticated tunnel through Google's edge, which then connects to port 22 on the VM via the **internal** network. No public port 22 is ever exposed.

> 💡 If `--tunnel-through-iap` fails with an IAM error, you may also need to grant your user `roles/iap.tunnelResourceAccessor`. Run:
> ```bash
> gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
>   --member="user:YOUR_EMAIL" \
>   --role="roles/iap.tunnelResourceAccessor"
> ```

---

## 6. Confirm the startup script ran

After SSH'ing into the app VM:

```bash
sudo cat /var/log/startup-complete.log    # the date we wrote
docker --version                          # docker installed
sudo systemctl is-active docker           # active
```

If `docker` is not installed yet, the script might still be running. Wait a minute and retry. You can also inspect:

```bash
sudo journalctl -u google-startup-scripts.service -e
```

---

## 7. Run the backend manually (just to feel it)

We're going to do this *for real* via CI/CD in chapter 09. For now, do it by hand to learn the moving parts. On the **app VM**:

```bash
# Pull a placeholder image just to test Docker works:
sudo docker run --rm -p 8000:8000 hashicorp/http-echo:1.0.0 -text="hello from the cloud"
```

Now from **your laptop**:

```bash
curl http://<APP_VM_EXTERNAL_IP>:8000
```

If you don't have a firewall rule allowing port 8000 from the internet yet, this will time out — expected. Don't open it; we'll only ever open 80/443 in production. This was just a manual sanity check; press `Ctrl+C` to stop the test container.

---

## 8. Why two VMs and not one?

For a *learning* project, one VM running everything is cheaper. We deliberately split because:

- It **forces you to use the VPC**. Suddenly "where does this packet go?" matters.
- It **mirrors real architectures**. Production rarely puts a DB on the same node as the app.
- It **practises the security model**. The DB has no external IP — that's only meaningful if it's a separate machine.

If cost is a problem, you can use `e2-micro` instead of `e2-small` for both VMs and stay within the free tier (slower, fine for learning).

---

## 9. Things that will surprise you

- The first boot of a VM can take 30–60 seconds before SSH responds. Be patient.
- `gcloud compute instances list` only shows VMs in your **default project**.
- Stopping a VM (`gcloud compute instances stop`) costs (almost) nothing for compute, but the **disk** keeps billing. Delete the VM to stop disk charges.
- If you SSH the first time and get "permission denied", give the VM another 20 seconds — IAM permissions sometimes lag the create call.

---

## 10. Checkpoint ✅

1. Why does the DB VM have **no** external IP?
2. What does a **startup script** do?
3. Why do we tag VMs with `app` and `db`?
4. What is IAP tunneling and what problem does it solve?

> Answers
> 1. Defense in depth — even if the firewall is misconfigured, the DB simply has no public address to attack.
> 2. Runs on first boot as root. We use it to install Docker (and later to pull/run the app image).
> 3. So firewall rules can target *kinds* of VMs instead of specific IPs.
> 4. It tunnels SSH (and other TCP) through Google's authenticated proxy, so you don't have to open port 22 to the internet.

---

## 11. Optional exercise 🧪

Read the contents of `/etc/hosts` and `/etc/resolv.conf` on the app VM. Then try to resolve the DB's hostname:

```bash
getent hosts taskboard-db
```

You'll see GCP's internal DNS resolves `taskboard-db` to its internal IP. That's how the app will eventually reach the DB without hardcoding an IP — same idea as the Docker Compose service names from chapter 02, but at the cloud level.

---

➡️ Next: [Chapter 07 — Database setup](./07-database-setup.md)
