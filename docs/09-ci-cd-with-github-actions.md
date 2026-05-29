# Chapter 09 — CI/CD with GitHub Actions

The biggest jump from "I have a deployed app" to "I have a *real* product" is **automation**. From now on, you don't deploy by SSH'ing in and running commands. You **push code**, and a robot does the rest.

This chapter explains the pipeline file (`.github/workflows/ci-cd.yml`) line by line, sets up the GCP side (service account, workload identity, Artifact Registry), and ships your first automated deploy.

---

## 1. What "CI/CD" actually means

- **CI — Continuous Integration**: every push runs your tests, your linters, and your build. The goal: never let broken code accumulate.
- **CD — Continuous Delivery**: when CI passes on `main`, the system produces a deployable artifact (a Docker image) and pushes it to a registry. Deploying is one button-press.
- **CD — Continuous Deployment**: same as above, but the deploy *also* happens automatically.

We do the third one. Pushing to `main` ships to production.

That's powerful. It's also why we put effort into **tests, linters, and rollback** — automation amplifies whatever you put in.

---

## 2. The five-step mental model

```
   developer's laptop
         │  git push
         ▼
    ┌─────────────────┐
    │   GitHub repo   │
    └────────┬────────┘
             │ webhook
             ▼
    ┌─────────────────────────────────────────┐
    │ GitHub Actions runner (a fresh Ubuntu VM)│
    │  1) test                                 │
    │  2) lint                                 │
    │  3) docker build                         │
    │  4) docker push → Artifact Registry      │
    │  5) gcloud ssh → app VM → docker pull/run│
    └────────┬─────────────────────────────────┘
             │
             ▼
        ┌──────────┐  HTTP  ┌────────┐
        │ app VM   │ ─────► │ db VM  │
        │ (Docker) │        │ (PG)   │
        └──────────┘        └────────┘
```

Five steps. Each is a distinct **job** in our workflow.

---

## 3. The workflow file, top to bottom

Open `.github/workflows/ci-cd.yml` in the repo. Walk through it alongside this section.

### `on:` — when does this run?

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
```

Two triggers:

- A push to `main` (real deploy).
- A pull request targeting `main` (tests only).

PRs **do not** deploy. That's deliberate — preview environments are a more advanced topic (chapter 13).

### `concurrency:` — don't trip over yourself

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

If you push twice quickly, the older deploy is cancelled. No race conditions on the VM.

### `permissions:` — least privilege at the workflow level too

```yaml
permissions:
  contents: read
  id-token: write
```

- `contents: read` — the workflow can clone the repo.
- `id-token: write` — required to mint the **OIDC token** GitHub gives us, which we exchange for GCP credentials. (See § 5.)

### The three jobs

1. `test-backend` and `test-frontend` — run on every push and PR.
2. `build-and-push` — only on `main`. Depends on the tests.
3. `deploy` — only on `main`. Depends on `build-and-push`.

`needs:` is how a job declares "wait for these other jobs first".

> 💡 **Why split into multiple jobs?**
> Each job runs on a fresh VM in parallel where possible. Splitting also makes the UI clearer — you can re-run just the failed job, and the test signal is delivered faster than waiting for the whole pipeline.

---

## 4. The CI jobs (testing and linting)

> 💡 **What's "linting" and what's "ruff"?**
> **Linting** is automated static analysis — a tool reads your source code *without running it* and flags style violations (PEP 8), unused imports, likely bugs (mutable default args, shadowed names), inconsistent import order, forgotten `print()` calls, and so on. It catches a class of issues tests don't catch: tests check **behavior**, linters check the **code itself**. Cheap, runs in milliseconds, gives instant feedback before a human reviewer ever sees the PR.
>
> **Ruff** is the modern Python linter — written in Rust, ~10–100× faster than older tools. It replaces a whole stack (`flake8` + `pylint` + `isort` + `pyupgrade` + `black`) with one binary and one config. Most Python projects started in 2024+ just use ruff. Common subcommands:
>
> ```bash
> ruff check app tests        # report problems (this is the CI gate below)
> ruff check --fix app tests  # report AND auto-fix what it can
> ruff format app tests       # apply black-style formatting
> ```
>
> If `ruff check` finds anything, it exits non-zero and the CI job fails — the PR can't merge until it's clean.

The backend job:

```yaml
- name: Lint (ruff)
  run: ruff check app tests
- name: Tests (pytest)
  env:
    DATABASE_URL: "sqlite:///./ci.db"
    JWT_SECRET: "ci-only-not-a-real-secret"
  run: pytest -q
```

Two important things:

1. The tests use **SQLite**, not Postgres. The smoke tests don't need DB-specific behavior, and SQLite needs zero infrastructure to run in CI.
2. `JWT_SECRET` is a placeholder — it's not a real secret because the tests don't talk to the real cloud.

The frontend job lints, runs `vitest`, and `npm run build` as a smoke test of the production bundle.

> ⚠️ **Pitfall**
> If your tests *need* a real Postgres (e.g. integration tests with PG-specific SQL), you'd start one as a **service container**. We keep tests dependency-free here for speed.

---

## 5. Workload Identity Federation — the modern auth model

**The old way**: create a service account, download a JSON key, paste it into a GitHub Secret. The risks are:

- The key never expires.
- A leaked key = total compromise.
- Rotating keys is painful.

**The new way (WIF)**: GitHub mints a short-lived OIDC token for each workflow run. GCP is configured to **trust GitHub's tokens** and exchange them for a short-lived GCP access token. No JSON keys exist anywhere.

```
GitHub Actions          GCP STS                     GCP API
   │  OIDC token (5 min)  │                             │
   │ ───────────────────► │                             │
   │                      │  exchange → access token    │
   │ ◄─────────────────── │                             │
   │  uses access token to call gcloud ──────────────► │
```

### Setting it up (do this once)

The block below is **bash** — it uses `$()`, `for ... do ... done`, and `\` line continuations that PowerShell can't parse, so pasting it into a Windows terminal will fail.

Use the ready-made script instead:

```powershell
# From the repo root, in PowerShell:
.\scripts\setup-wif.ps1 -Repo "<your-github-user>/<your-repo>"
```

It runs the same four steps shown below, then prints the two values you'll paste into your GitHub repo secrets (`GCP_WIF_PROVIDER` and `GCP_SA_EMAIL`).

> 💡 **On macOS / Linux / WSL** you can paste the bash version straight into your shell — just edit the `REPO=` line first.

<details>
<summary>What the script actually runs (the bash equivalent)</summary>

```bash
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
POOL=github-pool
PROVIDER=github
REPO=<your-github-user>/<your-repo>           # ← change me
SA=github-deployer

# 1) The service account that GitHub will impersonate.
gcloud iam service-accounts create $SA \
  --display-name="GitHub Actions deployer"

# 2) Grant the deployer the least-privilege roles it needs.
for role in roles/artifactregistry.writer roles/compute.instanceAdmin.v1 \
            roles/iap.tunnelResourceAccessor roles/iam.serviceAccountUser \
            roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="$role"
done

# 3) Create the workload identity pool + provider.
gcloud iam workload-identity-pools create $POOL \
  --location=global \
  --display-name="GitHub pool"

gcloud iam workload-identity-pools providers create-oidc $PROVIDER \
  --location=global \
  --workload-identity-pool=$POOL \
  --display-name="GitHub provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == '${REPO}'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# 4) Let the GitHub-side identity impersonate the service account.
gcloud iam service-accounts add-iam-policy-binding "${SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

# 5) Print the value you need for the GitHub secret GCP_WIF_PROVIDER.
echo "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
```
</details>

> ⚠️ **The `attribute-condition`** is the key security control: even if some other GitHub repo tried to impersonate this SA, GCP would reject it because `assertion.repository` wouldn't match.

> 🖥️ **See it in the UI:** Console → **IAM & Admin → Workload Identity Federation** shows your pool (`github-pool`) and provider, including the attribute mapping and condition. The deployer service account itself lives under **IAM & Admin → Service Accounts** — open it to confirm which principals are allowed to impersonate it.

---

## 6. Artifact Registry

This is where images live. Create the repo once:

```bash
gcloud artifacts repositories create taskboard \
  --repository-format=docker \
  --location=$(gcloud config get-value compute/region) \
  --description="TaskBoard images"
```

The full reference for the backend image then becomes:

```
<region>-docker.pkg.dev/<project-id>/taskboard/backend:<git-sha>
```

That's what the pipeline pushes to.

> 💡 We tag every image with the **short git SHA** (immutable, traceable) and also with `latest` (for convenience). In real production you usually drop `latest` to prevent ambiguity — see chapter 13.

> 🖥️ **See it in the UI:** Console → **Artifact Registry → Repositories → `taskboard`** lists every pushed image and tag, with sizes, push timestamps, and (if enabled) vulnerability-scan results. After your first deploy, this is where you confirm the image actually landed and find the SHA tags you'd roll back to.

---

## 7. The deploy job, demystified

```yaml
- name: Deploy on app VM
  run: |
    gcloud compute ssh ${{ secrets.APP_VM_NAME }} \
      --zone=${{ secrets.GCP_ZONE }} \
      --tunnel-through-iap \
      --command="bash -s" <<EOF
    ...
    sudo docker pull "${BACKEND_IMAGE}"
    sudo docker pull "${FRONTEND_IMAGE}"
    sudo docker rm -f taskboard-backend  || true
    sudo docker rm -f taskboard-frontend || true
    sudo docker run -d --name taskboard-backend  ...
    sudo docker run -d --name taskboard-frontend ...
    EOF
```

What this does:

1. Tunnels SSH through IAP (no public port 22).
2. Streams a bash script into the VM.
3. The VM uses its own service account to talk to Artifact Registry.
4. The two containers are restarted with the new image tags.
5. A smoke check confirms `/healthz` returns 200.

### Behind the scenes — why this is "OK but not amazing"

This deploy is **destructive in place**: there is a window of ~5–10 seconds where the old container is gone and the new one is starting. That's fine for a learning project. Real production uses:

- **Rolling updates** (managed instance groups + health checks).
- **Blue/green** (two parallel environments, swap traffic via load balancer).
- **Canary** (route a few % of traffic to the new version, then ramp up).

Chapter 13 covers these as next steps.

---

## 8. Secrets management — three places, same value

The same `JWT_SECRET` exists conceptually in three places, never as plain text in git:

| Location              | Form                          | When read                           |
| --------------------- | ----------------------------- | ----------------------------------- |
| Secret Manager        | encrypted at rest             | source of truth                     |
| GitHub Actions runner | env var during deploy job     | read for 5 minutes by the workflow  |
| App VM (running cont.)| env var in the container      | read at container start             |

The chain only works one direction: Secret Manager → runner → container. Nothing flows back. If you rotate the secret in Secret Manager, the next deploy picks it up. The previous container keeps using the old value until restart.

> 💡 **Why GitHub Secrets at all?** They store the **shape** of the connection (project ID, VM name) and the WIF identity, not the application secrets themselves. App secrets stay in Secret Manager.

---

## 9. Rollback — the most underrated CI/CD feature

Stuff breaks. You need a one-minute way to go back.

**Approach 1 — re-deploy a known good commit.**

In the GitHub Actions UI, find a previous successful run on `main`, click **Re-run all jobs**. The pipeline will rebuild that commit's image and redeploy. ~3 minutes.

**Approach 2 — pin an older image manually.**

On the app VM:

```bash
PREV_SHA=<a-known-good-short-sha>
BASE=<region>-docker.pkg.dev/<project>/taskboard
sudo docker pull "${BASE}/backend:${PREV_SHA}"
sudo docker rm -f taskboard-backend
sudo docker run -d --name taskboard-backend ... "${BASE}/backend:${PREV_SHA}"
```

Because every image is tagged with the git SHA, this always works. **This is why we don't rely on `latest`.**

---

## 10. Required GitHub secrets recap

In your GitHub repo: **Settings → Secrets and variables → Actions → New repository secret**. Add these:

| Secret              | Example value                                                    |
| ------------------- | ---------------------------------------------------------------- |
| `GCP_PROJECT_ID`    | `taskboard-learning-1`                                           |
| `GCP_REGION`        | `europe-west4`                                                   |
| `GCP_ZONE`          | `europe-west4-a`                                                 |
| `GCP_WIF_PROVIDER`  | `projects/123/locations/global/workloadIdentityPools/github-pool/providers/github` |
| `GCP_DEPLOYER_SA`   | `github-deployer@taskboard-learning-1.iam.gserviceaccount.com`   |
| `ARTIFACT_REPO`     | `taskboard`                                                      |
| `APP_VM_NAME`       | `taskboard-app`                                                  |
| `DB_HOSTNAME`       | `taskboard-db`                                                   |

GitHub Secrets are **write-only** from the UI — you can't read them back. Treat your secret values as one-way valves.

---

## 11. Ship it

1. Push your repo to GitHub.
2. Add the secrets above.
3. Commit something small (a typo fix) and push to `main`.
4. Watch the **Actions** tab.
5. When green, hit `http://<APP_VM_EXTERNAL_IP>` in a browser.

🎉 Your first robot-driven deploy.

---

## 12. Common beginner mistakes

| Mistake                                                                | Fix                                                                          |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Hardcoding a service account JSON key                                  | Use Workload Identity Federation. Never commit keys.                         |
| Tagging only `:latest`                                                 | You lose the ability to roll back. Tag by SHA and use `:latest` only as alias. |
| Not waiting on health checks before declaring success                  | Add a `curl /healthz` step that retries.                                     |
| Re-running deploys without invalidating in-flight runs                 | Use `concurrency: cancel-in-progress`.                                       |
| Granting `roles/owner` to the deployer "to make it work"               | Find the actual missing role; never use Owner.                               |
| Putting application secrets in GitHub Secrets directly                 | Put them in Secret Manager; let the workflow fetch them at deploy time.      |

---

## 13. Checkpoint ✅

1. What problem does **Workload Identity Federation** solve compared to JSON keys?
2. Why do we tag each image with the git SHA?
3. What does `concurrency: cancel-in-progress` do?
4. Where does the JWT secret live, and how does it get into the container?

> Answers
> 1. Long-lived JSON keys never expire and are catastrophic if leaked. WIF tokens are short-lived and tied to a specific repo/branch.
> 2. Immutable, traceable, and gives you a working rollback strategy.
> 3. If a new push happens during an older run, the older run is cancelled — preventing two deploys racing on the VM.
> 4. In Secret Manager. The deploy job fetches it, passes it as an env var into the SSH session, which sets it on `docker run -e JWT_SECRET=…`.

---

## 14. Optional exercise 🧪

Break the pipeline on purpose: open `backend/app/main.py`, introduce a syntax error, and push. Watch:

- `test-backend` fails immediately.
- `build-and-push` never starts.
- `deploy` never starts.
- The VM keeps serving the previous version untouched.

That's the **whole point** of a pipeline. A bad commit cannot reach production by accident.

---

➡️ Next: [Chapter 10 — Monitoring and logging](./10-monitoring-and-logging.md)
