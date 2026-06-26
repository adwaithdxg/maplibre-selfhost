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

# Tools: osmium-tool (merge extracts), jq (rewrite style JSON), curl (download),
# unzip (sprite archives), tini (clean PID 1 signal handling).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        osmium-tool jq curl ca-certificates unzip tini; \
    rm -rf /var/lib/apt/lists/*

# Planetiler fat-jar from the fetch stage.
COPY --from=fetch /planetiler.jar /opt/planetiler/planetiler.jar

# Non-root user. UID/GID 10001 keeps it well clear of host users; volumes are
# chowned by the entrypoint on first run.
RUN groupadd -g 10001 maptiler && \
    useradd  -u 10001 -g 10001 -m -s /usr/sbin/nologin maptiler && \
    mkdir -p /data/downloads /data/tiles /data/assets && \
    chown -R maptiler:maptiler /data /opt/planetiler

ENV PLANETILER_JAR=/opt/planetiler/planetiler.jar \
    JAVA_TOOL_OPTIONS="" \
    HOME=/home/maptiler

USER maptiler
WORKDIR /data

# tini -> our idempotent pipeline script. The script is bind-mounted at runtime
# so it can be patched without rebuilding the image.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash", "/opt/scripts/generate-tiles.sh"]
