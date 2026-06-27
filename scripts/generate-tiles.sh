#!/usr/bin/env bash
# =============================================================================
#  generate-tiles.sh — the run-once pipeline entrypoint (generator container).
# -----------------------------------------------------------------------------
#  Orchestrates the full "data -> tiles -> assets" build, fully idempotent:
#
#    1. Download + verify OSM extracts (download-data.sh)
#    2. Merge extracts into one .pbf (osmium) — or use the single extract as-is
#    3. Generate the vector tileset with Planetiler (OpenMapTiles schema)
#    4. Prepare fonts + style + demo viewer (prepare-assets.sh)
#    5. Write a completion marker
#
#  Re-running is safe: each stage is skipped when its up-to-date output exists,
#  unless FORCE_TILE_REBUILD=true. Output writes are atomic (tmp -> rename).
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

# ---- Configuration (with safe defaults) -------------------------------------
export DOWNLOADS="${DOWNLOADS:-/data/downloads}"
TILES="${TILES:-/data/tiles}"
export ASSETS="${ASSETS:-/data/assets}"
TILESET_ID="${TILESET_ID:-basemap}"
MIN_ZOOM="${MIN_ZOOM:-0}"
MAX_ZOOM="${MAX_ZOOM:-14}"
FORCE_TILE_REBUILD="${FORCE_TILE_REBUILD:-false}"
PLANETILER_XMX="${PLANETILER_XMX:-6g}"
PLANETILER_STORAGE="${PLANETILER_STORAGE:-ram}"
PLANETILER_JAR="${PLANETILER_JAR:-/opt/planetiler/planetiler.jar}"

MBTILES="${TILES}/${TILESET_ID}.mbtiles"
MERGED="${DOWNLOADS}/merged-${TILESET_ID}.osm.pbf"
DONE_MARKER="${TILES}/.${TILESET_ID}.ready"

mkdir -p "${DOWNLOADS}" "${TILES}" "${ASSETS}"

log_info "=== MapLibre tile generation pipeline starting ==="
log_info "regions=[${OSM_REGIONS:-asia/gcc-states}] tileset=${TILESET_ID} zoom=${MIN_ZOOM}-${MAX_ZOOM}"

# ---- Stage 1: download ------------------------------------------------------
mapfile -t PBF_FILES < <(bash "$(dirname "$0")/download-data.sh")
(( ${#PBF_FILES[@]} > 0 )) || die "no OSM extracts were downloaded"

# ---- Decide whether tiles need (re)building ---------------------------------
need_build=false
if [[ "${FORCE_TILE_REBUILD}" == "true" ]]; then
  log_info "FORCE_TILE_REBUILD=true -> rebuilding tiles"
  need_build=true
elif [[ ! -s "${MBTILES}" || ! -f "${DONE_MARKER}" ]]; then
  log_info "no existing tileset -> building"
  need_build=true
else
  # Rebuild if any source extract is newer than the tileset.
  for pbf in "${PBF_FILES[@]}"; do
    if newer_than "${pbf}" "${MBTILES}"; then
      log_info "source ${pbf##*/} is newer than tileset -> rebuilding"
      need_build=true
      break
    fi
  done
fi

if [[ "${need_build}" == "true" ]]; then
  # ---- Stage 2: merge (only if more than one extract) -----------------------
  if (( ${#PBF_FILES[@]} == 1 )); then
    SRC="${PBF_FILES[0]}"
    log_info "single extract -> no merge needed (${SRC##*/})"
  else
    log_info "merging ${#PBF_FILES[@]} extracts with osmium -> ${MERGED##*/}"
    retry 2 5 osmium merge --overwrite "${PBF_FILES[@]}" -o "${MERGED}"
    SRC="${MERGED}"
  fi

  # ---- Stage 3: Planetiler --------------------------------------------------
  TMP_OUT="${TILES}/.${TILESET_ID}.building.mbtiles"
  rm -f "${TMP_OUT}"
  log_info "running Planetiler (Xmx=${PLANETILER_XMX}, storage=${PLANETILER_STORAGE})"
  # Run from DOWNLOADS so Planetiler's auxiliary source downloads (water
  # polygons, Natural Earth, etc.) and tmp files persist on the cached volume.
  #
  # --download is REQUIRED: the OpenMapTiles profile needs ~1GB of extra data
  # sources (ocean polygons + Natural Earth). With --osm-path also set,
  # Planetiler keeps our OSM extract and only fetches the *missing* aux sources;
  # re-runs reuse the cache. Omitting --download was a cause of the exit-1.
  (
    cd "${DOWNLOADS}"
    java -Xmx"${PLANETILER_XMX}" -jar "${PLANETILER_JAR}" \
      --download \
      --osm-path="${SRC}" \
      --output="${TMP_OUT}" \
      --force \
      --minzoom="${MIN_ZOOM}" \
      --maxzoom="${MAX_ZOOM}" \
      --storage="${PLANETILER_STORAGE}"
  ) || die "Planetiler failed"

  [[ -s "${TMP_OUT}" ]] || die "Planetiler produced no output"
  # Atomic publish (same filesystem -> rename is atomic).
  mv -f "${TMP_OUT}" "${MBTILES}"
  log_info "tileset published: ${MBTILES} ($(du -h "${MBTILES}" | cut -f1))"
else
  log_info "tileset up to date -> skipping generation (${MBTILES})"
fi

# ---- Stage 4: assets (fonts + style + viewer) -------------------------------
bash "$(dirname "$0")/prepare-assets.sh"

# ---- Stage 5: completion marker --------------------------------------------
date -u '+%Y-%m-%dT%H:%M:%SZ' > "${DONE_MARKER}"
log_info "=== pipeline complete; marker written: ${DONE_MARKER} ==="
