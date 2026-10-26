# syntax=docker/dockerfile:1.7
#
# Base image pinned to an exact patch tag. For production, pin by digest too:
#   python:3.12.12-slim-bookworm@sha256:<digest>
# No HEALTHCHECK: Kubernetes startup/liveness/readiness probes own health.
# checkov:skip=CKV_DOCKER_2:Health is checked by Kubernetes probes, not Docker

# --- build stage: install dependencies into an isolated prefix ---------------------
FROM python:3.12.12-slim-bookworm AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

# Amazon RDS CA bundle (over HTTPS), used for sslmode=verify-full.
RUN mkdir -p /build/certs \
 && python -c "import urllib.request; urllib.request.urlretrieve('https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem', '/build/certs/rds-global-bundle.pem')" \
 && grep -q "BEGIN CERTIFICATE" /build/certs/rds-global-bundle.pem

# --- runtime stage ---------------------------------------------------------------
FROM python:3.12.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# Unprivileged user with a fixed UID that matches runAsUser in the manifest.
# pip/setuptools are removed from the runtime image to shrink the CVE surface.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
 && (pip uninstall -y pip setuptools wheel || true)

COPY --from=build /install /usr/local
# Code and certs are owned by root and read-only to the app user.
COPY --from=build --chmod=0444 /build/certs/rds-global-bundle.pem /app/certs/rds-global-bundle.pem
COPY --chmod=0444 app.py /app/app.py

WORKDIR /app
USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["python", "/app/app.py"]
