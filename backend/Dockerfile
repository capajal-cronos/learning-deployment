# =============================================================================
# Backend Dockerfile — FastAPI
# =============================================================================
# WHY multi-stage build?
#   1. The build stage installs compilers and dev tools.
#   2. The final stage copies only the installed packages.
#   3. Smaller final image  →  faster deploys, smaller attack surface.
# =============================================================================

# ---- Stage 1: builder ----
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Install Python deps into a wheel cache.
COPY requirements.txt .
RUN pip install --upgrade pip && pip wheel --wheel-dir /wheels -r requirements.txt


# ---- Stage 2: runtime ----
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Create a non-root user — security best practice.
# WHY: if the container is ever compromised, the attacker is not root inside.
RUN useradd --create-home --shell /bin/bash app
WORKDIR /app

# Copy wheels from builder and install (no compilers needed here).
COPY --from=builder /wheels /wheels
COPY requirements.txt .
RUN pip install --no-index --find-links=/wheels -r requirements.txt && rm -rf /wheels

# Copy source code.
COPY app ./app

USER app

EXPOSE 8000

# A simple health-check the container runtime can use.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz').status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
