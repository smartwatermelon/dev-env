#!/bin/bash
# Keep agentro's ACLs on the owner's home current. Runs as the owner; deny pass every run, allow pass daily.
#   sweep.sh [--full | --deny-only]
set -u
unset CDPATH

FIND_BIN="${FIND_BIN:-/usr/bin/find}"
CHMOD_BIN="${CHMOD_BIN:-/bin/chmod}"
ID_BIN="${ID_BIN:-/usr/bin/id}"
MV_BIN="${MV_BIN:-/bin/mv}"
DATE_BIN="${DATE_BIN:-/bin/date}"
REALPATH_BIN="${REALPATH_BIN:-/bin/realpath}"
TOUCH_BIN="${TOUCH_BIN:-/usr/bin/touch}"

here="${BASH_SOURCE[0]%/*}"
[ "${here}" != "${BASH_SOURCE[0]}" ] || here="."
# shellcheck source=SCRIPTDIR/config.sh
. "${here}/config.sh" || {
  echo "sweep: cannot read ${here}/config.sh" >&2
  exit 1
}

H="${AGENT_RO_OWNER_HOME}"
mode="auto"
case "${1:-}" in
  "") ;;
  --full) mode="full" ;;
  --deny-only) mode="deny" ;;
  *)
    echo "sweep: unknown option: $1 (use --full or --deny-only)" >&2
    exit 2
    ;;
esac

me=$("${ID_BIN}" -un) || exit 1
if [ "${me}" != "${AGENT_RO_OWNER}" ]; then
  echo "sweep: run as ${AGENT_RO_OWNER}, not ${me}" >&2
  exit 1
fi
[ -d "${H}" ] || {
  echo "sweep: no home folder ${H}" >&2
  exit 1
}

mkdir -p "${AGENT_RO_STATE_DIR}" "${AGENT_RO_LOG%/*}" || exit 1
# Keep the log small: one old copy, about 1 MB each.
if [ -f "${AGENT_RO_LOG}" ]; then
  size=$(wc -c <"${AGENT_RO_LOG}")
  if [ "${size}" -gt 1048576 ]; then "${MV_BIN}" -f "${AGENT_RO_LOG}" "${AGENT_RO_LOG}.1"; fi
fi
errs="${AGENT_RO_STATE_DIR}/last-errors"

log() {
  local ts
  ts=$("${DATE_BIN}" '+%Y-%m-%dT%H:%M:%S%z')
  printf '%s %s\n' "${ts}" "$*" >>"${AGENT_RO_LOG}"
}

# apply_tree ROOT STAMP [prune...]: DIR_ACES/FILE_ACES on owner-owned non-symlinks, only if changed after STAMP.
apply_tree() {
  local root="$1" stamp="$2"
  shift 2
  local -a args=("${root}" -xdev)
  local p a n=0
  if [ "$#" -gt 0 ]; then
    args+=("(")
    for p in "$@"; do
      if [ "${n}" -gt 0 ]; then args+=("-o"); fi
      n=$((n + 1))
      args+=("-path" "${p}")
    done
    args+=(")" -prune -o)
  fi
  args+=("!" -type l -user "${AGENT_RO_OWNER}")
  if [ -n "${stamp}" ]; then args+=(-cnewer "${stamp}"); fi
  args+=("(" -type d)
  for a in "${DIR_ACES[@]}"; do args+=(-exec "${CHMOD_BIN}" +a "${a}" {} +); done
  args+=(-o -type f)
  for a in "${FILE_ACES[@]}"; do args+=(-exec "${CHMOD_BIN}" +a "${a}" {} +); done
  args+=(")")
  "${FIND_BIN}" "${args[@]}" 2>>"${errs}"
}

# num FILE: the number in FILE, or 0.
num() {
  local v
  v=$(cat "$1" 2>/dev/null || echo 0)
  case "${v}" in '' | *[!0-9]*) v=0 ;; *) ;; esac
  echo "${v}"
}

: >"${errs}"
rc=0
start=${SECONDS}

now=$("${DATE_BIN}" +%s)
need_full=0
if [ "${mode}" = full ]; then
  need_full=1
elif [ "${mode}" = auto ]; then
  last=$(num "${AGENT_RO_STATE_DIR}/last-full")
  if [ $((now - last)) -ge "${AGENT_RO_FULL_SWEEP_S}" ]; then need_full=1; fi
fi

if [ "${need_full}" = 1 ]; then
  skip=()
  for rel in "${AGENT_RO_SWEEP_SKIP[@]}" "${AGENT_RO_DENY[@]}"; do skip+=("${H}/${rel}"); done
  # Read, plus explicit no-write: a world-writable entry must not become writable for agentro.
  DIR_ACES=("${AGENT_RO_ALLOW_DIR}" "${AGENT_RO_NOWRITE_DIR}")
  FILE_ACES=("${AGENT_RO_ALLOW_FILE}" "${AGENT_RO_NOWRITE_FILE}")
  # Whole walk only at install (no stamp) or on --full: each chmod +a bumps a file's ctime,
  # and git, watchers and backups rescan on that.
  st="${AGENT_RO_STATE_DIR}/allow-stamp"
  if [ "${mode}" = full ] || [ ! -f "${st}" ]; then st=""; fi
  apply_tree "${H}" "${st}" "${skip[@]}" || rc=1
  # Stamp even on errors, or a TCC-blocked folder turns every run into a full walk.
  echo "${now}" >"${AGENT_RO_STATE_DIR}/last-full"
  # Stamp AFTER the pass: its own chmods change ctime, and must not count as changes.
  "${TOUCH_BIN}" "${AGENT_RO_STATE_DIR}/allow-stamp"
fi

# Deny pass, after the allow pass so it always has the last word.
DIR_ACES=("${AGENT_RO_DENY_DIR}")
FILE_ACES=("${AGENT_RO_DENY_FILE}")
st="${AGENT_RO_STATE_DIR}/deny-stamp"
if [ "${mode}" = full ] || [ ! -f "${st}" ]; then st=""; fi
RH=$("${REALPATH_BIN}" "${H}" 2>/dev/null) || RH="${H}"
deny_rc=0
for rel in "${AGENT_RO_DENY[@]}"; do
  p="${H}/${rel}"
  if [ -L "${p}" ]; then
    # Dotfiles often link credential files from a repo: deny the target.
    t=$("${REALPATH_BIN}" "${p}" 2>/dev/null) || t=""
    case "${t}" in
      "${H}"/* | "${RH}"/*) p="${t}" ;;
      *)
        echo "skipped symlink ${p} -> ${t:-?} (target outside ${H}; deny it by hand)" >>"${errs}"
        rc=1
        continue
        ;;
    esac
  fi
  [ -e "${p}" ] || continue
  apply_tree "${p}" "${st}" || deny_rc=1
done
# A failed deny is retried in full next run: the stamp moves only on success.
if [ "${deny_rc}" = 0 ]; then "${TOUCH_BIN}" "${AGENT_RO_STATE_DIR}/deny-stamp"; else rc=1; fi

nerr=$(grep -c '' "${errs}" || true)
log "mode=${mode} full=${need_full} rc=${rc} errors=${nerr} seconds=$((SECONDS - start))"
exit "${rc}"
