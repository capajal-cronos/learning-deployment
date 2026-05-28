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

### Wait — why install Docker *here* and not in the Dockerfile?

This trips up almost everyone the first time. The startup script and the Dockerfile install things into **two different machines, at two different times**:

- **Dockerfile** = what goes *inside the shipping container* (your app + its libraries — Python, FastAPI, your code). Built once on your laptop/CI, versioned, shipped through a registry, and identical everywhere it runs.
- **Startup script** = what goes *on the host VM* so it can run containers at all (the Docker engine itself), or run a host-level service like Postgres.

Picture the VM as a **ship** and Docker images as **shipping containers** loaded onto it:

```
   ┌─────────────────────────────────────────────┐
   │  VM (the ship)        ← startup-app.sh sets  │
   │  • Debian Linux          this up             │
   │  • Docker engine                             │
   │   ┌────────────────────────┐                 │
   │   │ container (the box)     │ ← Dockerfile    │
   │   │ • Python + FastAPI      │   sets this up  │
   │   │ • your app code         │                 │
   │   └────────────────────────┘                 │
   └─────────────────────────────────────────────┘
```

| | Dockerfile | Startup script |
| --- | ---------- | -------------- |
| Installs onto | the **container image** | the **VM (host OS)** |
| Runs when | at **build time** (laptop/CI) | at **first boot** of the VM, as root |
| Lifecycle | immutable, tagged by git SHA, in Artifact Registry | tied to that one VM; re-running needs a reset/recreate |
| Example here | `pip install` deps, copy app code | `apt-get install docker.io` (app VM), Postgres (db VM) |

**Rule of thumb:** if it's *part of your application* → Dockerfile. If it's *what the machine needs to host or run* that application → startup script. That's exactly why CI/CD in chapter 09 can redeploy your app a hundred times without ever re-touching the VM's setup: the app rides in the image; the VM setup stays put.

> 🛢️ The DB VM is the one exception to "apps go in containers" — there we install Postgres *directly on the host* via the startup script, because in this tutorial the database is a long-lived, stateful host service rather than a shipped image. Chapter 07 explains that choice.

---

## 4. Create the VMs

> Before running these commands, make sure you completed chapter 05 (VPC + subnet exist).

### 4a. Set your default region and zone first

If you skip this, `gcloud compute instances create` will stop and make you pick a zone from a list of 130+ — and the zone **must** be inside the same region as your subnet (`europe-west1` from chapter 05), or the `--subnet=app-subnet` flag will fail.

> 📍 In that interactive list, the `europe-west1` zones are **`[52]` `europe-west1-b`**, **`[53]` `europe-west1-c`**, **`[54]` `europe-west1-d`**. (The numbers can shift as Google adds zones, and the list truncates after 50 — type `list` at the prompt to see them all. Note the prompt wants the *number*, not the zone name.)

Set both defaults once so every `compute` command stops prompting:

```bash
gcloud config set compute/region europe-west1
gcloud config set compute/zone europe-west1-b
```

> ⚠️ Setting only the **region** is not enough — VM creation needs a **zone** (the letter-suffixed `-b`/`-c`/`-d` part). Set both.

Confirm they stuck:

```bash
gcloud config get-value compute/region
gcloud config get-value compute/zone
```

If you'd rather not set defaults, add `--zone=europe-west1-b` to each `create` command instead.

### 4b. DB VM (internal only)

> ⚠️ **Prerequisite: Cloud NAT must exist first.** The DB VM is created with `--no-address`, so its startup script can only reach `apt.postgresql.org` and `deb.debian.org` if outbound NAT is in place. If you skip this, the script will time out, no `postgres` user gets created, and chapter 07's `pg_dump` step will fail with `sudo: unknown user postgres`. See chapter 05, section 8 ("Cloud NAT").

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

### 4c. App VM (public)

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

### What is this shell you just landed in?

Once SSH connects, your prompt changes to something like `yourname@taskboard-app:~$`. **You are now typing commands inside the VM**, not on your laptop — it's a regular Debian Linux machine running in Google's data center, and this is its terminal. Anything you run here happens on the cloud VM. Type `exit` (or press `Ctrl+D`) to return to your laptop's PowerShell.

**On the app VM** (`taskboard-app`) the shell is where you:

- Verify the box is healthy — is Docker installed? did the startup script finish? (that's exactly step 6 below)
- Pull and run your application container, view its logs (`docker ps`, `docker logs`), and restart it
- Debug "why isn't the site loading?" — check the container, ports, and processes from the inside

Think of it as the maintenance hatch for the machine that serves your users.

**On the DB VM** (`taskboard-db`) the shell is your *only* way in — remember it has **no external IP**, so IAP tunneling is the sole door. There you:

- Confirm Postgres is installed and running (`sudo systemctl status postgresql`)
- Open the database console with `sudo -u postgres psql` to inspect tables, run queries, or create the app's database/user
- Check logs if the app can't connect

Because the DB is internal-only, you can't reach it from your laptop directly — you SSH into *it* (or tunnel a port) whenever you need to poke at the data. That isolation is the whole security point from chapter 05.

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

> 🪧 **This is just a `console.log("hello")`, not your app.** `hashicorp/http-echo` is a throwaway image that does nothing but echo back the `-text` string on a port. We use it purely to prove the infrastructure works (Docker runs, a container can serve a port). Your *real* backend isn't deployed until chapter 09 — don't read anything more into this image.

**Find the app VM's external IP.** You saw it in the `EXTERNAL_IP` column of `gcloud compute instances list`, but you can also grab just that value directly:

```bash
gcloud compute instances describe taskboard-app --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
```

**What `--format` is doing:** `gcloud describe` normally dumps the VM's *entire* config (dozens of fields). The `--format` flag reshapes that output, and `get(...)` is a projection that prints **just one field's value** — no key, no table, no quotes — which is perfect for copy-paste or piping into another command. The dotted path navigates the VM's structure: `networkInterfaces[0]` = the first network card, `accessConfigs[0]` = its first external-IP config, `natIP` = the public IP itself. (The internal IP lives at `networkInterfaces[0].networkIP` if you ever need that instead.)

> 🖥️ **Prefer a UI?** Open the [Cloud Console](https://console.cloud.google.com) → **Navigation menu (☰) → Compute Engine → VM instances**. You'll see both VMs, their internal/external IPs, and a status dot. Clicking a VM shows its full config and an in-browser SSH button.

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
- Stopping a VM halts the compute charge but the **disk** keeps billing. You must name the instance(s) — a bare `gcloud compute instances stop` errors with *"argument INSTANCE_NAMES: Must be specified"*. Stop both like this (zone comes from your default):

  ```bash
  gcloud compute instances stop taskboard-app taskboard-db
  ```

  Start them again later with `gcloud compute instances start taskboard-app taskboard-db`. To stop disk charges entirely, `delete` the VMs instead — but that also wipes their disks.
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
