# ---- Stage 1: builder ----
FROM python:3.14-slim AS builder

WORKDIR /app

COPY requirements.txt .

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --no-cache-dir -r requirements.txt

# ---- Stage 2: final runtime image ----
FROM python:3.14-slim

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Non-root user
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

# Bring in the pre-built virtualenv from the builder stage
COPY --from=builder /opt/venv /opt/venv

# Security hardening: strip pip/setuptools/wheel from both the venv AND
# the base image's system Python (installed via ensurepip). They are
# build-time tools only - Gunicorn serves the app directly from the venv
# and never invokes pip at runtime. Removing them also removes pip's
# vendored msgpack copy and setuptools' own CVEs from the final image.
RUN rm -rf /opt/venv/lib/python3.14/site-packages/pip \
           /opt/venv/lib/python3.14/site-packages/pip-*.dist-info \
           /opt/venv/lib/python3.14/site-packages/setuptools \
           /opt/venv/lib/python3.14/site-packages/setuptools-*.dist-info \
           /opt/venv/lib/python3.14/site-packages/pkg_resources \
           /opt/venv/lib/python3.14/site-packages/wheel* \
           /opt/venv/bin/pip* \
           /usr/local/lib/python3.14/site-packages/pip \
           /usr/local/lib/python3.14/site-packages/pip-*.dist-info \
           /usr/local/lib/python3.14/site-packages/setuptools* \
           /usr/local/bin/pip*

# Copy only what's needed at runtime
COPY app/ ./app/
COPY run.py .
COPY healthcheck.py .

RUN chown -R appuser:appgroup /app /opt/venv

USER appuser

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "healthcheck.py"]

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "run:app"]