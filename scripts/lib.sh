#!/usr/bin/env bash
# =============================================================================
#  lib.sh — shared helpers sourced by every pipeline script.
#  Provides: structured logging, retries, atomic download with resume + md5,
#  and small guard utilities. Pure bash + coreutils + curl.
# =============================================================================

# Colourless, timestamped, level-tagged logging to stderr (so stdout stays
# clean for any captured command output).
_log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${level}" "$*" >&2
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
die()       { log_error "$@"; exit 1; }

# Retry a command up to N times with linear backoff.
#   retry <attempts> <sleep_seconds> <command...>
retry() {
  local -i attempts="$1"; shift
  local -i delay="$1"; shift
  local -i n=1
  until "$@"; do
    if (( n >= attempts )); then
      log_error "command failed after ${attempts} attempts: $*"
      return 1
    fi
    log_warn "attempt ${n}/${attempts} failed; retrying in ${delay}s: $*"
    sleep "$(( delay * n ))"
    (( n++ ))
  done
  return 0
}

# Download a URL to a destination with resume (-C -) and retries. Idempotent:
# a fully-downloaded, verified file is left untouched by callers.
#   download_file <url> <dest>
download_file() {
  local url="$1" dest="$2"
  log_info "downloading ${url}"
  retry 5 10 curl -fL --connect-timeout 30 --retry 3 \
        -C - -o "${dest}" "${url}"
}

# Try a list of mirror URLs until one succeeds. Returns 0 on first success.
#   download_first <dest> <url1> [url2 ...]
download_first() {
  local dest="$1"; shift
  local url
  for url in "$@"; do
    if curl -fL --connect-timeout 20 --retry 2 -o "${dest}" "${url}"; then
      log_info "fetched ${dest##*/} from ${url}"
      return 0
    fi
    log_warn "mirror failed: ${url}"
  done
  return 1
}

# Verify a file against an expected md5 hash (first whitespace-delimited field
# of a .md5 sidecar, e.g. Geofabrik's "<hash>  <name>" format).
#   verify_md5 <file> <expected_hash>
verify_md5() {
  local file="$1" expected="$2" actual
  actual="$(md5sum "${file}" | awk '{print $1}')"
  if [[ "${actual}" == "${expected}" ]]; then
    log_info "md5 OK: ${file##*/}"
    return 0
  fi
  log_warn "md5 MISMATCH for ${file##*/}: got ${actual}, expected ${expected}"
  return 1
}

# True if $1 is newer than $2, OR $2 is missing.
newer_than() { [[ ! -e "$2" || "$1" -nt "$2" ]]; }

# Normalise a Geofabrik region key (e.g. "asia/gcc-states") into a safe
# local filename stem (e.g. "asia_gcc-states").
region_stem() { echo "$1" | tr '/' '_'; }
