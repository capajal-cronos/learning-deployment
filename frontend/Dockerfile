# =============================================================================
# Frontend Dockerfile — React (Vite build) + Express server
# =============================================================================
# Multi-stage build with TWO very different jobs:
#
#   Stage 1 (builder):  has dev dependencies (vite, esbuild, typescript…) and
#                       compiles the React source in src/ into a folder of
#                       plain static files (HTML / JS / CSS) under /app/dist.
#                       This stage is HEAVY — node_modules can be 300+ MB.
#
#   Stage 2 (runtime):  a fresh image with ONLY the Express server and its
#                       production deps. It serves the pre-built static
#                       files from /dist and proxies /api/* to the backend.
#                       No build tools, no source, no dev deps. Small.
#
# Why split? Same reasons as the backend Dockerfile:
#   - The browser doesn't need vite or source files — only the built bundle.
#   - Smaller runtime image → faster deploys, fewer CVEs to scan.
# =============================================================================


# ---- Stage 1: build the React app -------------------------------------------
# `node:20-alpine` = Node.js 20 on Alpine Linux. Alpine is *tiny* (~50 MB
# base vs ~350 MB for the default `node:20`). The trade-off: Alpine uses
# musl libc instead of glibc, which occasionally breaks native modules
# pre-built for glibc. For Vite + Express we're safe.
FROM node:20-alpine AS builder

WORKDIR /app

# Copy ONLY the manifests first. As long as package.json and the lockfile
# don't change, Docker reuses the cached `npm ci` layer below, even when
# src/* changes. Frontend installs are slow (hundreds of packages) — this
# trick saves minutes on every iterative rebuild.
#
# The `*` after package-lock.json makes the COPY tolerant of a missing
# lockfile (some setups commit only package.json). Docker errors out on a
# missing file without the wildcard.
COPY package.json package-lock.json* ./

# `npm ci` is the CI-friendly install: it requires a lockfile and installs
# EXACTLY the versions pinned there — no resolver surprises. The fallback
# to `npm install` only triggers when there's no lockfile to honor.
#   --no-audit  → skip the vulnerability scan (slow + noisy in CI).
#   --no-fund   → skip the "please fund me" banners.
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund

# NOW copy the rest of the source. This is the layer that changes most
# often, so we keep it cheap by putting it last in the build stage.
# .dockerignore (next to this file) keeps node_modules, .env, etc. out.
COPY . .

# `npm run build` invokes Vite, which type-checks, bundles, and minifies
# everything under src/ into /app/dist as plain static files. After this
# step, /app/dist contains everything a browser needs — no node, no react,
# no JSX. That's the whole product of this stage.
RUN npm run build


# ---- Stage 2: production runtime --------------------------------------------
# Fresh image. We're throwing away the entire builder filesystem and only
# bringing along /app/dist plus the production-only Express deps.
FROM node:20-alpine AS runtime

# NODE_ENV=production has several effects:
#   - Express skips verbose error pages (no stack traces leaked to clients).
#   - Many npm packages skip dev-only code paths.
#   - `npm install` would skip devDependencies automatically (we're not
#     relying on that — we use --omit=dev below, explicitly).
ENV NODE_ENV=production
WORKDIR /app

# Same caching trick again: manifests first, install second.
# `--omit=dev` skips everything in devDependencies (vite, eslint, vitest…)
# because the runtime only needs to RUN the server, not build the app.
# That alone cuts node_modules roughly in half.
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund

# Bring in exactly two things from the source tree + builder:
#   - server.js: the Express server that serves /dist and proxies /api.
#   - /app/dist: the static React bundle produced by stage 1.
# Crucially, we DO NOT copy src/, vite.config.js, tests/ etc. — they're not
# needed at runtime.
COPY server.js ./
COPY --from=builder /app/dist ./dist

# Create a non-root user. See backend/Dockerfile for the long version of
# why this matters. The Alpine syntax differs from Debian's `useradd`:
#   addgroup -S app     → create system group "app"
#   adduser  -S app -G app → create system user "app" in that group
# (-S means "system" — no home dir by default, no password set.)
RUN addgroup -S app && adduser -S app -G app
USER app

# Documentation hint: the Express server listens on port 3000. Actually
# publishing it to the host still requires `-p 3000:3000` or `ports:` in
# Compose.
EXPOSE 3000

# Healthcheck — Docker hits /healthz periodically and marks the container
# unhealthy on repeated failures. Alpine ships `wget` by default, so we use
# it (Alpine has no curl unless you `apk add curl`). `-qO-` = quiet, write
# to stdout — we don't care about the response body, only the exit code.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:3000/healthz >/dev/null 2>&1 || exit 1

# Default command — start the Express server. JSON-array form so SIGTERM
# reaches node directly for clean shutdown (no /bin/sh wrapper to swallow
# the signal).
CMD ["node", "server.js"]
