# Chapter 03 — Docker basics

In the last chapter you used Docker as a tool. In this one we open the hood. By the end you'll understand what an **image**, **container**, **layer**, and **registry** actually are, and why each is essential to deploying to the cloud.

---

## 1. Why Docker exists

Before Docker:

> "I tested it on my laptop. It runs on my staging server. It crashes on production. **Why?**"

Because "on my machine" is a snowflake — your Python version, your env vars, the Postgres client library on your system, even your timezone. Docker freezes all of that into a single **image** so the *exact same* thing runs everywhere.

Three core ideas:

1. **Image** — a frozen, read-only filesystem snapshot of your app and its dependencies.
2. **Container** — a running instance of an image. Disposable. You start, stop, and delete them.
3. **Registry** — a remote storage for images (Docker Hub, Google Artifact Registry, GitHub Container Registry…).

Mental model: **image is to container as class is to object** in programming.

---

## 2. Anatomy of the backend Dockerfile

Open `backend/Dockerfile`. We're going to walk through it line by line. Each instruction is small in isolation, but together they tell a precise story about *what kind of image you want at the end*.

The whole file is also commented inline now — this section explains the **why** in more depth.

### 2.1 The two `FROM` lines and what "multi-stage" buys you

```dockerfile
FROM python:3.12-slim AS builder
...
FROM python:3.12-slim AS runtime
```

Two `FROM` lines means **two independent images built one after the other**. The first one — named `builder` — exists only inside this build. The image that actually ships is the **last** stage (`runtime`). The builder is thrown away after the build finishes.

Why bother?

| Concern              | Builder stage                  | Runtime stage                |
| -------------------- | ------------------------------ | ---------------------------- |
| Needs compilers?     | yes (some pip wheels build C)  | no                           |
| Needs pip cache?     | yes                            | no                           |
| Needs your source?   | no (just deps)                 | yes                          |
| Final size           | ~800 MB                        | ~150 MB                      |
| Ships to production? | **no**                         | yes                          |

The runtime image inherits **nothing** from the builder unless we explicitly say `COPY --from=builder …`. That's how the build tools get left behind.

`python:3.12-slim` is the **slim** variant of Python's official image — Debian-based but with docs, locales, and `/usr/share` cruft stripped out. The non-slim `python:3.12` is closer to 1 GB. `slim` is the right default for a deployable Python app.

### 2.2 Environment variables — three small flags that matter a lot

```dockerfile
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
```

A single `ENV` instruction with `\` continuations creates **one** image layer instead of four. Each `ENV`, `RUN`, and `COPY` produces a layer, and more layers = more metadata + more places the cache can miss. Bundle related env vars together.

What each one actually does:

- **`PYTHONDONTWRITEBYTECODE=1`** — Python normally writes `.pyc` files next to your `.py` files for faster imports. In a container that runs once and then exits, those `.pyc` files are useless bytes on disk. Off.
- **`PYTHONUNBUFFERED=1`** — by default, Python buffers stdout when it's not a terminal. Inside a container, stdout is a pipe to the Docker daemon, so Python **does** buffer, and `docker logs` shows nothing until the buffer fills or the process exits. With this flag, every `print()` and every log line flushes immediately. **This is the #1 reason new dockerized apps "look silent" when they're actually working.** Always set it.
- **`PIP_NO_CACHE_DIR=1`** — pip would otherwise keep every downloaded `.whl` in `~/.cache/pip`. In a one-shot container build, that cache only inflates the image.
- **`PIP_DISABLE_PIP_VERSION_CHECK=1`** — skips pip's "a new pip is available" banner on every invocation. Faster, less log noise.

### 2.3 `WORKDIR` — the persistent `cd`

```dockerfile
WORKDIR /app
```

Sets the working directory for every `RUN`, `COPY`, and `CMD` that follows. If `/app` doesn't exist, Docker creates it. It's similar to `cd /app` except the change is permanent for this layer and every layer that comes after. Using `WORKDIR` (instead of `RUN cd /app && …`) is the idiomatic way.

### 2.4 The cache-friendly `COPY` order

```dockerfile
COPY requirements.txt .
RUN pip install --upgrade pip && pip wheel --wheel-dir /wheels -r requirements.txt
...
COPY app ./app
```

This is the single most important pattern in this whole file:

> Files that **change rarely** go near the top. Files that **change constantly** go near the bottom.

Docker caches each layer based on the content of its inputs. If `requirements.txt` is byte-for-byte identical to the last build, Docker reuses the cached `pip wheel` layer — which can save several minutes per build. If we copied `app/` first, then *every code change* would invalidate the wheels layer too, and you'd reinstall everything on every save. Painful.

### 2.5 `pip wheel` vs `pip install`

```dockerfile
RUN pip install --upgrade pip && \
    pip wheel --wheel-dir /wheels -r requirements.txt
```

`pip wheel` **downloads and compiles** every dependency into `.whl` files inside `/wheels` — but does **not install them anywhere**. We've essentially built a tiny, offline package mirror.

Then in the runtime stage:

```dockerfile
COPY --from=builder /wheels /wheels
RUN pip install --no-index --find-links=/wheels -r requirements.txt && \
    rm -rf /wheels
```

- `--no-index` tells pip "don't talk to PyPI". This is faster, reproducible, and surfaces missing deps immediately instead of pulling them from the internet at runtime build time.
- `--find-links=/wheels` tells pip "look in this folder for wheels".
- `rm -rf /wheels` in the **same `RUN`** is critical: if you delete the wheels in a later layer, they still live in the previous layer's filesystem and bloat the image. Layers are append-only; you can only shrink a layer by not creating those files in it in the first place.

### 2.6 Non-root user

```dockerfile
RUN useradd --create-home --shell /bin/bash app
...
USER app
```

By default, every command in a Dockerfile runs as **root** inside the image. That's convenient for installing packages but dangerous for the running app: if anyone exploits a bug in your code, they get root *inside* the container. With user namespacing misconfigured (which it often is in dev clusters), that's one short hop from root *on the host*.

Creating a user named `app` and switching to it with `USER app` means the running process can't `chown`, can't write to `/usr/local`, can't `apt-get install` more packages. Cheap, large defense.

A few practical points:

- `--create-home` gives `/home/app`, which some libraries expect to exist.
- `--shell /bin/bash` makes `docker exec -it ... bash` work for debugging.
- Anything you need to do as root (`apt-get install`, system tweaks) MUST happen **before** `USER app`. After that line, you're no longer privileged.

### 2.7 `EXPOSE` — documentation, not magic

```dockerfile
EXPOSE 8000
```

`EXPOSE` does **not** publish a port. It's a hint, a comment for humans (and a few tools like `docker run -P`) saying "the app inside listens on 8000". Actually making the port reachable from your host requires either `-p 8000:8000` on `docker run` or a `ports:` entry in `docker-compose.yml`.

People often think `EXPOSE` is what opens the port. It is not. Knowing this saves an hour of head-scratching at least once in every engineer's career.

### 2.8 `HEALTHCHECK`

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz').status==200 else 1)"
```

Docker will run this command periodically inside the container. If it exits 0 → healthy, non-zero → unhealthy. Many orchestrators react to this:

- Docker Compose's `depends_on: condition: service_healthy` waits for it.
- Kubernetes has its own `livenessProbe` / `readinessProbe` (different mechanism, same idea).

The flags:

- `--interval=30s` — how often to check.
- `--timeout=5s` — fail the check if it takes longer.
- `--start-period=10s` — grace window after container start where failures don't count toward the unhealthy threshold. Apps need a few seconds to come up.
- `--retries=3` — three consecutive failures before flipping to "unhealthy".

We use Python's `urllib` instead of `curl` so we don't have to install `curl` just to power the health check. Smaller image, fewer attack surface entries.

### 2.9 `CMD` — and why the array form matters

```dockerfile
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

`CMD` is the default command Docker runs when the container starts. There are two forms:

| Form               | Example                                     | What happens                                                |
| ------------------ | ------------------------------------------- | ------------------------------------------------------------ |
| **Array (exec)**   | `CMD ["uvicorn", "app.main:app"]`           | `uvicorn` is exec'd directly as PID 1. Signals reach it.     |
| String (shell)     | `CMD uvicorn app.main:app`                  | Docker wraps it in `/bin/sh -c "..."` — signals hit sh, not uvicorn. |

Use the **array form**. Otherwise `docker stop` (which sends SIGTERM) hits `sh`, which doesn't forward signals, so your app gets killed instead of shutting down cleanly. That means dropped requests, no flush of in-flight work, no graceful goodbye.

One subtle bit: `--host 0.0.0.0`. That binds uvicorn to **every interface inside the container**. `0.0.0.0` inside a container is **not** the same as "publicly exposed" — the container is still in its own network namespace, still firewalled by Docker (or by your VPC in production). If you used `127.0.0.1` here instead, the app would only be reachable from inside the container itself, and even a `-p 8000:8000` wouldn't help you. People hit this constantly.

---

## 3. The frontend Dockerfile — same ideas, different runtime

Open `frontend/Dockerfile`. The structure mirrors the backend, but the build *output* is fundamentally different and worth understanding.

### 3.1 The "build" stage actually produces static files

```dockerfile
FROM node:20-alpine AS builder
...
RUN npm run build
```

The builder stage runs Vite (`npm run build`), which type-checks, bundles, tree-shakes, and minifies everything under `src/` into a folder of **plain static files** at `/app/dist`. After this step, `dist/` contains:

- `index.html`
- a few hashed `.js` and `.css` files
- any static assets

That's the entire product of the frontend build. The browser doesn't need React, JSX, or Vite — it gets HTML+JS+CSS. The runtime image only has to **serve those files** and proxy `/api/*` to the backend.

### 3.2 `node:20-alpine` and the musl gotcha

```dockerfile
FROM node:20-alpine AS builder
```

Alpine Linux is *much* smaller than Debian — the base is ~5 MB, the Node image ~50 MB instead of ~350 MB. The catch: Alpine uses **musl libc** instead of **glibc**, which sometimes breaks native modules pre-built for glibc (e.g. some image processing libs, some database drivers). For pure JS/TS + Vite + Express we're fine.

When in doubt, the safer default is `node:20-slim` (Debian-based, still small-ish). Switch only if you hit a musl-incompatible dependency.

### 3.3 `npm ci` vs `npm install`

```dockerfile
COPY package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund
```

- **`npm ci`** — "clean install". Requires `package-lock.json`. Installs **exactly** the versions in the lockfile. Fails loudly if `package.json` and the lockfile disagree. This is what you want in CI/CD and in Docker builds.
- **`npm install`** — resolves versions fresh, can update the lockfile. Convenient locally, dangerous in CI (you'd get "works on my machine" reproducibility issues).

The `|| npm install` fallback exists only for setups that don't commit a lockfile. The `*` after `package-lock.json` tells `COPY` "this file may or may not exist; don't fail the build if it's missing".

`--no-audit` skips the security scan (noisy and slow in CI — run it separately in a real pipeline). `--no-fund` skips the "consider funding me" banners.

### 3.4 Two installs, two reasons

The builder installs the **full** dependency tree (dev deps included — vite, eslint, vitest, typescript…). The runtime installs only the **production** deps:

```dockerfile
RUN npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund
```

`--omit=dev` skips everything in `devDependencies`. That alone cuts `node_modules` roughly in half. The runtime only needs to **run** Express; the build tools are already done with their job in stage 1.

### 3.5 What gets copied into the runtime

```dockerfile
COPY server.js ./
COPY --from=builder /app/dist ./dist
```

Just two things:

1. `server.js` — the small Express server that serves `/dist` and proxies `/api/*`.
2. `/app/dist` from the builder stage — the static React bundle.

Notice what is **not** copied: `src/`, `vite.config.js`, `tests/`, `eslint.config.js`. None of those are needed at runtime. Leaving them out makes the image smaller and reduces the surface a security scanner has to chew through.

### 3.6 Non-root user — Alpine syntax

```dockerfile
RUN addgroup -S app && adduser -S app -G app
USER app
```

Same idea as the backend's `useradd`, different tools. Alpine's BusyBox `adduser` has different flags than Debian's `useradd`:

- `addgroup -S app` — create a system group named `app`.
- `adduser -S app -G app` — create a system user `app` in group `app`.

`-S` means "system": no home dir by default, no password set. We don't need either since this account exists only to drop privileges.

### 3.7 `HEALTHCHECK` with `wget`, not `curl`

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:3000/healthz >/dev/null 2>&1 || exit 1
```

Alpine ships **`wget` by default** but not `curl`. Using `wget` saves us an `apk add curl` step (and ~3 MB).

- `-q` — quiet, don't print progress.
- `-O-` — write to stdout (we redirect it to `/dev/null`; we only care about the exit code, not the response body).

---

## 4. Layers, in one picture

Each `RUN`, `COPY`, and `ADD` creates a **layer**. Layers stack and are content-addressed (hashed), so Docker can cache them aggressively.

```
[ layer 5: COPY app ./app          ]   ← changes most often
[ layer 4: install pinned wheels    ]
[ layer 3: COPY requirements.txt    ]
[ layer 2: ENV …                    ]
[ layer 1: python:3.12-slim         ]   ← changes least often
```

> 💡 Order your Dockerfile from "changes rarely" at the bottom to "changes constantly" at the top. That maximizes cache hits.

---

## 5. `.dockerignore` matters

`docker build` sends the entire build directory ("build context") to the Docker daemon. If you don't exclude things, you ship `node_modules`, `.git`, and your `.env` into the build — slow at best, dangerous at worst.

We have `.dockerignore` files in `backend/` and `frontend/`. They exclude things like `.env`, virtualenvs, and test caches.

⚠️ **Pitfall**: Forgetting `.env` in `.dockerignore` is how secrets get baked into public images. Always add it.

---

## 6. Build, run, debug

```bash
# Build the backend image standalone:
docker build -t taskboard-backend ./backend

# Inspect the image:
docker images taskboard-backend
docker history taskboard-backend     # see every layer

# Run it manually (no compose):
docker run --rm -p 8000:8000 \
  -e DATABASE_URL='sqlite:///./local.db' \
  taskboard-backend

# Get a shell inside a running container:
docker exec -it <container-id-or-name> bash
```

That last one is the single most useful skill in a debugging emergency — once you can poke around inside a running container, mysteries dissolve fast.

---

## 7. Images vs containers (concretely)

```bash
docker images          # list IMAGES
docker ps              # list RUNNING containers
docker ps -a           # list ALL containers (incl. stopped)
docker rm <id>         # delete a container
docker rmi <id>        # delete an image
docker system prune    # delete dangling things (free disk)
```

> ⚠️ **Pitfall**
> `docker system prune -a -f --volumes` will nuke unused images **and** volumes. Don't run it absent-mindedly while you have local data you care about.

---

## 8. Why we use multi-stage builds

Two reasons, both about production:

1. **Size.** A typical "compile + run" image is 800MB. The split image is 150MB. Deploys are faster, registry pulls are faster, your bill is smaller.
2. **Security.** Compilers and dev headers are an attacker's toolkit. Not shipping them = nothing for them to use.

> 🧠 **Think first**
> Why don't we just `COPY .` and call it a day?

Because:
- It ignores `.dockerignore` lessons (you ship junk).
- It busts the cache on every code change for unrelated layers (slow rebuilds).
- It may include dev-only files and secrets.

---

## 9. Registries

Once your image exists, you need to put it somewhere a server can pull it from. That place is a **registry**.

| Registry                       | Maintained by | When we use it                       |
| ------------------------------ | ------------- | ------------------------------------ |
| Docker Hub                     | Docker Inc.   | Pulling public images like Postgres. |
| **Google Artifact Registry**   | Google Cloud  | Pushing our own images (chapter 09). |
| GitHub Container Registry      | GitHub        | Alternative for OSS / self-hosted.   |

The full image reference looks like:

```
<registry-host>/<project>/<repo>/<image>:<tag>
europe-west4-docker.pkg.dev/my-project/taskboard/backend:1.0.3
```

We'll create one of these in chapter 09.

---

## 10. Containers in production != on your laptop

A few differences worth knowing now so they're not surprises later:

| Concern         | On your laptop             | In production                                                          |
| --------------- | -------------------------- | ---------------------------------------------------------------------- |
| Restart policy  | Stops when you stop it     | Auto-restart on crash (Docker, systemd, or Kubernetes)                 |
| Logs            | Go to your terminal        | Go to a central log system (Cloud Logging)                             |
| Secrets         | `.env` on disk             | A secret manager (Secret Manager, Vault) injected at start             |
| Storage         | Bind mounts / named volumes| Managed disks; data stores live OUTSIDE the container                  |
| Networking      | Compose bridge network     | A real cloud VPC with subnets and firewall rules                       |

We'll bridge each of these as the tutorial progresses.

---

## 11. Checkpoint ✅

1. Why do we `COPY requirements.txt` *before* `COPY app`?
2. What does `USER app` do, and why?
3. What's the difference between an **image** and a **container**?
4. Why do we use multi-stage builds?

> Answers
> 1. So Docker can cache the slow `pip install` step. Source-only edits don't invalidate it.
> 2. Switches the container's runtime user from root to `app`. Reduces blast radius if the app is compromised.
> 3. Image = frozen template. Container = a running (or stopped) instance of an image.
> 4. Smaller final image and fewer build tools in production → faster deploys, smaller attack surface.

---

## 12. Optional exercise 🧪

Time the backend rebuild with and without changing `requirements.txt`:

```bash
docker build -t taskboard-backend ./backend           # cold
# edit a comment in backend/app/main.py
docker build -t taskboard-backend ./backend           # warm
# add a harmless `# comment` line to requirements.txt
docker build -t taskboard-backend ./backend           # cold-ish
```

What do you observe about which layers were rebuilt?

---

➡️ Next: [Chapter 04 — GCP introduction](./04-gcp-introduction.md)
