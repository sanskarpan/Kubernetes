# Multi-stage Dockerfile for Django Notes App
#
# Stage 1 (builder): installs dependencies into /install prefix
# Stage 2 (runtime): copies only the installed packages — no build toolchain in final image
#
# Benefits of multi-stage:
#   - Final image contains no pip, gcc, or build headers
#   - Significantly reduced attack surface
#   - Smaller image size (builder stage is discarded)

# ---- Stage 1: Builder ----
FROM python:3.11-slim AS builder

WORKDIR /app

# Copy only requirements first (Docker layer cache optimization)
# Rebuilding dependencies only when requirements.txt changes
COPY requirements.txt .

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- Stage 2: Runtime ----
FROM python:3.11-slim AS runtime

# Create a non-root user and group
# Running as root inside a container is a security risk even with namespacing
RUN groupadd -r appuser --gid=1000 && \
    useradd -r -g appuser --uid=1000 --no-log-init appuser

WORKDIR /app

# Copy installed Python packages from builder (no pip in final image)
COPY --from=builder /install /usr/local

# Copy application source code
COPY --chown=appuser:appuser . .

# Switch to non-root user before the final CMD
USER appuser

# Expose application port (documentation only — does not publish the port)
EXPOSE 8000

# Health check for Docker / container runtimes
# Kubernetes liveness/readiness probes are preferred in K8s environments,
# but HEALTHCHECK ensures correctness when running outside Kubernetes
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/')" || exit 1

# Use exec form (not shell form) to ensure proper signal handling
# Django's development server — replace with gunicorn in production:
# CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "4", "notesapp.wsgi:application"]
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
