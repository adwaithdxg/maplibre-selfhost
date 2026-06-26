#!/usr/bin/env bash
# =============================================================================
#  download-data.sh — fetch + verify the configured Geofabrik OSM extracts.
# -----------------------------------------------------------------------------
#  * Idempotent: skips any extract that already exists and matches its md5.
#  * Resumable: interrupted downloads continue with curl -C -.
#  * Self-verifying: every .pbf is checked against Geofabrik's .md5 sidecar.
#
#  Echoes (to STDOUT) the newline-separated list of downloaded .pbf paths so a
#  caller can capture them; all human logging goes to STDERR via lib.sh.
#
#  Env: OSM_REGIONS (space separated keys), DOWNLOADS (target dir).
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

DOWNLOADS="${DOWNLOADS:-/data/downloads}"
OSM_REGIONS="${OSM_REGIONS:-asia/gcc-states}"
BASE_URL="https://download.geofabrik.de"

mkdir -p "${DOWNLOADS}"

downloaded=()
for region in ${OSM_REGIONS}; do
  stem="$(region_stem "${region}")"
  pbf="${DOWNLOADS}/${stem}-latest.osm.pbf"
  url="${BASE_URL}/${region}-latest.osm.pbf"
  md5url="${url}.md5"

  # Fetch expected md5 (best-effort; if unavailable we still proceed but warn).
  expected=""
  if curl -fsSL --retry 2 -o "${pbf}.md5" "${md5url}" 2>/dev/null; then
    expected="$(awk '{print $1}' "${pbf}.md5")"
  else
    log_warn "could not fetch md5 sidecar for ${region}; integrity check skipped"
  fi

  # Skip if a valid copy already exists.
  if [[ -s "${pbf}" ]]; then
    if [[ -z "${expected}" ]] || verify_md5 "${pbf}" "${expected}"; then
      log_info "extract present & valid, skipping: ${region}"
      downloaded+=("${pbf}")
      echo "${pbf}"
      continue
    fi
    log_warn "existing extract failed verification, re-downloading: ${region}"
  fi

  # Download (resumable) with up to 3 verification-gated attempts.
  for attempt in 1 2 3; do
    download_file "${url}" "${pbf}" || die "download failed: ${region}"
    if [[ -z "${expected}" ]] || verify_md5 "${pbf}" "${expected}"; then
      break
    fi
    log_warn "verification failed (attempt ${attempt}); discarding partial file"
    rm -f "${pbf}"
    [[ "${attempt}" == "3" ]] && die "could not obtain a valid extract for ${region}"
  done

  downloaded+=("${pbf}")
  echo "${pbf}"
done

log_info "downloaded/validated ${#downloaded[@]} extract(s)"
