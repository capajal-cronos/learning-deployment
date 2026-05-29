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

### Anatomy of a `firewall-rules create` command

A GCP firewall rule is a single sentence: *"on this network, allow/deny traffic going this direction, on these protocols/ports, from these sources, to these targets."* The flags are just the words of that sentence — the rule below literally reads as *"in `taskboard-vpc`, allow incoming TCP/22 from `35.235.240.0/20` to any VM tagged `app` or `db`."*

Field by field:

| Flag | What it is | Concrete example | Notes |
|---|---|---|---|
| `allow-ssh-from-iap` | The **name** you give this rule. Yes — you invent it. | `allow-ssh-from-iap` | Must be unique **per project**, not per VPC. That's why you sometimes hit "already exists" even when you think you're in a clean state. |
| `--network` | Which VPC the rule belongs to | `taskboard-vpc` | Required for custom-mode VPCs. A rule in `vpc-A` has no effect on traffic in `vpc-B`. |
| `--direction` | INGRESS = traffic coming **in** to a VM. EGRESS = traffic going **out**. | `INGRESS` | Almost every rule you'll write is INGRESS. GCP defaults egress to "allow all" and ingress to "deny all". |
| `--action` | ALLOW or DENY. | `ALLOW` | Most rules are ALLOW (we're poking holes in the default-deny). DENY rules exist but are rarely needed. |
| `--rules` | The protocol(s) and port(s) covered. Format: `protocol:port` or just `protocol`. Multiple separated by commas. | `tcp:22`, `tcp:80,tcp:443`, `tcp:5432`, `icmp` | `tcp:22` = SSH. `tcp:5432` = Postgres. `icmp` = ping. You can also write `tcp` alone to mean "all TCP ports". |
| `--source-ranges` | Where the traffic must come **from** (a list of CIDR blocks). | `35.235.240.0/20`, `0.0.0.0/0`, `10.10.0.0/24` | `0.0.0.0/0` = the whole public internet. A private CIDR like `10.10.0.0/24` = only your subnet. `35.235.240.0/20` = Google's IAP tunnel range. |
| `--target-tags` | Which VMs the rule applies **to**, identified by **network tags** (NOT names). | `app`, `db`, `app,db` | When you created the VMs you used `--tags=app` and `--tags=db`. That's the link. A VM without the matching tag is invisible to this rule. |

The bottom three flags (`--rules`, `--source-ranges`, `--target-tags`) are where each rule's intent really lives — the others are boilerplate. We comment those three on every rule below to explain *why* those specific values.

Two convenient features that make this scale:

1. **Tags are how a rule finds its VMs.** No IP lists to maintain. Add `--tags=db` to a new VM and every `db`-targeted rule automatically applies to it. Remove the tag and the rules stop applying.
2. **The default is deny.** A new custom-mode VPC starts with **zero** ingress allowed. Every "open" port is a deliberate rule you wrote. There is no "and don't forget to block the rest" — that's automatic.

### "Already exists" — what to do

Firewall rules are global per-project. If you (or a teammate) ran `firewall-rules create` for the same name before, you'll get:

```
ERROR: ... The resource 'projects/<project>/global/firewalls/<rule>' already exists
```

Three options:

```bash
# 1. Inspect the existing rule — usually it's already correct and you can just move on.
gcloud compute firewall-rules describe <rule-name>

# 2. Edit in place (works for ports, sources, tags — but NOT --network).
gcloud compute firewall-rules update <rule-name> --source-ranges=10.10.0.0/24

# 3. Nuke and re-create (the only path if --network is wrong).
gcloud compute firewall-rules delete <rule-name> --quiet
# then re-run the original create command
```

---

### Rule 1 — SSH via IAP only

**What it grants:** SSH access (TCP/22) into both the app VM and the DB VM.
**Why we need it:** We have to log into these machines to install packages, inspect logs, debug startup scripts, and run one-off commands. Without an SSH rule, the default-deny blocks every `gcloud compute ssh` attempt.
**Why narrowly:** Port 22 exposed to the open internet is one of the most-attacked surfaces in cloud — botnets brute-force it within minutes of a VM coming online. So we don't open 22 to `0.0.0.0/0`. Instead, we restrict the source to **Google's IAP (Identity-Aware Proxy) range**: the only way to reach 22 is through an authenticated `gcloud compute ssh --tunnel-through-iap`, where Google has already verified your identity *before* the TCP connection even starts.

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

**What it grants:** HTTP (TCP/80) and HTTPS (TCP/443) into the **app VM only**.
**Why we need it:** This is the user-facing surface. Anyone on the internet who types your domain (or external IP) into a browser needs to reach the app VM, and browsers only speak 80 and 443 by default.
**Why narrowly:** Even though the source is the whole internet (`0.0.0.0/0`), the rule's reach is limited *by target*. It only applies to VMs tagged `app`. The DB VM has no `app` tag, so the public internet still has zero paths to it — exactly what we want. We also list only ports 80 and 443: nothing else (no random debugging ports, no Postgres, no Redis) is exposed.

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

**What it grants:** Postgres traffic (TCP/5432) into the **DB VM only**, and **only from inside the VPC**.
**Why we need it:** The backend container running on the app VM needs to open connections to Postgres. Without this rule, even legitimate backend-to-DB traffic would hit the default-deny — your API would just hang.
**Why narrowly:** The DB is the most valuable thing in the stack, so it gets the tightest rule of all three. Source is restricted to `10.10.0.0/24` (our subnet's CIDR), which means a packet from the public internet can never match — public IPs aren't in that range. So even if someone discovered the DB's internal IP, they'd have no path to reach it. This is the rule that turns "no external IP" from a hopeful claim into an enforced reality.

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

> 🖥️ **See them in the UI:** Console → **VPC network → Firewall**. Each rule shows its direction, targets (by tag), source ranges, and ports at a glance — much easier to eyeball than the CLI list. You can also toggle **logging** on a rule here to record allowed/denied packets.

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

> 🖥️ **See it in the UI:** Console → **IAM & Admin → IAM** lists every principal (you, service accounts, groups) and the roles each holds. Tick **Include Google-provided role grants** to see the full picture. This is the fastest way to answer "who can touch this project, and with what power?"

---

## 4. Storing the JWT secret and DB password

So far we've been hand-waving the secrets. Let's do it right.

### 4.0 What is `jwt-secret` actually for?

Chapter 01 introduced JWTs briefly. Before we lock the secret away, it's worth understanding what we're storing and *why losing it is catastrophic*.

**The problem JWTs solve.** HTTP is stateless — the server forgets you the moment a request ends. After a user logs in with `POST /auth/login`, every *next* request (`GET /tasks`, `POST /tasks`, …) needs to prove "I'm still that same user". Two reasonable approaches exist:

1. **Server-side sessions** — the server keeps a `session_id → user_id` table in Redis or the DB. The client sends back a cookie. Works fine, but every server instance needs to share that state.
2. **JWTs** — the server hands the client a *signed* token at login time. The client sends it back on every request. The server verifies the signature and trusts the claim. **No lookup, no shared state.** This is what this app uses.

**What's actually in the token.** From `backend/app/auth.py` (`create_access_token`):

```python
payload = {
    "sub": str(user_id),     # "this token belongs to user 42"
    "iat": ...,              # issued-at timestamp
    "exp": ...,              # expires-at timestamp
}
return jwt.encode(payload, settings.jwt_secret, algorithm=...)
```

The payload is plain JSON. The interesting bit is the **signature**: `jwt.encode` HMACs the payload with `jwt_secret`. Anyone can read the payload (it's base64, not encrypted), but only someone holding `jwt_secret` can produce a valid signature for it.

**The verification half** is `get_current_user`. It pulls the `Authorization: Bearer <token>` header, runs `jwt.decode(token, settings.jwt_secret, ...)`, and trusts whatever `sub` the payload claims — *because the signature proves the server itself issued this token*.

**Why the secret has to live in Secret Manager.**

- Anyone who knows `jwt_secret` can forge a token claiming `sub: 1` (or any user_id) and instantly bypass login for that user.
- So the secret must be: long and random (≥ 32 bytes), never in git, never in logs, rotatable. Secret Manager gives you all three.

`db-password` is unrelated to auth — it's just the Postgres user's password, another credential we don't want hardcoded. Same treatment for the same reasons.

### 4.1 Enable the Secret Manager API

Like every GCP service, Secret Manager has to be **enabled per project** before you can use it. On a fresh project, your very first `gcloud secrets ...` call will fail with:

```
ERROR: ... Secret Manager API has not been used in project <id> before or it is disabled.
```

Enable it once:

```bash
gcloud services enable secretmanager.googleapis.com
```

Wait ~30 seconds for the activation to propagate, then continue.

> ⚠️ **Pitfall — propagation is eventual, not instant**
> Even after `enable` returns "finished successfully", the activation has to fan out to every region's API frontends. It's normal for the **first** `gcloud secrets ...` call to succeed and the **next** one (seconds later) to still fail with `SERVICE_DISABLED`. Don't re-enable, don't panic — just wait ~30–60 seconds and retry the failed command.

> 🖥️ **In the UI:** Console → **APIs & Services → Library**, search "Secret Manager API", click **Enable**. Same effect as the CLI command.

> 💡 **Why APIs are disabled by default**
> GCP keeps every service off until you opt in. That keeps the attack surface (and the per-project quota footprint) small, and it forces you to make an explicit decision before a new service can be called from your project. You'll do this `services enable` dance for every new service the first time you reach for it.

### 4.2 Create the secrets

```bash
echo -n "a-really-long-random-string-32-chars-min" | \
  gcloud secrets create jwt-secret --replication-policy=automatic --data-file=-

echo -n "a-strong-postgres-password" | \
  gcloud secrets create db-password --replication-policy=automatic --data-file=-
```

> 💡 **What is `echo -n ... | gcloud ... --data-file=-` doing?**
> Two pieces, both load-bearing:
>
> - **`--data-file=-`** tells gcloud "read the secret value from **stdin**" instead of from a file on disk. We use this so the secret never has to be written to a file (where it could end up in shell history, a backup, or accidentally committed to git).
> - **`echo -n`** prints the string **without a trailing newline**. Plain `echo "secret"` would actually store `secret\n` in Secret Manager — your app would later compare `"secret"` against `"secret\n"` and silently fail to authenticate or connect, with no obvious clue why. The `-n` flag is the entire reason this idiom exists.
>
> Alternatives, for context:
>
> ```bash
> # Interactive — gcloud prompts you for the value
> gcloud secrets create jwt-secret --replication-policy=automatic
>
> # From a file (then remember to shred it afterward)
> gcloud secrets create jwt-secret --replication-policy=automatic --data-file=./secret.txt
> ```

Read them back (as your user, just to confirm):

```bash
gcloud secrets versions access latest --secret=jwt-secret
gcloud secrets versions access latest --secret=db-password
```

> 💡 **What just happened?**
> Secret Manager stores each value as an immutable **version**. New values become version 2, 3, … . Apps usually read `latest` but can pin to a specific version for safety during rollouts.

> 🖥️ **See it in the UI:** Console → **Security → Secret Manager** lists your secrets, their versions, and which principals can access each one (the **Permissions** tab). The values stay hidden until you explicitly click to reveal a version — so the UI is safe to browse without leaking anything.

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

> 💡 **TLS in one breath**
> **TLS** (Transport Layer Security) is the encryption layer that turns plain HTTP into HTTPS — `HTTPS = HTTP wrapped in TLS`. It's the successor to SSL; people still say "SSL certificate" out of habit but mean the same thing. "Terminating TLS" just means: do the decryption here, then forward plain HTTP onward.

> 💡 **What's an "instance group"?**
> A GCP resource that bundles one or more VMs so they can be addressed as a single thing. The flavor you'll almost always want is a **Managed Instance Group (MIG)** — every VM is spun up from one shared **instance template**, and GCP will auto-scale, auto-heal (replace failing VMs), and roll out updates N-at-a-time for you. A load balancer doesn't forward to "a VM" directly; it forwards to a **backend service** that points at an instance group, and the LB picks a healthy VM from the group for each request. That indirection is what gives you horizontal scaling and zero-downtime deploys.
>
> **Our tutorial has no instance group** — there's just one app VM with its own external IP. The diagram above is what production looks like, not what we built. Chapter 13 walks through the upgrade.

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
