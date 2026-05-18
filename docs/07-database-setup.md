# Chapter 07 — Database setup

We installed Postgres on the DB VM in chapter 06 via the startup script. This chapter explains **what** the script did, **why** the DB lives on a separate VM, and how the app reaches it.

We also talk about the trade-offs of self-managed Postgres vs **Cloud SQL** so you understand both choices.

---

## 1. What we did, in plain words

Recap of `scripts/startup-db.sh`:

1. Installed `postgresql-16` from Debian's repos.
2. Edited `postgresql.conf` so Postgres listens on **all interfaces** of the VM (not just localhost).
3. Edited `pg_hba.conf` so password-authenticated connections from `10.10.0.0/24` are allowed.
4. Created a role `taskboard` and a database `taskboard`.

Where does the password come from?

The script reads it from **instance metadata**:

```bash
http://metadata.google.internal/computeMetadata/v1/instance/attributes/db-password
```

That URL is only reachable from inside the VM and is how we inject secrets at boot. We'll set the metadata value via the CI/CD pipeline (or a one-time gcloud command for manual setup).

```bash
gcloud compute instances add-metadata taskboard-db \
  --metadata=db-password='a-real-strong-password'
```

> ⚠️ **Pitfall**
> Setting the metadata *after* the VM has already booted does **not** re-run the startup script. Either reboot the VM (`gcloud compute instances reset taskboard-db`) or set the metadata **before** creating the VM.

---

## 2. Why Postgres listens on all interfaces

It sounds scary — "listen on all interfaces" — but it's correct here. The VM has:

- `lo` (127.0.0.1) — loopback.
- The VPC interface (`10.10.0.6`) — internal IP.

Listening on "all" means listening on the VPC interface as well. **What restricts access is the firewall rule, not the listener.** The DB VM has no external IP, so "all interfaces" is still just "the private one".

If we *did* have an external IP, this configuration would be a serious mistake without a firewall in front.

---

## 3. Why a separate VM at all?

A small project doesn't need it. We split for the reasons in chapter 06: it makes the VPC, firewall, and identity stories *real*. The downsides:

- More infrastructure to manage.
- More moving parts to monitor.
- Higher cost (two VMs vs one).

The honest "this is a small project" answer is: use a **managed database** like Cloud SQL. Which leads to…

---

## 4. Compute Engine Postgres vs Cloud SQL — when to pick which

| Concern                 | Self-managed on VM             | Cloud SQL                                 |
| ----------------------- | ------------------------------ | ----------------------------------------- |
| Cost                    | Lower                          | Higher (you pay for the management)       |
| Patching                | You                            | Google                                    |
| Backups                 | You set them up                | Built-in, point-in-time recovery          |
| HA / failover           | You build it                   | Single click for multi-zone HA            |
| Configuration freedom   | Total                          | Limited to supported settings             |
| Learning value          | Huge                           | Black box                                 |
| Recommended for prod?   | Only if you really know Postgres | Yes for most teams                       |

For *this tutorial*, self-managed wins because it teaches networking. For a *real* product, Cloud SQL is usually the right call. Chapter 13 has a "production upgrades" section that revisits this.

---

## 5. Verifying connectivity from the app VM

After chapter 06 you should have two VMs. SSH into the **app** VM:

```bash
gcloud compute ssh taskboard-app --tunnel-through-iap
```

Then test the DB connection:

```bash
# Install the postgres client just for this test (we don't need it for the app
# itself, the container has its own driver).
sudo apt-get update -y && sudo apt-get install -y postgresql-client

# Connect via internal hostname (GCP DNS resolves this to 10.10.0.6).
psql "postgresql://taskboard:THE_PASSWORD@taskboard-db:5432/taskboard" -c "\l"
```

If the connection succeeds, you've just proved:

- The DNS name `taskboard-db` resolves inside the VPC.
- The firewall rule for port 5432 from the subnet works (we add it in chapter 08).
- Postgres is configured to accept the credentials.
- Routing between the two VMs is OK.

Four important things validated in one ping.

---

## 6. The connection string the app uses

Recap from chapter 01:

```
postgresql+psycopg://taskboard:THE_PASSWORD@taskboard-db:5432/taskboard
```

When running in Docker Compose locally, the hostname was `db`. In production it's `taskboard-db`. The application code doesn't change — only the **environment variable** does. This is the same pattern as `BACKEND_URL` for the frontend: the code stays portable, the env config is where the truth lives.

---

## 7. Backups (a teaser)

Even on a tutorial DB, please do this once so you know how:

```bash
# On the DB VM:
sudo -u postgres pg_dump taskboard | gzip > /tmp/taskboard-$(date +%F).sql.gz
```

In a real deployment you'd:

- Run `pg_dump` on a schedule.
- Push the dump to a **Cloud Storage** bucket with object versioning.
- Test the restore at least once a quarter.

The biggest backup mistake is "we have backups but we've never restored from them". Restore drills > backup configuration.

---

## 8. Resetting the schema during development

While iterating, you can blow away the tables and let FastAPI re-create them on startup:

```sql
-- as postgres superuser:
DROP DATABASE taskboard;
CREATE DATABASE taskboard OWNER taskboard;
```

The FastAPI app calls `Base.metadata.create_all` at startup, which is fine for *learning*. In production you would use **Alembic** migrations so schema changes are versioned, reviewable, and reversible. Chapter 13 expands on this.

---

## 9. Common beginner mistakes

| Symptom                                                | Likely cause                                                                  |
| ------------------------------------------------------ | ----------------------------------------------------------------------------- |
| `psql: error: connection to server at "taskboard-db", port 5432 failed: timeout` | Missing firewall rule for port 5432. See chapter 08.        |
| `FATAL: no pg_hba.conf entry for host …`               | Source IP isn't in `10.10.0.0/24`. Are you on the right VM/subnet?            |
| `FATAL: password authentication failed`                | Metadata `db-password` was set after first boot. Reset the VM or recreate.    |
| Backend can't connect on container startup             | The DB VM is rebooting or still running its startup script. Wait a minute.    |

---

## 10. Checkpoint ✅

1. Why does the DB listening on "all interfaces" not mean "exposed to the internet"?
2. Why use a managed database (Cloud SQL) in production over self-managed?
3. What's the role of the **metadata server** at `metadata.google.internal` in our setup?

> Answers
> 1. The VM has no external IP. "All interfaces" = `lo` + private VPC interface; the firewall controls access to the private one.
> 2. Patching, backups, HA, and PITR are handled for you. You'd otherwise spend more time being a DBA than building features.
> 3. It's a per-VM source of attributes and short-lived credentials. We use it to inject the DB password securely without baking it into the image or script.

---

## 11. Optional exercise 🧪

On the DB VM, run:

```bash
sudo ss -lnpt | grep 5432
```

Look at the address Postgres is bound to (`*:5432` or `0.0.0.0:5432`). Then look at the VM's actual interfaces:

```bash
ip -brief addr
```

You'll see exactly **why** binding "to all" still makes the service reachable on the VPC interface — and *only* on the VPC interface, because that's the only non-loopback address the VM has.

---

➡️ Next: [Chapter 08 — Firewalls and security](./08-firewalls-and-security.md)
