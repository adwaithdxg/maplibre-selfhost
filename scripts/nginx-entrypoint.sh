#!/usr/bin/env sh
# =============================================================================
#  nginx-entrypoint.sh — runs as /docker-entrypoint.d/99-maplibre.sh
# -----------------------------------------------------------------------------
#  Executed by the official Nginx image entrypoint BEFORE it execs nginx:
#    1. Render nginx.conf + conf.d from templates (env-driven).
#    2. Pick HTTP-only or HTTPS server blocks based on ENABLE_SSL.
#    3. Bootstrap a self-signed cert so HTTPS can start before Let's Encrypt
#       has issued the real one (certbot replaces it; we reload to pick it up).
#    4. Start a background loop that reloads Nginx periodically so renewed
#       certificates are loaded with zero downtime.
#  It must RETURN (not exec) so the parent entrypoint can start Nginx.
# =============================================================================
set -eu

TPL=/etc/nginx/templates-src
OUT_CONFD=/etc/nginx/conf.d
SNIP=/etc/nginx/snippets

DOMAIN="${DOMAIN:-}"
ENABLE_SSL="${ENABLE_SSL:-true}"
ENABLE_HTTP3="${ENABLE_HTTP3:-false}"
NGINX_TILE_CACHE_MAX="${NGINX_TILE_CACHE_MAX:-20g}"
NGINX_TILE_CACHE_TTL="${NGINX_TILE_CACHE_TTL:-30d}"
NGINX_RATE_LIMIT="${NGINX_RATE_LIMIT:-50r/s}"
NGINX_RATE_BURST="${NGINX_RATE_BURST:-100}"

log() { printf '%s [nginx-init] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

# Server name: real domain, or "_" (catch-all) for IP-only deployments.
if [ -n "${DOMAIN}" ] && [ "${DOMAIN}" != "localhost" ]; then
  SERVER_NAME="${DOMAIN}"
else
  SERVER_NAME="_"
fi

# Detect whether this nginx binary actually supports HTTP/3 (QUIC).
HAVE_HTTP3="false"
if nginx -V 2>&1 | grep -q -- '--with-http_v3_module'; then
  HAVE_HTTP3="true"
fi
USE_HTTP3="false"
if [ "${ENABLE_HTTP3}" = "true" ] && [ "${HAVE_HTTP3}" = "true" ]; then
  USE_HTTP3="true"
  log "HTTP/3 (QUIC) enabled"
elif [ "${ENABLE_HTTP3}" = "true" ]; then
  log "HTTP/3 requested but this nginx build lacks http_v3; falling back to HTTP/2"
fi

mkdir -p "${OUT_CONFD}" "${SNIP}" /etc/nginx/ssl

# ---- Render main nginx.conf + static snippets -------------------------------
export NGINX_TILE_CACHE_MAX NGINX_TILE_CACHE_TTL NGINX_RATE_LIMIT
envsubst '${NGINX_TILE_CACHE_MAX} ${NGINX_RATE_LIMIT}' \
  < "${TPL}/nginx.conf" > /etc/nginx/nginx.conf

# Snippets are static; copy verbatim.
cp -f "${TPL}/snippets/"*.conf "${SNIP}/" 2>/dev/null || true
# Upstream definition is static; copy verbatim.
cp -f "${TPL}/conf.d/upstream.conf" "${OUT_CONFD}/upstream.conf"

# The shared location block (templated cache TTL + rate-limit burst).
export NGINX_TILE_CACHE_TTL NGINX_RATE_BURST
envsubst '${NGINX_TILE_CACHE_TTL} ${NGINX_RATE_BURST}' \
  < "${TPL}/conf.d/locations.conf.template" > "${SNIP}/locations.conf"

# ---- TLS bootstrap ----------------------------------------------------------
CERT_BASE="/etc/letsencrypt/live/${DOMAIN:-default}"
SSL_CERT="${CERT_BASE}/fullchain.pem"
SSL_KEY="${CERT_BASE}/privkey.pem"

if [ "${ENABLE_SSL}" = "true" ]; then
  if [ ! -f "${SSL_CERT}" ] || [ ! -f "${SSL_KEY}" ]; then
    log "no certificate found -> generating temporary self-signed cert at ${CERT_BASE}"
    mkdir -p "${CERT_BASE}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "${SSL_KEY}" -out "${SSL_CERT}" \
      -subj "/CN=${DOMAIN:-localhost}" >/dev/null 2>&1
    # Marker tells certbot this is a placeholder it may replace.
    touch "${CERT_BASE}/.selfsigned"
  fi
fi

# ---- Render server blocks ---------------------------------------------------
export SERVER_NAME SSL_CERT SSL_KEY
if [ "${ENABLE_SSL}" = "true" ]; then
  # Port 80: ACME + redirect to HTTPS.
  envsubst '${SERVER_NAME}' \
    < "${TPL}/conf.d/server-http-redirect.conf.template" \
    > "${OUT_CONFD}/server-http.conf"
  # Port 443: full TLS server.
  envsubst '${SERVER_NAME} ${SSL_CERT} ${SSL_KEY}' \
    < "${TPL}/conf.d/server-https.conf.template" \
    > "${OUT_CONFD}/server-https.conf"
  # Activate QUIC/HTTP3 listener + Alt-Svc only when the build supports it.
  if [ "${USE_HTTP3}" = "true" ]; then
    sed -i 's/#__HTTP3__//g' "${OUT_CONFD}/server-https.conf"
  fi
else
  # No TLS: serve the app directly on port 80.
  envsubst '${SERVER_NAME}' \
    < "${TPL}/conf.d/server-http-serve.conf.template" \
    > "${OUT_CONFD}/server-http.conf"
fi

# ---- Validate the rendered configuration before handing back to nginx -------
if ! nginx -t; then
  log "ERROR: rendered nginx configuration failed validation"
  exit 1
fi
log "configuration rendered and validated (ssl=${ENABLE_SSL}, http3=${USE_HTTP3})"

# ---- Background: watch the certificate and reload on change -----------------
# Checks the cert fingerprint every 60s. When certbot replaces the bootstrap
# self-signed cert (or renews), Nginx reloads within a minute, zero downtime.
if [ "${ENABLE_SSL}" = "true" ]; then
  (
    LAST=""
    while true; do
      sleep 60
      [ -f "${SSL_CERT}" ] || continue
      CUR="$(md5sum "${SSL_CERT}" 2>/dev/null | awk '{print $1}')"
      if [ -n "${CUR}" ] && [ "${CUR}" != "${LAST}" ]; then
        if [ -n "${LAST}" ] && nginx -t >/dev/null 2>&1; then
          nginx -s reload >/dev/null 2>&1 && log "reloaded after certificate change"
        fi
        LAST="${CUR}"
      fi
    done
  ) &
fi

log "init complete; handing control back to nginx"
