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

## 2. Anatomy of a Dockerfile

Open `backend/Dockerfile`. Walk through it line by line.

```dockerfile
FROM python:3.12-slim AS builder
```

Start from an **official Python image**. The `AS builder` names this stage so we can reference it later. This is called a **multi-stage build**.

```dockerfile
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1
```

Sets environment variables for *this image*. `PYTHONUNBUFFERED=1` is important: it makes Python print logs immediately instead of buffering them, so `docker logs` shows you the truth.

```dockerfile
WORKDIR /app
COPY requirements.txt .
RUN pip install --upgrade pip && pip wheel --wheel-dir /wheels -r requirements.txt
```

`COPY` first, then `RUN`. That order is a **caching trick**:

- If `requirements.txt` hasn't changed, Docker reuses the cached layer.
- If you edit source code only, the slow `pip install` step does **not** rerun.

```dockerfile
FROM python:3.12-slim AS runtime
```

Start a **second** stage from a fresh base. We will copy only what we need from `builder`:

```dockerfile
COPY --from=builder /wheels /wheels
COPY requirements.txt .
RUN pip install --no-index --find-links=/wheels -r requirements.txt && rm -rf /wheels
COPY app ./app
```

The runtime image now contains:

- Python 3.12-slim
- The installed packages
- Your source code

It does **not** contain: compilers, build tools, package caches. Smaller image → faster deploys, smaller attack surface, lower storage cost.

```dockerfile
USER app
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- `USER app` → don't run as root (security best practice). If an attacker escapes the app, they don't get root inside the container.
- `EXPOSE 8000` → documentation. It doesn't actually open a port; the `ports:` block in compose or a `-p` flag does.
- `CMD [...]` → the default command to start when the container runs.

---

## 3. Layers, in one picture

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

## 4. `.dockerignore` matters

`docker build` sends the entire build directory ("build context") to the Docker daemon. If you don't exclude things, you ship `node_modules`, `.git`, and your `.env` into the build — slow at best, dangerous at worst.

We have `.dockerignore` files in `backend/` and `frontend/`. They exclude things like `.env`, virtualenvs, and test caches.

⚠️ **Pitfall**: Forgetting `.env` in `.dockerignore` is how secrets get baked into public images. Always add it.

---

## 5. Build, run, debug

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

## 6. Images vs containers (concretely)

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

## 7. Why we use multi-stage builds

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

## 8. Registries

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

## 9. Containers in production != on your laptop

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

## 10. Checkpoint ✅

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

## 11. Optional exercise 🧪

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
