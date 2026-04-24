#!/usr/bin/env bash
# fleet-sync.sh — pull per-host config from the fleet-sync server, validate,
# apply atomically, reload service, ping healthcheck.
#
# Invoked by fleet-sync.service (oneshot), scheduled by fleet-sync.timer.
# Can also be run by hand for immediate sync.
#
# Config layout:
#   /etc/fleet-sync/client.conf   — bash-sourced: SERVER_URL, TOKEN_FILE, HOSTNAME override
#   /etc/fleet-sync/token         — mode 0400, bearer token, single line
#   /etc/fleet-sync/manifest.d/*.manifest — one per service, line format:
#       <src-path>  <dst-path>  [validate|reload|healthcheck:<key>]
#     where __HOST__ in src-path is replaced with the host identity.
#
# Per-service manifests are pulled and applied independently. A single
# service's failure does not block others. Validation errors abort that
# service's apply (old files stay in place).

set -euo pipefail

CONF=${FLEET_SYNC_CONF:-/etc/fleet-sync/client.conf}
MANIFEST_DIR=${FLEET_SYNC_MANIFESTS:-/etc/fleet-sync/manifest.d}
STAGING_DIR=${FLEET_SYNC_STAGING:-/var/lib/fleet-sync/staging}
BACKUP_DIR=${FLEET_SYNC_BACKUPS:-/var/lib/fleet-sync/backups}

if [[ ! -r "$CONF" ]]; then
  echo "fleet-sync: config $CONF missing or unreadable" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$CONF"

: "${SERVER_URL:?SERVER_URL must be set in $CONF}"
: "${TOKEN_FILE:=/etc/fleet-sync/token}"
HOST=${HOSTNAME_OVERRIDE:-$(hostname -s)}

if [[ ! -r "$TOKEN_FILE" ]]; then
  echo "fleet-sync: token file $TOKEN_FILE missing or unreadable" >&2
  exit 2
fi
TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")

mkdir -p "$STAGING_DIR" "$BACKUP_DIR"

log() {
  # journald captures stdout; add a tag so it's greppable.
  echo "fleet-sync[$HOST]: $*"
}

fetch() {
  # $1 = server path, $2 = destination local path. Returns 0 on success.
  local src=$1 dst=$2
  local tmp
  tmp=$(mktemp "${dst}.XXXXXX")
  if curl --fail --silent --show-error \
       --max-time 30 \
       -H "Authorization: Bearer $TOKEN" \
       -o "$tmp" \
       "$SERVER_URL/$src"; then
    mv "$tmp" "$dst"
    return 0
  else
    local rc=$?
    rm -f "$tmp"
    log "fetch failed src=$src rc=$rc"
    return $rc
  fi
}

apply_service() {
  # Apply one manifest file. Returns 0 on success, non-zero on any failure.
  local manifest=$1
  local service
  service=$(basename "$manifest" .manifest)
  local svc_stage="$STAGING_DIR/$service"
  local svc_backup="$BACKUP_DIR/$service.$(date +%s)"

  log "service=$service manifest=$manifest"

  rm -rf "$svc_stage"
  mkdir -p "$svc_stage"

  local -a pairs=()
  local validate_cmd="" reload_cmd="" healthcheck_url=""

  # Pass 1: parse manifest.
  while IFS= read -r raw; do
    # Strip comments and blank lines.
    local line=${raw%%#*}
    line=${line#"${line%%[![:space:]]*}"}  # ltrim
    line=${line%"${line##*[![:space:]]}"}  # rtrim
    [[ -z $line ]] && continue

    if [[ $line == validate:* ]]; then
      validate_cmd=${line#validate:}
      continue
    fi
    if [[ $line == reload:* ]]; then
      reload_cmd=${line#reload:}
      continue
    fi
    if [[ $line == healthcheck:* ]]; then
      healthcheck_url=${line#healthcheck:}
      continue
    fi

    # File line: <src>  <dst>
    # shellcheck disable=SC2206
    local parts=($line)
    if [[ ${#parts[@]} -ne 2 ]]; then
      log "ignoring malformed line: $line"
      continue
    fi
    local src=${parts[0]//__HOST__/$HOST}
    local dst=${parts[1]}
    pairs+=("$src|$dst")
  done < "$manifest"

  if [[ ${#pairs[@]} -eq 0 ]]; then
    log "service=$service no files in manifest — skipping"
    return 0
  fi

  # Pass 2: fetch everything into staging.
  local pair src dst stage_path
  for pair in "${pairs[@]}"; do
    src=${pair%%|*}
    dst=${pair##*|}
    stage_path="$svc_stage/$(echo "$dst" | sed 's|/|__|g')"
    if ! fetch "$src" "$stage_path"; then
      log "service=$service fetch failed; aborting apply"
      return 1
    fi
  done

  # Pass 3: validate in staging.
  if [[ -n $validate_cmd ]]; then
    log "service=$service running validate"
    if ! FLEET_STAGE="$svc_stage" FLEET_HOST="$HOST" bash -c "$validate_cmd"; then
      log "service=$service validate FAILED; aborting apply"
      return 1
    fi
  fi

  # Pass 4: snapshot current files to backup, then atomic replace.
  mkdir -p "$svc_backup"
  for pair in "${pairs[@]}"; do
    dst=${pair##*|}
    if [[ -f $dst ]]; then
      cp -p "$dst" "$svc_backup/$(echo "$dst" | sed 's|/|__|g')"
    fi
  done

  for pair in "${pairs[@]}"; do
    dst=${pair##*|}
    stage_path="$svc_stage/$(echo "$dst" | sed 's|/|__|g')"
    mkdir -p "$(dirname "$dst")"
    mv "$stage_path" "$dst"
  done

  # Pass 5: reload service.
  if [[ -n $reload_cmd ]]; then
    log "service=$service running reload"
    if ! bash -c "$reload_cmd"; then
      log "service=$service reload FAILED; rolling back"
      for pair in "${pairs[@]}"; do
        dst=${pair##*|}
        local backup_path="$svc_backup/$(echo "$dst" | sed 's|/|__|g')"
        [[ -f $backup_path ]] && cp -p "$backup_path" "$dst"
      done
      log "service=$service rolled back"
      return 1
    fi
  fi

  # Pass 6: ping healthcheck if provided.
  if [[ -n $healthcheck_url ]]; then
    curl --silent --max-time 10 --retry 3 "$healthcheck_url" > /dev/null || true
  fi

  log "service=$service applied OK"
  return 0
}

main() {
  shopt -s nullglob
  local manifests=("$MANIFEST_DIR"/*.manifest)
  if [[ ${#manifests[@]} -eq 0 ]]; then
    log "no manifests under $MANIFEST_DIR"
    return 0
  fi

  local failures=0
  for manifest in "${manifests[@]}"; do
    if ! apply_service "$manifest"; then
      failures=$((failures + 1))
    fi
  done

  # Retention: keep last 10 backups per service.
  for svc_dir in "$BACKUP_DIR"/*; do
    [[ -d $svc_dir ]] || continue
    # shellcheck disable=SC2012
    ls -1tr "$svc_dir" 2>/dev/null | head -n -10 | while read -r old; do
      rm -rf "${svc_dir:?}/$old"
    done
  done

  if [[ $failures -gt 0 ]]; then
    log "completed with $failures failure(s)"
    return 1
  fi
  log "all services applied OK"
  return 0
}

main "$@"
