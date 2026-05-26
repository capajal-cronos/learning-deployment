# =============================================================================
# Backend Dockerfile — FastAPI (Python)
# =============================================================================
# This is a MULTI-STAGE build. Two `FROM` lines = two independent images
# built in sequence. We use the first ("builder") to compile/download Python
# packages, and the second ("runtime") to actually ship the app.
#
# Why bother?
#   - The builder needs compilers + pip + dev headers. ~800 MB.
#   - The runtime just needs Python + the installed packages. ~150 MB.
#   - Smaller runtime → faster deploys, faster pulls, smaller attack surface.
#
# Layer-cache tip you'll see repeated below:
#   Put lines that change RARELY at the top, and lines that change OFTEN at
#   the bottom. Docker reuses a cached layer only if every layer above it is
#   still identical. Source code changes constantly; requirements.txt does
#   not — so we COPY requirements.txt first and COPY app/ later.
# =============================================================================


# ---- Stage 1: builder -------------------------------------------------------
# `python:3.12-slim` = official Python image on a minimal Debian base.
# `slim` strips out docs, locales, and most extras — much smaller than the
# default `python:3.12` (~120 MB vs ~1 GB), but still has apt + pip.
# `AS builder` names this stage so the runtime stage can copy from it later.
FROM python:3.12-slim AS builder

# Bundle 4 env vars into ONE layer (each ENV/RUN/COPY = one layer).
#   PYTHONDONTWRITEBYTECODE=1  → don't create .pyc files. Smaller image, and
#                                they're useless in a throwaway container.
#   PYTHONUNBUFFERED=1         → flush stdout/stderr immediately. Without
#                                this, `docker logs` lags behind reality and
#                                you'll think your app is silent when it
#                                isn't. CRITICAL for debugging.
#   PIP_NO_CACHE_DIR=1         → don't keep pip's download cache on disk.
#   PIP_DISABLE_PIP_VERSION_CHECK=1 → skip the "new pip available" check on
#                                every invocation. Faster, less log noise.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Set the working dir for every subsequent RUN/COPY/CMD. If /app doesn't
# exist, Docker creates it. Same idea as `cd /app` but persistent.
WORKDIR /app

# COPY requirements.txt FIRST, before any source code. This is the single
# most important caching trick in this file: as long as requirements.txt is
# unchanged, Docker reuses the cached `pip wheel` layer below, even if
# you've edited 50 .py files. Wheel-building is slow (minutes); source
# edits should never trigger it.
COPY requirements.txt .

# `pip wheel` downloads + compiles every dependency into a .whl file in
# /wheels — but does NOT install them. We're effectively pre-building a
# little offline package mirror that the runtime stage can install from
# without ever touching the internet or a C compiler.
RUN pip install --upgrade pip && \
    pip wheel --wheel-dir /wheels -r requirements.txt


# ---- Stage 2: runtime -------------------------------------------------------
# Brand-new image, fresh from the same slim base. NONE of the builder's
# files exist here unless we explicitly `COPY --from=builder` them in.
# That's how multi-stage builds keep the runtime small: build tools and
# caches are simply left behind.
FROM python:3.12-slim AS runtime

# Repeat the runtime-relevant env vars (build-only ones like
# PIP_DISABLE_PIP_VERSION_CHECK don't matter at runtime).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Create a non-root user named `app`. By default, containers run everything
# as root — which is fine until the app gets compromised. With USER app
# (set below), any code execution exploit lands as `app`, not root, so the
# attacker can't write to system paths or install packages. Cheap defense.
#   --create-home  → gives /home/app, expected by some libraries.
#   --shell        → so `docker exec -it ... bash` works for debugging.
RUN useradd --create-home --shell /bin/bash app

WORKDIR /app

# Pull the pre-built wheels out of the builder image, install them with
# --no-index so pip refuses to hit the internet (faster, more reproducible,
# and forces us to notice if a dep is missing from the wheel set), and
# then delete /wheels because they're useless once installed. Deleting in
# the SAME `RUN` is important — otherwise the wheels live forever in the
# previous layer and bloat the final image.
COPY --from=builder /wheels /wheels
COPY requirements.txt .
RUN pip install --no-index --find-links=/wheels -r requirements.txt && \
    rm -rf /wheels

# Copy the actual application code LAST — it changes on every commit, so
# putting it at the bottom means edits invalidate only this one layer.
COPY app ./app

# Switch to the non-root user. Everything below this line — and the running
# container itself — executes as `app`. Note: anything you need to do as
# root (apt-get install, useradd, chown system files) must happen BEFORE
# this line.
USER app

# EXPOSE is DOCUMENTATION ONLY. It does NOT publish the port — that's done
# by `-p` on `docker run` or `ports:` in docker-compose.yml. Think of it as
# a hint to humans (and a few tools) that the app listens on 8000.
EXPOSE 8000

# Docker can periodically run a command inside the container and mark it
# unhealthy if the command fails. Compose and Kubernetes both use this
# signal — `depends_on: condition: service_healthy` waits for it.
#   --interval=30s   → run the check every 30s
#   --timeout=5s     → fail the check if it takes longer than 5s
#   --start-period=10s → grace window after container start (failures
#                        during this window don't count)
#   --retries=3      → need 3 consecutive failures to mark unhealthy
# We use `python -c` instead of `curl` so we don't have to install curl
# just for the healthcheck (smaller image).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz').status==200 else 1)"

# CMD = the default command the container runs. Using the JSON-array form
# (["uvicorn", ...]) means Docker `exec`s the binary directly, so signals
# like SIGTERM reach uvicorn cleanly. The shell form ("uvicorn ...") would
# wrap it in /bin/sh -c, which swallows signals and breaks graceful
# shutdown.
#   --host 0.0.0.0   → listen on every interface inside the container.
#                      0.0.0.0 in here is NOT publicly exposed — the
#                      container is still firewalled by Docker / your VPC.
#                      Using 127.0.0.1 would make the app unreachable from
#                      outside the container.
#   --port 8000      → matches EXPOSE above.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
