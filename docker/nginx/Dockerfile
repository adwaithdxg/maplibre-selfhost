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

# Pin ngx_brotli to a known-good commit for fully reproducible builds.
ARG NGX_BROTLI_COMMIT=a71f9312c2deb28875acc7bacfdd5695a111aa53

# Toolchain. NOTE: `cmake` is required — modern ngx_brotli ships the Brotli
# library as a submodule that MUST be compiled (with CMake) before `make
# modules`. Omitting this is what caused the previous "exit code 2" failure.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates wget \
        libpcre2-dev zlib1g-dev libssl-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Fetch the EXACT nginx source that matches THIS base image (derived from
# `nginx -v`), so the dynamic module is always ABI-compatible — no version
# guessing, no "module is not binary compatible" at startup. Then fetch
# ngx_brotli at the pinned commit with its Brotli submodule.
RUN set -eux; \
    NGINX_SRC="$(nginx -v 2>&1 | sed -e 's@.*nginx/@@' -e 's@ .*@@')"; \
    echo "Building Brotli modules for nginx ${NGINX_SRC}"; \
    wget -q "https://nginx.org/download/nginx-${NGINX_SRC}.tar.gz"; \
    tar xzf "nginx-${NGINX_SRC}.tar.gz"; \
    mv "nginx-${NGINX_SRC}" nginx-src; \
    git clone https://github.com/google/ngx_brotli.git; \
    cd ngx_brotli; \
    git checkout "${NGX_BROTLI_COMMIT}"; \
    git submodule update --init --recursive

# Step 1: build the bundled Brotli static libraries with CMake.
# (-O2 -fPIC only — no -march=native, so the image stays portable across CPUs.)
RUN set -eux; \
    cd /build/ngx_brotli/deps/brotli; \
    mkdir -p out; cd out; \
    cmake -DCMAKE_BUILD_TYPE=Release \
          -DBUILD_SHARED_LIBS=OFF \
          -DCMAKE_C_FLAGS="-O2 -fPIC" \
          -DCMAKE_INSTALL_PREFIX=./installed ..; \
    cmake --build . --config Release --target brotlienc brotlidec brotlicommon

# Step 2: compile the dynamic modules against the matching nginx source.
# --with-compat is REQUIRED so the .so loads into the official nginx binary.
RUN set -eux; \
    cd /build/nginx-src; \
    ./configure --with-compat --add-dynamic-module=/build/ngx_brotli; \
    make -j"$(nproc)" modules; \
    mkdir -p /modules; \
    install -m 0644 objs/ngx_http_brotli_filter_module.so /modules/; \
    install -m 0644 objs/ngx_http_brotli_static_module.so /modules/

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
