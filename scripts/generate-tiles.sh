#!/usr/bin/env bash
# =============================================================================
#  generate-tiles.sh — the run-once pipeline entrypoint (generator container).
# -----------------------------------------------------------------------------
#  Builds TWO tilesets so the map shows the whole world at overview zoom but
#  full detail only for the configured region (GCC by default):
#
#    * <TILESET_ID>.mbtiles  — detailed region, z0..MAX_ZOOM (bounds = OSM extent)
#    * world.mbtiles         — global overview, z0..WORLD_MAX_ZOOM (bounds = world)
#                              built from global Natural Earth + ocean polygons,
#                              so it covers the entire planet at low zoom. Tiny.
#
#  Pipeline (fully idempotent; re-running is safe, outputs are atomic):
#    1. Download + verify OSM extracts        (download-data.sh)
#    2. Merge extracts into one .pbf          (osmium, only if >1)
#    3. Generate detailed regional tileset    (Planetiler)
#    4. Generate global overview tileset      (Planetiler, --bounds=world)
#    5. Prepare fonts + style + viewer        (prepare-assets.sh)
#    6. Write a completion marker
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

# World overview settings.
WORLD_OVERVIEW="${WORLD_OVERVIEW:-true}"
WORLD_MAX_ZOOM="${WORLD_MAX_ZOOM:-6}"
# Web-mercator world bounds (lon/lat). Forces Planetiler to emit global tiles
# instead of clamping to the regional OSM extent.
WORLD_BOUNDS="-180,-85.05113,180,85.05113"

MBTILES="${TILES}/${TILESET_ID}.mbtiles"
WORLD_MBTILES="${TILES}/world.mbtiles"
MERGED="${DOWNLOADS}/merged-${TILESET_ID}.osm.pbf"
DONE_MARKER="${TILES}/.${TILESET_ID}.ready"

mkdir -p "${DOWNLOADS}" "${TILES}" "${ASSETS}"

log_info "=== MapLibre tile generation pipeline starting ==="
log_info "regions=[${OSM_REGIONS:-asia/gcc-states}] tileset=${TILESET_ID} zoom=${MIN_ZOOM}-${MAX_ZOOM}"
log_info "world overview=${WORLD_OVERVIEW} (z0-${WORLD_MAX_ZOOM})"

# ---- Stage 1: download ------------------------------------------------------
mapfile -t PBF_FILES < <(bash "$(dirname "$0")/download-data.sh")
(( ${#PBF_FILES[@]} > 0 )) || die "no OSM extracts were downloaded"

# ---- Decide whether the detailed tileset needs (re)building -----------------
need_build=false
if [[ "${FORCE_TILE_REBUILD}" == "true" ]]; then
  log_info "FORCE_TILE_REBUILD=true -> rebuilding tiles"
  need_build=true
elif [[ ! -s "${MBTILES}" || ! -f "${DONE_MARKER}" ]]; then
  log_info "no existing tileset -> building"
  need_build=true
else
  for pbf in "${PBF_FILES[@]}"; do
    if newer_than "${pbf}" "${MBTILES}"; then
      log_info "source ${pbf##*/} is newer than tileset -> rebuilding"
      need_build=true
      break
    fi
  done
fi

# ---- Resolve the OSM source (single extract or merged) ----------------------
# Computed unconditionally so the world build can reuse it even when the
# detailed tileset is already up to date.
if (( ${#PBF_FILES[@]} == 1 )); then
  OSM_SRC="${PBF_FILES[0]}"
else
  if [[ "${need_build}" == "true" || ! -s "${MERGED}" ]]; then
    log_info "merging ${#PBF_FILES[@]} extracts with osmium -> ${MERGED##*/}"
    retry 2 5 osmium merge --overwrite "${PBF_FILES[@]}" -o "${MERGED}"
  fi
  OSM_SRC="${MERGED}"
fi
log_info "OSM source: ${OSM_SRC##*/}"

# Helper: run Planetiler. $1=osm $2=output $3=minzoom $4=maxzoom $5=extra args
run_planetiler() {
  local osm="$1" out="$2" minz="$3" maxz="$4" extra="${5:-}"
  # Run from DOWNLOADS so Planetiler's auxiliary downloads (ocean polygons,
  # Natural Earth) and tmp files persist on the cached volume across runs.
  # --download fetches the (global) aux sources required by the OpenMapTiles
  # profile; with --osm-path set it keeps our extract and only grabs what's
  # missing.
  (
    cd "${DOWNLOADS}"
    # shellcheck disable=SC2086
    java -Xmx"${PLANETILER_XMX}" -jar "${PLANETILER_JAR}" \
      --download \
      --osm-path="${osm}" \
      --output="${out}" \
      --force \
      --minzoom="${minz}" \
      --maxzoom="${maxz}" \
      --storage="${PLANETILER_STORAGE}" \
      ${extra}
  )
}

# ---- Stage 3: detailed regional tileset -------------------------------------
if [[ "${need_build}" == "true" ]]; then
  TMP_OUT="${TILES}/.${TILESET_ID}.building.mbtiles"
  rm -f "${TMP_OUT}"
  log_info "building detailed tileset '${TILESET_ID}' (z${MIN_ZOOM}-${MAX_ZOOM})"
  run_planetiler "${OSM_SRC}" "${TMP_OUT}" "${MIN_ZOOM}" "${MAX_ZOOM}" \
    || die "Planetiler failed building the detailed tileset"
  [[ -s "${TMP_OUT}" ]] || die "Planetiler produced no detailed output"
  mv -f "${TMP_OUT}" "${MBTILES}"     # atomic publish (same filesystem)
  log_info "detailed tileset published: ${MBTILES} ($(du -h "${MBTILES}" | cut -f1))"
else
  log_info "detailed tileset up to date -> skipping (${MBTILES})"
fi

# ---- Stage 4: global overview tileset (non-fatal) ---------------------------
# Built from global Natural Earth + ocean polygons (the OSM extract only adds a
# little regional detail at low zoom). z0-WORLD_MAX_ZOOM is only a few thousand
# tiles, so this is fast and small. If it fails, we continue with region-only.
if [[ "${WORLD_OVERVIEW}" == "true" ]]; then
  if [[ "${FORCE_TILE_REBUILD}" == "true" || ! -s "${WORLD_MBTILES}" ]]; then
    WORLD_TMP="${TILES}/.world.building.mbtiles"
    rm -f "${WORLD_TMP}"
    log_info "building global overview tileset 'world' (z0-${WORLD_MAX_ZOOM}, bounds=world)"
    if run_planetiler "${OSM_SRC}" "${WORLD_TMP}" 0 "${WORLD_MAX_ZOOM}" "--bounds=${WORLD_BOUNDS}"; then
      if [[ -s "${WORLD_TMP}" ]]; then
        mv -f "${WORLD_TMP}" "${WORLD_MBTILES}"
        log_info "world overview published: ${WORLD_MBTILES} ($(du -h "${WORLD_MBTILES}" | cut -f1))"
      else
        log_warn "world overview produced no output; continuing region-only"
        rm -f "${WORLD_TMP}"
      fi
    else
      log_warn "world overview generation failed; continuing region-only"
      rm -f "${WORLD_TMP}"
    fi
  else
    log_info "world overview up to date -> skipping (${WORLD_MBTILES})"
  fi
else
  log_info "world overview disabled (WORLD_OVERVIEW=false)"
fi

# ---- Stage 5: assets (fonts + style + viewer) -------------------------------
bash "$(dirname "$0")/prepare-assets.sh"

# ---- Stage 6: completion marker --------------------------------------------
date -u '+%Y-%m-%dT%H:%M:%SZ' > "${DONE_MARKER}"
log_info "=== pipeline complete; marker written: ${DONE_MARKER} ==="
