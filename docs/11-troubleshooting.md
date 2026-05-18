# Chapter 11 — Troubleshooting

A reference chapter. Skim it now, then come back here when something breaks.

The general method, before any specific tip:

1. **Reproduce or pin down "what is failing"** — be precise. Not "the app is down". Try: "the frontend returns HTTP 502 from the public IP, but the backend's `/healthz` is 200 when SSH'd into the VM".
2. **Find the boundary**. The boundary is the first thing between your input and the failure. Local → VPC → VM → container → app.
3. **Check the easy stuff at the boundary**. Logs, networking, recently changed files.
4. **Form one hypothesis. Test it.** Don't change three things and re-deploy.

---

## 1. Local development problems

### "Port already allocated"

```
Error response from daemon: ... port is already allocated
```

Something else is on the host port. Find it:

```bash
# macOS / Linux:
lsof -iTCP:3000 -sTCP:LISTEN
# Windows PowerShell:
Get-NetTCPConnection -LocalPort 3000
```

Either stop it, or change the host port in `docker-compose.yml` (e.g. `"3001:3000"`).

### Frontend changes don't appear

If you're using `docker compose up` (Path A), the React build is baked into the image. Rebuild:

```bash
docker compose up --build
```

Or switch to Path B (native `npm run dev`) for iterative work.

### Backend can't connect to DB on first start

The DB takes a few seconds to be ready. Our compose file already uses `depends_on: condition: service_healthy`. If it still fails, run `docker compose down -v && docker compose up --build` to ensure a clean slate.

### `passlib` complaining about bcrypt version

If you see something like `AttributeError: module 'bcrypt' has no attribute '__about__'`, the bcrypt package is too new for passlib 1.7.4. The `bcrypt==4.0.1` pin in `requirements.txt` fixes this. Make sure you didn't accidentally upgrade.

### Tests can't import the app

If pytest says `ModuleNotFoundError: No module named 'app'`, you're probably running it from the wrong directory. Run from `backend/`, not the repo root:

```bash
cd backend
pytest
```

---

## 2. Docker problems

### Image is huge

Multi-stage builds matter. `docker image ls` should show backend ≈ 150-200 MB and frontend ≈ 130-180 MB. If you see ~800 MB+, you probably skipped the multi-stage pattern or are using a non-`slim` base.

### `docker pull` is slow

Either bad caching layers or you're pulling on a slow connection. Look at the layers:

```bash
docker history <image>
```

The big layers usually correspond to one bad `COPY` line.

### "permission denied while trying to connect to the Docker daemon socket"

You need to run docker as root or be in the `docker` group:

```bash
sudo usermod -aG docker $USER
# then log out and back in
```

---

## 3. GCP / `gcloud` problems

### `PERMISSION_DENIED` on a command that worked yesterday

Three usual suspects, in order:

1. You ran `gcloud config set project SOMETHING_ELSE` and forgot.
2. Billing was disabled (free trial expired).
3. The relevant API was disabled (rare unless someone disabled it).

```bash
gcloud config list
gcloud services list --enabled
```

### "Quota exceeded"

GCP enforces region-wide quotas (number of CPUs, IP addresses, etc.). Usually triggered by leftover resources you forgot to delete (chapter 12). Open **IAM & Admin → Quotas** to see which one is full.

### `gcloud compute ssh` hangs

- The VM might still be booting (wait 30 sec).
- Your IAP firewall rule might be missing or scoped to the wrong tag.
- You may not have `roles/iap.tunnelResourceAccessor`.

Test the tunnel diagnostically:

```bash
gcloud compute ssh taskboard-app --tunnel-through-iap --troubleshoot
```

### `gcloud auth configure-docker` says it can't write the config

On the VM, you need to run gcloud commands as the same user that will run docker, or use `sudo gcloud …`. On the runner, this is usually a permission issue with `$HOME/.docker/config.json` — fix by deleting and re-running.

---

## 4. Networking problems

### "I can't reach my app at the external IP"

Step by step:

1. From your laptop: `curl -v http://<EXT_IP>` — does it time out (firewall) or 5xx (app)?
2. SSH into the app VM: `curl http://localhost:80` — does the container respond?
3. If yes, the problem is the firewall rule. Check `gcloud compute firewall-rules list --filter="network=taskboard-vpc"`.
4. If no, the container is the problem. `sudo docker ps` and `sudo docker logs taskboard-frontend`.

### "Backend can connect to DB on Compose, not on GCP"

Likely causes:

1. The `allow-internal-db` firewall rule doesn't exist or has the wrong target tag.
2. The DB VM's `pg_hba.conf` doesn't have the `host all all 10.10.0.0/24 md5` line.
3. The app VM is on a *different* subnet (you accidentally created two).

Quick triage from the app VM:

```bash
sudo apt-get install -y netcat
nc -vz taskboard-db 5432           # works → firewall + DNS OK
psql "postgresql://..." -c "\l"    # works → auth OK
```

### "DNS resolves on Compose but not in production"

The Compose service name (`backend`, `db`) only works inside the Compose network. In production, hostnames are **VM names** (`taskboard-db`) inside the same VPC. Check the connection string env var.

---

## 5. CI/CD problems

### Workflow says "Error: google-github-actions/auth failed"

Usually one of:

- WIF provider/pool not configured.
- `attribute-condition` doesn't match your repo (rename, fork, transfer all break this).
- `id-token: write` permission missing in the workflow file.

Re-run the WIF setup from chapter 09 § 5 and double-check `assertion.repository` matches your current GitHub repo path.

### Image push: `denied: Permission "artifactregistry.repositories.uploadArtifacts" denied`

The deployer service account is missing `roles/artifactregistry.writer`. Re-grant:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"
```

### `gcloud compute ssh` in deploy job hangs

Same causes as in § 3 above. Often the `iap.tunnelResourceAccessor` role is missing.

### "Why is the new image not running?"

The deploy step may have succeeded *uploading* the image, but the `docker run` step may not have happened. SSH in manually and check:

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Image}}'
```

If the running image's tag is older than your latest commit SHA, the deploy didn't actually start the new container.

---

## 6. Application problems

### "Login works, but tasks fail with 401"

The JWT secret on the backend changed (rotated) without restarting the container, or the secret in Secret Manager is different from what's in the container's env. Restart the backend container; the front-end will redirect users to log in again with the new key.

### "Postgres logs show 'too many clients already'"

The default Postgres `max_connections=100`. SQLAlchemy keeps connections in a pool — five backend replicas × pool size 5 × 4 workers = 100, easy to hit. Either raise `max_connections`, lower the pool size, or (the right answer in production) put PgBouncer in front.

### "Tasks aren't persisting after redeploy"

Either:

- You're hitting a different DB (check `DATABASE_URL`).
- You ran `docker compose down -v` locally and forgot you wiped the volume.
- You re-created the DB VM (which wipes its disk, since we didn't attach a separate persistent disk — see chapter 13).

---

## 7. When you really don't know

The general recipe:

1. **Read the actual error**, all of it. Especially the last 3 lines of a stack trace.
2. **Search the exact error message**, in quotes. Skip the AI summary and read the actual GitHub issue or StackOverflow answer.
3. **Bisect**. If it worked an hour ago, what changed? `git diff HEAD~1`.
4. **Reduce the surface**. Try the smallest possible version (`curl localhost:80` from inside the VM, `psql -h localhost`, …). If small succeeds and big fails, the difference is the bug.
5. **Sleep on it.** The number of bugs that vanish after 8 hours of sleep is uncanny.

---

## 8. The single most useful command

If you only remember one debug command:

```bash
gcloud compute ssh taskboard-app --tunnel-through-iap -- \
  "sudo docker ps; sudo docker logs --tail=100 taskboard-backend; sudo docker logs --tail=100 taskboard-frontend"
```

It tells you what's running and the last hundred log lines from each container, in one keystroke.

---

➡️ Next: [Chapter 12 — Cleanup and cost management](./12-cleanup-and-cost-management.md)
