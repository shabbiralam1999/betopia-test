# ============================================================================
# Service B — Python (FastAPI) transactional API
# Multi-stage build: build venv in a full image, ship only the venv +
# distroless Python runtime.
# ============================================================================

# ---- Stage 1: builder -------------------------------------------------------
FROM python:3.12-slim AS builder
WORKDIR /app

# Build tools live ONLY in this stage — never reach the runtime image.
RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency manifest first so this layer caches independently of
# source-code churn.
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

COPY . .

# ---- Stage 2: runtime --------------------------------------------------------
FROM gcr.io/distroless/python3-debian12:nonroot AS runtime

USER 10001:10001
WORKDIR /app

# Ship only the compiled virtualenv + app source — no compiler, no pip,
# no shell.
COPY --from=builder --chown=10001:10001 /opt/venv /opt/venv
COPY --from=builder --chown=10001:10001 /app       /app

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PORT=8081

EXPOSE 8081

# Read-only root filesystem enforced via k8s securityContext
# (see k8s/base/deployment-service-b.yaml).

ENTRYPOINT ["/opt/venv/bin/python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8081"]
