# Chapter 08 — Firewalls and security

By the end of this chapter your deployment has:

- A small, deliberate set of firewall rules.
- Secrets stored in **Secret Manager**, not in env files committed to git.
- A service account with **least privilege**.
- HTTPS in front of your app (or at least a path to add it).

Security in cloud is mostly about *limiting what each piece is allowed to do*. We add layers — none of them perfect alone, all of them useful together.

---

## 1. Mental model — "defense in depth"

```
                            ┌────────────────────────────┐
   internet            ←    │  Layer 1: firewall rules    │
                            │  (cheap, broad)             │
                            └────────────────────────────┘
                            ┌────────────────────────────┐
                            │  Layer 2: IAM permissions   │
                            │  (who can do what)          │
                            └────────────────────────────┘
                            ┌────────────────────────────┐
                            │  Layer 3: app authentication│
                            │  (JWT, sessions, RBAC)      │
                            └────────────────────────────┘
                            ┌────────────────────────────┐
                            │  Layer 4: secrets stored    │
                            │  in a real secret manager   │
                            └────────────────────────────┘
                            ┌────────────────────────────┐
                            │  Layer 5: data encryption   │
                            │  at rest and in transit     │
                            └────────────────────────────┘
```

If a single layer is bypassed, the next one (hopefully) still holds.

---

## 2. The full firewall rule set

We saw the *shape* of these in chapter 05. Now we create them.

### Rule 1 — SSH via IAP only

We created this temporarily in chapter 06. Re-state it here for completeness:

```bash
gcloud compute firewall-rules create allow-ssh-from-iap \
  --network=taskboard-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20 \
  --target-tags=app,db
```

`35.235.240.0/20` is Google's IAP range. Only authenticated IAP tunnels originate from it.

### Rule 2 — Public HTTP/HTTPS to the app

```bash
gcloud compute firewall-rules create allow-http-public \
  --network=taskboard-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=app
```

This is the *only* rule that allows traffic from the open internet. It is narrowly scoped to TCP 80 and 443, and only to VMs tagged `app`. The DB VM is **not** tagged `app`, so this rule has no effect on it.

### Rule 3 — Internal DB access

```bash
gcloud compute firewall-rules create allow-internal-db \
  --network=taskboard-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:5432 \
  --source-ranges=10.10.0.0/24 \
  --target-tags=db
```

This is the **most important** rule for the topology. It says: TCP 5432 is allowed only from inside the subnet, only on VMs tagged `db`. Anyone trying to reach 5432 from the internet hits the default-deny and goes nowhere.

Verify what you have:

```bash
gcloud compute firewall-rules list --filter="network=taskboard-vpc"
```

You should see exactly three custom rules, plus whatever default rules GCP has.

> ⚠️ **Pitfall**
> When in doubt, **trace the source IP** of a packet that fails. Most firewall mysteries are "this packet doesn't actually come from where I think it does".

---

## 3. The principle of least privilege (IAM)

IAM stands for **Identity and Access Management**. Three concepts:

1. **Principal** — who is acting. (You, a service account, a group.)
2. **Role** — a bundle of permissions. (`roles/storage.objectViewer`.)
3. **Resource** — what the action is on. (A project, a bucket, a VM.)

A grant says: *"principal P has role R on resource X."*

Beginners reach for `roles/owner` because it Just Works. Don't. Owner is the cloud equivalent of "give it full sudo because the install script complained".

### What we'll grant for the CI/CD pipeline (chapter 09)

A service account named `github-deployer@<project>.iam.gserviceaccount.com` with:

| Role                                  | Why                                                       |
| ------------------------------------- | --------------------------------------------------------- |
| `roles/artifactregistry.writer`       | Push images to Artifact Registry.                         |
| `roles/compute.instanceAdmin.v1`      | Update VM metadata (so we can roll a new image version).  |
| `roles/iap.tunnelResourceAccessor`    | SSH into VMs through IAP (for the deploy step).           |
| `roles/iam.serviceAccountUser`        | Impersonate the VM's service account during deploys.      |
| `roles/secretmanager.secretAccessor`  | Read secrets at deploy time.                              |

That's already more than minimum, but each role has a clear story. Avoid `roles/editor` and `roles/owner` for automation.

---

## 4. Storing the JWT secret and DB password

So far we've been hand-waving the secrets. Let's do it right.

Create the secrets:

```bash
echo -n "a-really-long-random-string-32-chars-min" | \
  gcloud secrets create jwt-secret --replication-policy=automatic --data-file=-

echo -n "a-strong-postgres-password" | \
  gcloud secrets create db-password --replication-policy=automatic --data-file=-
```

Read them back (as your user, just to confirm):

```bash
gcloud secrets versions access latest --secret=jwt-secret
gcloud secrets versions access latest --secret=db-password
```

> 💡 **What just happened?**
> Secret Manager stores each value as an immutable **version**. New values become version 2, 3, … . Apps usually read `latest` but can pin to a specific version for safety during rollouts.

Then, when the pipeline runs, it will:

- Read both secrets via the deployer service account.
- Pass them to the VMs as environment variables when starting the container.
- They are never written to disk inside the image.

---

## 5. HTTPS (the honest version)

Real production HTTPS on Compute Engine usually uses a **Global HTTPS Load Balancer**:

```
internet → [HTTPS LB w/ managed cert] → instance group → app VM(s)
```

The load balancer terminates TLS, attaches a managed (free) certificate, and forwards to your VM over the VPC. This is one of the few things in GCP that is *both* a network resource and an HTTPS terminator.

For this tutorial we keep it simpler:

- The app VM exposes ports 80/443.
- You can install Caddy on the VM to handle HTTPS with auto-Let's-Encrypt.
- Or you keep HTTP only at first and add TLS later as an exercise.

We won't go through the full LB setup here — chapter 13 has it as an advanced upgrade.

> ⚠️ **Pitfall**
> Never put plain HTTP in front of a real product. We use HTTP-only here only because this is a learning lab on a temporary VM. **Do not** reuse this stack for anything with real users without TLS.

---

## 6. Hardening checklist for this stack

A pragmatic, prioritized list:

| Priority | Item                                                                 | Status in this tutorial                |
| -------- | -------------------------------------------------------------------- | -------------------------------------- |
| P0       | DB has no public IP                                                  | ✅                                     |
| P0       | SSH not exposed to the internet                                      | ✅ (IAP only)                          |
| P0       | Secrets in Secret Manager, not in git                                | ✅                                     |
| P0       | Service account uses least-privilege roles                          | ✅                                     |
| P1       | HTTPS in front of the app                                           | 🟡 (manual exercise / chapter 13)      |
| P1       | Container runs as non-root                                          | ✅                                     |
| P1       | Image scanning on push (Artifact Registry vulnerability scanning)   | 🟡 enable per project                  |
| P2       | DB backups to a versioned bucket                                    | 🟡 (chapter 13)                        |
| P2       | Audit logs reviewed                                                 | 🟡                                     |
| P3       | WAF / DDoS protection (Cloud Armor)                                 | 🟡                                     |

P0 items are non-negotiable. P1 you should add for anything past "demo". P2/P3 are for real production.

---

## 7. Application-level security recap

We didn't ignore this either:

- Passwords are bcrypt-hashed (chapter 01 § 6).
- JWTs are signed with a key from Secret Manager.
- Authorization is enforced per-route via the `get_current_user` dependency.
- Pydantic validates every request body shape.
- SQLAlchemy parameterizes every query — SQL injection isn't possible by accident.
- CORS is restricted to known origins.

The one weakness we have for "real production" is JWT in `localStorage`. Two ways to fix:

1. Use **HttpOnly cookies** — safer against XSS, requires CSRF protection.
2. Use a managed identity provider (Google Sign-In, Auth0, etc.).

---

## 8. Common beginner mistakes

| Mistake                                                   | Why it's bad                                              |
| --------------------------------------------------------- | --------------------------------------------------------- |
| Opening port 22 to the world                              | Brute-forced by botnets within minutes.                   |
| Putting the DB on the internet "to make it easier"        | Anybody can probe Postgres; CVEs land regularly.          |
| Using `roles/owner` for a CI/CD service account           | One leaked token = total project compromise.              |
| Storing `JWT_SECRET` in `.env` and committing it          | The git history is forever.                               |
| Issuing JWTs that never expire                            | A leaked token is a permanent backdoor.                   |
| Trusting client-side input for "is admin?"                | Trivially bypassed in DevTools.                           |

---

## 9. Checkpoint ✅

1. Why is the rule `allow-internal-db` source-restricted to `10.10.0.0/24`?
2. What is the difference between IAM and a firewall rule?
3. Why is `roles/owner` a poor choice for CI/CD?
4. Where should a JWT secret live?

> Answers
> 1. So **only machines inside the VPC** can reach Postgres. The internet's source IPs aren't in that range.
> 2. Firewall rules control *network* access (what packets are allowed where). IAM controls *who can do what* with the cloud APIs.
> 3. Way too broad. If the CI token is stolen the attacker can do anything you can, including deleting the project.
> 4. In a secret manager. Read at runtime by the app. Never in git.

---

## 10. Optional exercise 🧪

Temporarily try to make the wrong thing happen so you can see what "blocked" looks like:

```bash
# From your laptop (NOT a VM):
nc -vz <DB_VM_EXTERNAL_IP> 5432    # connection should fail — there's no external IP
nc -vz <APP_VM_EXTERNAL_IP> 5432   # connection should also fail — wrong tag/firewall
```

Then read the logs:

```bash
gcloud logging read 'resource.type="gce_subnetwork" AND jsonPayload.disposition="DENIED"' \
  --limit 5 --format='value(timestamp,jsonPayload.connection)'
```

Seeing your own blocked attempts is incredibly satisfying.

---

➡️ Next: [Chapter 09 — CI/CD with GitHub Actions](./09-ci-cd-with-github-actions.md)
