# =============================================================================
#  Nginx image — official Nginx + Brotli (dynamic modules), production hardened
# -----------------------------------------------------------------------------
#  Multi-stage:
#    stage "modules": compile ngx_brotli as DYNAMIC modules against the EXACT
#                     same Nginx version as the runtime image (ABI must match).
#    stage "runtime": official nginx:<ver> + the .so modules + tooling
#                     (curl, envsubst, openssl) + our entrypoint.
#
#  HTTP/2, gzip and Brotli are always available. HTTP/3 (QUIC) is enabled at
#  runtime only if the nginx binary advertises http_v3 support (see entrypoint);
#  otherwise the stack cleanly falls back to HTTP/2.
# =============================================================================

ARG NGINX_VERSION=1.27.4

# ----- Stage 1: build Brotli dynamic modules ---------------------------------
FROM nginx:${NGINX_VERSION} AS modules
ARG NGINX_VERSION

# Toolchain + the headers Nginx was configured with (mirrored via `nginx -V`).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential git ca-certificates wget \
        libpcre2-dev zlib1g-dev libssl-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
# Matching Nginx source (only used to compile compatible dynamic modules).
RUN set -eux; \
    wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    tar xzf "nginx-${NGINX_VERSION}.tar.gz"; \
    git clone --depth 1 --recurse-submodules https://github.com/google/ngx_brotli.git

# --with-compat is REQUIRED so the resulting .so loads into the official binary.
RUN set -eux; \
    cd "nginx-${NGINX_VERSION}"; \
    ./configure --with-compat --add-dynamic-module=../ngx_brotli; \
    make -j"$(nproc)" modules; \
    mkdir -p /modules; \
    cp objs/ngx_http_brotli_filter_module.so /modules/; \
    cp objs/ngx_http_brotli_static_module.so /modules/

# ----- Stage 2: runtime ------------------------------------------------------
FROM nginx:${NGINX_VERSION} AS runtime

# Informational: real HTTP/3 needs a QUIC-enabled nginx binary. The official
# image (used here) ships HTTP/2 + (compiled-in) compression; the entrypoint
# auto-detects http_v3 support and only enables QUIC when present. To get HTTP/3,
# rebuild FROM a QUIC base image (e.g. a macbre/nginx-http3 tag) — config is ready.
ARG BUILD_HTTP3=false

# Runtime tooling: curl (healthcheck), gettext-base (envsubst for templating),
# openssl (self-signed bootstrap cert), tzdata.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        curl gettext-base openssl tzdata; \
    rm -rf /var/lib/apt/lists/*

# Brotli dynamic modules compiled in stage 1.
COPY --from=modules /modules/ /etc/nginx/modules/

# Our hook: render templates, bootstrap TLS, background cert-reload loop.
# The official image's docker-entrypoint.sh runs every executable in
# /docker-entrypoint.d/ (sorted) and THEN execs nginx, so 99- runs last.
COPY scripts/nginx-entrypoint.sh /docker-entrypoint.d/99-maplibre.sh
RUN chmod +x /docker-entrypoint.d/99-maplibre.sh

# Writable dirs for cache + runtime config (rendered) + ACME webroot.
RUN mkdir -p /var/cache/nginx /etc/nginx/conf.d /var/www/certbot \
             /etc/nginx/ssl /var/log/nginx; \
    # log to stdout/stderr is configured in nginx.conf; keep dir for buffers.
    chown -R nginx:nginx /var/cache/nginx /var/www/certbot /etc/nginx/ssl

# We keep the official image's docker-entrypoint.sh (it runs everything in
# /docker-entrypoint.d/ then execs nginx). Our 99-maplibre.sh hooks in there.
EXPOSE 80 443 443/udp
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=15s --timeout=5s --retries=5 --start-period=15s \
  CMD curl -fsS http://localhost/healthz || exit 1
