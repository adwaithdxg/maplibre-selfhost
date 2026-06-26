#!/bin/sh
# =============================================================================
#  certbot-entrypoint.sh — Let's Encrypt issuance + auto-renewal sidecar.
# -----------------------------------------------------------------------------
#  Flow:
#    * If TLS/Let's Encrypt is not applicable (ENABLE_SSL=false, or no real
#      DOMAIN), idle forever — Nginx keeps its self-signed cert.
#    * Otherwise: wait for Nginx, replace the bootstrap self-signed cert with a
#      real certificate via the webroot (http-01) challenge, then renew every
#      12h. Nginx detects the new cert file and reloads automatically.
# =============================================================================
set -eu

DOMAIN="${DOMAIN:-}"
EMAIL="${LETSENCRYPT_EMAIL:-}"
ENABLE_SSL="${ENABLE_SSL:-true}"
STAGING="${LETSENCRYPT_STAGING:-0}"
WEBROOT="/var/www/certbot"
LIVE="/etc/letsencrypt/live/${DOMAIN}"

log() { printf '%s [certbot] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ---- Skip conditions --------------------------------------------------------
if [ "${ENABLE_SSL}" != "true" ] || [ -z "${DOMAIN}" ] || [ "${DOMAIN}" = "localhost" ]; then
  log "Let's Encrypt disabled (ENABLE_SSL=${ENABLE_SSL}, DOMAIN='${DOMAIN}'). Idling."
  # Stay alive so the restart policy doesn't flap.
  while true; do sleep 3600; done
fi

STAGING_FLAG=""
[ "${STAGING}" = "1" ] && STAGING_FLAG="--staging" && log "using Let's Encrypt STAGING environment"

EMAIL_FLAG="--register-unsafely-without-email"
[ -n "${EMAIL}" ] && EMAIL_FLAG="--email ${EMAIL}"

# ---- Wait for Nginx to be serving the ACME path -----------------------------
log "waiting for nginx to accept ACME challenges..."
i=0
until wget -q -O /dev/null "http://nginx/healthz" 2>/dev/null; do
  i=$((i + 1))
  [ "${i}" -ge 60 ] && { log "nginx not reachable after 5min; continuing anyway"; break; }
  sleep 5
done

# ---- First issuance ---------------------------------------------------------
issue_cert() {
  log "requesting certificate for ${DOMAIN}"
  certbot certonly \
    --webroot -w "${WEBROOT}" \
    -d "${DOMAIN}" \
    ${EMAIL_FLAG} \
    --agree-tos --non-interactive \
    --keep-until-expiring --expand \
    ${STAGING_FLAG}
}

if [ -f "${LIVE}/.selfsigned" ]; then
  # Remove the Nginx-generated placeholder so certbot can create a clean,
  # renewable certificate lineage at the same path.
  log "replacing bootstrap self-signed certificate with a real one"
  rm -rf "${LIVE}" \
         "/etc/letsencrypt/archive/${DOMAIN}" \
         "/etc/letsencrypt/renewal/${DOMAIN}.conf"
  if issue_cert; then
    log "certificate issued successfully"
  else
    log "ERROR: issuance failed — Nginx keeps the self-signed cert; will retry on next loop"
  fi
elif [ ! -d "${LIVE}" ]; then
  issue_cert || log "ERROR: initial issuance failed; will retry on next loop"
else
  log "existing Let's Encrypt certificate found; skipping initial issuance"
fi

# ---- Renewal loop -----------------------------------------------------------
log "entering renewal loop (every 12h)"
while true; do
  sleep 43200
  log "running certbot renew"
  certbot renew --webroot -w "${WEBROOT}" --quiet ${STAGING_FLAG} || log "renew attempt failed"
done
