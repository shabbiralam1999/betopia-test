# ============================================================================
# Service A — Node.js (Express) transactional API
# Multi-stage build: isolated build environment -> distroless runtime
# ============================================================================

# ---- Stage 1: deps ----------------------------------------------------------
# Installing deps in their own stage means this layer only invalidates when
# package.json / package-lock.json change (maximizes Docker layer caching).
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---- Stage 2: build ----------------------------------------------------------
# Full deps (incl. devDependencies) needed only to compile/transpile.
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build            # e.g. tsc -> dist/

# ---- Stage 3: runtime ----------------------------------------------------------
# Distroless nodejs image: no shell, no package manager, minimal CVE surface.
FROM gcr.io/distroless/nodejs20-debian12:nonroot AS runtime

# distroless:nonroot already runs as UID 65532, but we pin an explicit
# app UID/GID (>10000 convention) for auditability and to match k8s
# securityContext.runAsUser below.
USER 10001:10001

WORKDIR /app
COPY --from=deps  --chown=10001:10001 /app/node_modules ./node_modules
COPY --from=build --chown=10001:10001 /app/dist         ./dist
COPY --from=build --chown=10001:10001 /app/package.json ./package.json

ENV NODE_ENV=production \
    PORT=8080

EXPOSE 8080

# Read-only root filesystem is enforced at the Kubernetes securityContext
# level (see k8s/base/deployment-service-a.yaml). Nothing here writes to
# disk at runtime, so no writable volume mount is required.

ENTRYPOINT ["/nodejs/bin/node", "dist/server.js"]
