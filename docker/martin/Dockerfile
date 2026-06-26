# =============================================================================
#  Martin image — thin wrapper over the official Martin release
# -----------------------------------------------------------------------------
#  Why a wrapper instead of the bare upstream image?
#    * Adds `curl` so Compose can run a real HTTP health check on /health.
#    * Lets us pin behaviour / future-proof for extra tooling.
#  The official image is Debian-based, so apt is available. Pin the exact
#  version via MARTIN_IMAGE in .env for reproducible production builds.
# =============================================================================
ARG MARTIN_IMAGE=ghcr.io/maplibre/martin:latest
FROM ${MARTIN_IMAGE}

USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# Drop privileges. Martin only needs to read the mounted tiles/assets.
USER 1000:1000

EXPOSE 3000
# ENTRYPOINT/CMD are inherited from the upstream image; the `command:` in
# docker-compose.yml supplies `--config /config/martin.yaml`.
