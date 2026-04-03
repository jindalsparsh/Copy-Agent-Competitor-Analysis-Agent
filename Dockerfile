# ── Build stage ───────────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build

# Install build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency spec and install into an isolated prefix so we can
# copy only the installed packages to the runtime stage.
COPY pyproject.toml .
RUN pip install --upgrade pip \
    && pip install --prefix=/install ".[dev]" --no-warn-script-location

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

WORKDIR /app

# Non-root user for security
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy application source
COPY app/ ./app/

# The service account key is mounted at runtime via Docker volume or
# Kubernetes secret — do NOT bake it into the image.
# GOOGLE_APPLICATION_CREDENTIALS should point to the mounted path.

# Expose the FastAPI port
EXPOSE 8000

# Health check — matches GET /health endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

USER appuser

# Start Uvicorn with a single worker (scale via replicas, not workers,
# so each container owns its scheduler if ENABLE_SCHEDULER=true)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
