# =============================================================================
# Frontend Dockerfile — React (Vite build) + Express server
# =============================================================================
# Multi-stage:
#   1. `builder`  installs dev deps and runs `vite build` to produce /app/dist.
#   2. `runtime`  installs only production deps and copies the built static
#                 files in. The image stays small and free of build tools.
# =============================================================================

# ---- Stage 1: build the React app ----
FROM node:20-alpine AS builder
WORKDIR /app

# Copy manifests first so Docker can cache `npm ci` independently of source
# changes (changes to src/* do not invalidate the dependency layer).
COPY package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund

COPY . .
RUN npm run build


# ---- Stage 2: production runtime ----
FROM node:20-alpine AS runtime

ENV NODE_ENV=production
WORKDIR /app

# Only install production deps for the Express server.
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund

COPY server.js ./
COPY --from=builder /app/dist ./dist

# Non-root user — see backend/Dockerfile for the same reasoning.
RUN addgroup -S app && adduser -S app -G app
USER app

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:3000/healthz >/dev/null 2>&1 || exit 1

CMD ["node", "server.js"]
