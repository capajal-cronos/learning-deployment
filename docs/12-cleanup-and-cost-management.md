# Chapter 12 — Cleanup and cost management

The most important chapter. Run it whenever you stop working — even for a day.

Cloud resources don't care that you're "just learning". A small VM is ~$13/month, a forgotten load balancer is ~$18/month, an unattached disk is ~$0.40/month. Cents-per-hour adds up fast.

---

## 1. The "what's costing me money?" question

Open **Billing → Reports** in the Cloud Console. Filter by your project. The chart by **service** answers "what bills me?" in one glance.

CLI alternative:

```bash
gcloud billing accounts list
gcloud billing projects describe $(gcloud config get-value project)
```

Real bills only appear after ~24 hours, so cleanup early is better than reading the bill late.

---

## 2. The hit list

For our deployment, the things that cost money are, roughly:

| Resource                | Cost (approx, EU/US small region)             |
| ----------------------- | --------------------------------------------- |
| 1 × `e2-small` VM       | ~$13/month                                    |
| 1 × `e2-small` VM       | ~$13/month                                    |
| 2 × 10 GB persistent disks | ~$0.80/month                                |
| 1 × static external IP (in use) | free; if reserved & unused: ~$2.50/month |
| Artifact Registry storage | ~$0.10/GB/month                             |
| Cloud Logging ingest    | first 50 GB/project free                      |
| Network egress          | first 1 GB/month free                         |

So the dominant cost is **VMs**. Delete them, you save 95%.

---

## 3. The "soft stop" option

If you want to pause work but come back tomorrow:

```bash
gcloud compute instances stop taskboard-app taskboard-db
```

This stops the VMs (no compute charges) but **keeps the disks** (small charge). Start again with:

```bash
gcloud compute instances start taskboard-app taskboard-db
```

External IPs are usually **ephemeral** for our setup — when you stop a VM, you may lose its external IP. That's fine for a tutorial; if you need a stable IP, you'd reserve one (and pay for it while idle).

---

## 4. The full cleanup script

Save as `scripts/cleanup.sh`. **Read it before running**. You should see your VPC name etc. — change `PROJECT_ID` if needed.

```bash
#!/usr/bin/env bash
set -uo pipefail
PROJECT_ID=$(gcloud config get-value project)
REGION=$(gcloud config get-value compute/region)
ZONE=$(gcloud config get-value compute/zone)
VPC=taskboard-vpc

read -rp "Delete all TaskBoard resources in project '$PROJECT_ID'? [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }

# Order matters: VMs first, then firewall rules, then subnet, then VPC.
gcloud compute instances delete taskboard-app taskboard-db --zone="$ZONE" --quiet || true

for rule in allow-ssh-from-iap allow-http-public allow-internal-db; do
  gcloud compute firewall-rules delete "$rule" --quiet || true
done

gcloud compute networks subnets delete app-subnet --region="$REGION" --quiet || true
gcloud compute networks delete "$VPC" --quiet || true

# Artifact Registry images (storage cost).
gcloud artifacts repositories delete taskboard --location="$REGION" --quiet || true

# Secrets — kept by default; uncomment if you want them gone.
# gcloud secrets delete jwt-secret --quiet || true
# gcloud secrets delete db-password --quiet || true

echo "Cleanup complete."
```

> ⚠️ This deletes the VPC and Artifact Registry too. If you want to keep them for the next session, comment those lines out and just delete the VMs.

---

## 5. The deeper cleanup

Even after the script above, a few things linger:

- **Orphan disks** — if a VM was deleted with `--keep-disks`, its disk lingers. Check:
  ```bash
  gcloud compute disks list
  gcloud compute disks delete <name> --zone=<zone>
  ```
- **Unused external IPs**:
  ```bash
  gcloud compute addresses list --filter="status:RESERVED AND -users:*"
  gcloud compute addresses delete <name>
  ```
- **Old container images** in Artifact Registry — they cost storage:
  ```bash
  gcloud artifacts docker images list <region>-docker.pkg.dev/<project>/taskboard
  gcloud artifacts docker images delete <full-tag> --delete-tags --quiet
  ```

A quick way to spot everything in a project: **Cloud Console → Asset Inventory** (one URL away).

---

## 6. Closing the project entirely

If you want a perfectly clean slate:

1. Delete the project itself.
2. GCP will keep it for 30 days, then it's gone forever.

```bash
gcloud projects delete $(gcloud config get-value project)
```

After you confirm, the project goes into "scheduled for deletion" status. Billing stops immediately. If you change your mind within 30 days you can restore.

---

## 7. Cost habits that pay off

| Habit                                                  | Why                                                   |
| ------------------------------------------------------ | ----------------------------------------------------- |
| Set a billing budget alert at $5                       | One email beats a $200 surprise.                      |
| Use one project per learning experiment               | Easy to delete an entire project.                     |
| Tag every resource you create with `purpose=learning` | Easier to grep when listing for cleanup.              |
| Run the cleanup script at the end of each session     | Don't trust "I'll do it tomorrow".                    |
| Use the free tier where possible                       | `e2-micro` in `us-central1` is always free.           |
| Don't leave load balancers running                     | They cost more than the VMs they front.               |

---

## 8. Checkpoint ✅

1. What's the difference between **stopping** a VM and **deleting** it, cost-wise?
2. What does a `RESERVED` but unused external IP cost?
3. Which single command is the most cost-effective in this chapter?

> Answers
> 1. Stopping ends compute charges but keeps disk charges. Deleting ends both.
> 2. About $2.50/month — small, but easy to forget.
> 3. `gcloud projects delete <project>`. Atomic. Nothing left.

---

## 9. Confession time

You are now allowed to keep the deployment running while you finish chapter 13. Just promise that when you're done, you'll come back to **section 4** of this chapter.

> 🧠 **Habit**: bookmark this chapter as the **first** chapter in the docs folder, not the last. Future-you will thank you.

---

➡️ Next: [Chapter 13 — Next steps](./13-next-steps.md)
