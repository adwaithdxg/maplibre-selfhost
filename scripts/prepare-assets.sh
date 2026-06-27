#!/usr/bin/env bash
# =============================================================================
#  prepare-assets.sh — fonts, MapLibre style, and demo viewer.
# -----------------------------------------------------------------------------
#  Produces (into the shared assets volume):
#    * fonts/   : Noto Sans (Latin) + Noto Sans Arabic TTFs -> Martin serves
#                 SDF glyphs from these (Arabic is essential for GCC labels).
#    * style/style.json : OpenMapTiles-schema style, URLs templated for this
#                 deployment. Served as a static file by Nginx.
#    * web/index.html   : a self-test MapLibre viewer.
#
#  Idempotent + resilient: a missing font CDN degrades labels but never breaks
#  tile serving. Fonts already present are not re-downloaded.
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

ASSETS="${ASSETS:-/data/assets}"
FONT_DIR="${ASSETS}/fonts"
STYLE_DIR="${ASSETS}/style"
WEB_DIR="${ASSETS}/web"
STYLE_TEMPLATE="${STYLE_TEMPLATE:-/opt/style/style.template.json}"
WEB_TEMPLATE="${WEB_TEMPLATE:-/opt/web/index.html}"

TILESET_ID="${TILESET_ID:-basemap}"
MIN_ZOOM="${MIN_ZOOM:-0}"
MAX_ZOOM="${MAX_ZOOM:-14}"
WORLD_MAX_ZOOM="${WORLD_MAX_ZOOM:-6}"
TILES_DIR="${TILES:-/data/tiles}"
WORLD_MBTILES="${TILES_DIR}/world.mbtiles"
DOMAIN="${DOMAIN:-}"
ENABLE_SSL="${ENABLE_SSL:-true}"

mkdir -p "${FONT_DIR}" "${STYLE_DIR}" "${WEB_DIR}"

# ---- Public base URL --------------------------------------------------------
# DOMAIN set  -> absolute (works cross-origin, with Nginx CORS headers).
# DOMAIN unset-> root-relative "" (portable; resolves against the serving host).
#
# IMPORTANT for cross-origin clients (e.g. a separate React app): root-relative
# URLs ("/tiles/...") only work when the map is viewed on the SAME origin as the
# server, because MapLibre resolves them against the page's origin. To serve an
# app hosted elsewhere, set PUBLIC_BASE_URL to this server's absolute base, e.g.
#   PUBLIC_BASE_URL=http://157.173.108.1   (or https://maps.example.com)
# and the style + viewer will use absolute URLs (CORS headers are already sent).
if [[ -n "${PUBLIC_BASE_URL:-}" ]]; then
  PUBLIC_URL="${PUBLIC_BASE_URL%/}"                 # explicit override wins
elif [[ -n "${DOMAIN}" && "${DOMAIN}" != "localhost" ]]; then
  if [[ "${ENABLE_SSL}" == "true" ]]; then PUBLIC_URL="https://${DOMAIN}"; else PUBLIC_URL="http://${DOMAIN}"; fi
else
  PUBLIC_URL=""
fi
log_info "asset PUBLIC_URL='${PUBLIC_URL:-<root-relative>}'"

# ---- Fonts ------------------------------------------------------------------
# name | candidate mirrors (first that works wins)
fetch_font() {
  local file="$1"; shift
  local dest="${FONT_DIR}/${file}"
  if [[ -s "${dest}" ]]; then
    log_info "font present: ${file}"
    return 0
  fi
  if download_first "${dest}" "$@"; then
    return 0
  fi
  log_warn "could not fetch font ${file}; labels using it may not render"
  rm -f "${dest}"
}

NOTO="https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts"
JSD="https://cdn.jsdelivr.net/gh/notofonts/notofonts.github.io/fonts"

fetch_font "NotoSans-Regular.ttf" \
  "${NOTO}/NotoSans/unhinted/ttf/NotoSans-Regular.ttf" \
  "${JSD}/NotoSans/unhinted/ttf/NotoSans-Regular.ttf"
fetch_font "NotoSans-Bold.ttf" \
  "${NOTO}/NotoSans/unhinted/ttf/NotoSans-Bold.ttf" \
  "${JSD}/NotoSans/unhinted/ttf/NotoSans-Bold.ttf"
fetch_font "NotoSansArabic-Regular.ttf" \
  "${NOTO}/NotoSansArabic/unhinted/ttf/NotoSansArabic-Regular.ttf" \
  "${JSD}/NotoSansArabic/unhinted/ttf/NotoSansArabic-Regular.ttf"
fetch_font "NotoSansArabic-Bold.ttf" \
  "${NOTO}/NotoSansArabic/unhinted/ttf/NotoSansArabic-Bold.ttf" \
  "${JSD}/NotoSansArabic/unhinted/ttf/NotoSansArabic-Bold.ttf"

# ---- Style ------------------------------------------------------------------
# Substitute deployment-specific values into the bundled style template.
if [[ -f "${STYLE_TEMPLATE}" ]]; then
  export PUBLIC_URL TILESET_ID MIN_ZOOM MAX_ZOOM WORLD_MAX_ZOOM
  envsubst '${PUBLIC_URL} ${TILESET_ID} ${MIN_ZOOM} ${MAX_ZOOM} ${WORLD_MAX_ZOOM}' \
    < "${STYLE_TEMPLATE}" > "${STYLE_DIR}/style.json"

  # If the global overview tileset is absent (disabled or failed to build),
  # strip the "world" source and all world-tier layers so the style still loads
  # cleanly with just the regional tileset — no 404s for /tiles/world.
  if [[ ! -s "${WORLD_MBTILES}" ]]; then
    log_warn "world.mbtiles not present -> removing world source/layers from style"
    tmp="${STYLE_DIR}/.style.tmp.json"
    jq 'del(.sources.world)
        | .layers |= map(select((.metadata."mlb:tier" // "") != "world"))' \
      "${STYLE_DIR}/style.json" > "${tmp}" && mv -f "${tmp}" "${STYLE_DIR}/style.json"
  else
    log_info "world overview tileset present -> style uses world + regional sources"
  fi

  # Validate JSON before publishing (fail loud — a broken style is useless).
  jq empty "${STYLE_DIR}/style.json" \
    || die "rendered style.json is not valid JSON"
  log_info "style published: ${STYLE_DIR}/style.json"
else
  log_warn "style template not found at ${STYLE_TEMPLATE}; skipping style render"
fi

# ---- Demo viewer ------------------------------------------------------------
if [[ -f "${WEB_TEMPLATE}" ]]; then
  export PUBLIC_URL
  envsubst '${PUBLIC_URL}' < "${WEB_TEMPLATE}" > "${WEB_DIR}/index.html"
  log_info "demo viewer published: ${WEB_DIR}/index.html"
fi

log_info "asset preparation complete"
