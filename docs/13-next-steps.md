# Chapter 13 — Next steps

You did it. You took a fullstack app from a local Docker Compose to a real GCP deployment, behind a custom VPC, with a CI/CD pipeline that ships from `git push` to production.

This last chapter is for the question: **"what now?"**

---

## 1. Recap — what you learned

A quick reference, in order:

| Chapter | The "aha"                                                                |
| ------- | ------------------------------------------------------------------------ |
| 00      | Deployment is a stack: code → packaging → infra → service.               |
| 01      | One request crosses three components. Express exists for a reason.       |
| 02      | Docker Compose teaches networking on your laptop for free.               |
| 03      | Images, containers, layers, multi-stage builds, registries.              |
| 04      | GCP projects, APIs, regions/zones, billing.                              |
| 05      | VPC = your own private network. CIDR + routes + firewall = the topology. |
| 06      | A VM is just a Linux box you rent. Startup scripts make it useful.       |
| 07      | A managed DB is usually better; we rolled our own to learn the network.  |
| 08      | Defense in depth, IAM, Secret Manager, least privilege.                  |
| 09      | CI/CD is automation amplification. WIF beats JSON keys.                  |
| 10      | Observability = logs + metrics + traces. Uptime checks are essential.    |
| 11      | Troubleshooting is a method, not a memorized list.                       |
| 12      | Cleanup pays for itself.                                                 |

That's a lot. If anything is fuzzy, re-read that one chapter. Spaced repetition is real.

---

## 2. The most valuable next exercises

### A. Add HTTPS

Right now your app is HTTP. Two paths:

1. **Caddy on the VM** (easy). Add Caddy as a container that fronts the Express server and obtains a Let's Encrypt certificate automatically. Buy a cheap domain (~$10) and point it at the VM's external IP.
2. **Global HTTPS Load Balancer** (production-grade). Reserve a global static IP, create an HTTPS LB with a managed certificate, an unmanaged backend group containing your VM. You no longer need port 80/443 open to the world on the VM itself — only the LB does.

The second path teaches you a lot about real GCP networking.

### B. Switch to Cloud SQL

Replace the self-managed Postgres VM with a Cloud SQL Postgres instance. You'll learn:

- Private Service Connect / Private IP for Cloud SQL.
- IAM-based DB authentication.
- Automated backups and point-in-time recovery.

The app's `DATABASE_URL` is the only thing that has to change.

### C. Real migrations

Replace `Base.metadata.create_all` with **Alembic**. Generate the initial migration, commit it, and add `alembic upgrade head` as a deploy step. Schema changes now have a paper trail and are reversible.

### D. Blue/green deploys

Two VMs running the same image. The load balancer routes 100% to "blue". The pipeline deploys to "green", health-checks it, then flips the LB. If anything breaks, flip back — zero downtime, zero in-flight requests dropped.

### E. Infrastructure as Code

Replace the `gcloud` commands in this tutorial with **Terraform**:

```hcl
resource "google_compute_network" "vpc" {
  name                    = "taskboard-vpc"
  auto_create_subnetworks = false
}
```

Now your infra is git-tracked. PRs review network changes. `terraform plan` shows the diff before applying. This is the single biggest professional leap.

### F. Kubernetes (GKE) — when?

If you ever:

- Need to autoscale workers based on queue length,
- Want to run 10+ services with shared infrastructure,
- Need rolling deploys / canary as first-class concepts,

…then GKE earns its complexity. For one or two services, Compute Engine + good CI/CD is honestly simpler.

GKE Autopilot is the most beginner-friendly entry point if you go this route.

---

## 3. Production-grade upgrades, in priority order

A checklist for "what would I do if real users showed up tomorrow?":

1. **HTTPS in front** (HTTPS load balancer + managed cert).
2. **Cloud SQL** with PITR backups.
3. **Workload Identity for the VM** (so the VM's container reads secrets directly via the metadata server, no env vars).
4. **Structured JSON logging** end-to-end.
5. **Alerting policies** for `5xx > 1% for 5min`, `latency p95 > 2s`, `DB connection errors > 0`.
6. **Rate limiting** at the edge (Cloud Armor or in Express).
7. **Image scanning** enabled on Artifact Registry; fail the build on critical CVEs.
8. **Branch protection** on `main` with required CI checks and code review.
9. **Preview environments** per PR (spin up an ephemeral VM, tear it down on merge).
10. **Disaster recovery drill**: restore from backup once a quarter. **Practice the restore.**

---

## 4. Suggested next projects

If you want to keep practising the same muscles, in roughly increasing difficulty:

| Project                                              | What it adds                                                   |
| ---------------------------------------------------- | -------------------------------------------------------------- |
| **Newsletter sender** with Postgres + worker queue   | Async background jobs (Cloud Tasks or RabbitMQ), idempotency.  |
| **Image upload + thumbnail service**                 | Cloud Storage, signed URLs, multi-step pipelines.              |
| **Real-time chat**                                   | WebSockets, sticky sessions, fan-out at scale.                 |
| **Multi-region failover deployment**                 | Global load balancing, DNS, RTO/RPO thinking.                  |
| **Mini-SaaS with tenant isolation**                  | Multi-tenancy, per-tenant rate limits, billing integration.    |

Each one stretches a different muscle. Pick the one that sounds *fun*, not the one that sounds "résumé-worthy". Fun wins.

---

## 5. Career-shaped reading

A short, opinionated list:

- *The Twelve-Factor App* — short essay, deeply influential.
- *Designing Data-Intensive Applications* — chapter by chapter, for distributed systems.
- The Google **SRE Book** (free online) — "what would site reliability engineering teach me?"
- The GCP **Architecture Center** — patterns and reference architectures.

---

## 6. How to keep this project alive

If you intend to keep TaskBoard running:

- Set a real domain name and HTTPS.
- Add Alembic migrations *before* you make any schema change.
- Replace JWT-in-localStorage with HttpOnly cookies.
- Add a real backup schedule (daily `pg_dump` to a Cloud Storage bucket with versioning).
- Set a billing alert.
- Decide on a maintenance ritual — a weekly hour to review logs, costs, and pending CVEs.

If you intend to delete it: chapter 12, now.

---

## 7. A final word

The hardest part of being a cloud engineer is not the syntax. It's **knowing what each tool exists for**. Names like "VPC", "subnet", "service account" are uninteresting alone but powerful as a vocabulary for designing safer, more reliable systems.

You now have that vocabulary. Use it. Critique tutorials when their reasoning seems wrong. Ask "why" before "how" whenever you can.

Welcome to the trade. 🚀

---

⬅️ Back to: [Chapter 00](./00-introduction.md) · [README](../README.md)
