# =============================================================================
#  Generator image — OSM download + merge + Planetiler tile generation
# -----------------------------------------------------------------------------
#  Multi-stage:
#    stage "fetch"  : pull the pinned Planetiler fat-jar (cached layer)
#    stage "runtime": JRE + osmium-tool + jq + curl, non-root, tiny surface
# =============================================================================

# ----- Stage 1: fetch Planetiler ---------------------------------------------
FROM debian:bookworm-slim AS fetch

# Use the "latest" GitHub release by default (always resolvable). Override with
#   --build-arg PLANETILER_URL=.../planetiler.jar   to pin an exact version.
ARG PLANETILER_URL="https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    curl -fL --retry 5 --retry-delay 5 -o /planetiler.jar "${PLANETILER_URL}"; \
    test -s /planetiler.jar

# ----- Stage 2: runtime ------------------------------------------------------
FROM eclipse-temurin:21-jre-jammy AS runtime

# Tools:
#   osmium-tool  - merge multiple OSM extracts
#   jq           - validate the rendered style JSON
#   gettext-base - provides `envsubst` (REQUIRED by prepare-assets.sh; its
#                  absence was a cause of the generator exiting 1)
#   curl         - downloads, unzip - archives, tini - clean PID 1 signals
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        osmium-tool jq gettext-base curl ca-certificates unzip tini; \
    rm -rf /var/lib/apt/lists/*

# Planetiler fat-jar from the fetch stage.
COPY --from=fetch /planetiler.jar /opt/planetiler/planetiler.jar

# Create the data mountpoints. This is a transient, run-once batch job (it
# exits before any network-facing service starts), so it runs as root to avoid
# the named-volume ownership pitfalls entirely — it must be able to write the
# tiles/assets/downloads volumes regardless of how Docker initialised them.
# The long-lived, internet-facing services (martin, nginx) remain non-root.
RUN mkdir -p /data/downloads /data/tiles /data/assets

ENV PLANETILER_JAR=/opt/planetiler/planetiler.jar \
    JAVA_TOOL_OPTIONS=""

WORKDIR /data

# tini -> our idempotent pipeline script. The script is bind-mounted at runtime
# so it can be patched without rebuilding the image.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash", "/opt/scripts/generate-tiles.sh"]
