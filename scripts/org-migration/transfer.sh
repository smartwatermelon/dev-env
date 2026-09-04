#!/usr/bin/env bash
# Transfer every repo on the move list to its target org. A pre-flight checks
# that every distinct target is a real organization before any POST.
# Idempotent: a repo already owned by its target is skipped. A failed transfer
# is reported and the loop continues; exit 1 at the end if any failed.
# Usage: transfer.sh <move-list> [--only <repo>] [--dry-run]
# Design: docs/superpowers/specs/2026-09-03-org-migration-design.md, Steps 3-4.
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/org-migration/lib.sh
source "${HERE}/lib.sh"

# Poll cadence; the tests shrink both.
OM_POLL_SECONDS="${OM_POLL_SECONDS:-2}"
OM_POLL_MAX="${OM_POLL_MAX:-30}"

list=""
only=""
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      only="${2:?--only needs a repo}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -*)
      echo "transfer: unknown flag $1" >&2
      exit 2
      ;;
    *)
      list="$1"
      shift
      ;;
  esac
done
if [[ -z "${list}" ]]; then
  echo "usage: transfer.sh <move-list> [--only <repo>] [--dry-run]" >&2
  exit 2
fi

pairs="$(om_read_move_list "${list}")" || exit 1

# Pre-flight: every distinct target must already be a real organization.
# During the rename window the name `smartwatermelon` is claimable, and a
# transfer to a *user* is an invitation sent to whoever holds the name — not a
# move we could take back. Read-only and cheap, so --dry-run runs it too.
preflight_failed=0
targets="$(awk '{print $2}' <<<"${pairs}")" || exit 1
targets="$(sort -u <<<"${targets}")" || exit 1
while read -r target; do
  [[ -n "${target}" ]] || continue
  if ! target_type="$(gh api "orgs/${target}" --jq '.type' 2>/dev/null)"; then
    echo "transfer: target ${target} does not resolve as an organization; aborting" >&2
    preflight_failed=1
    continue
  fi
  if [[ "${target_type}" != "Organization" ]]; then
    echo "transfer: target ${target} is a ${target_type}, not an Organization; aborting" >&2
    preflight_failed=1
  fi
done <<<"${targets}"
if [[ "${preflight_failed}" -ne 0 ]]; then
  exit 1
fi

failed=0
seen_only=0
while read -r repo target; do
  if [[ -n "${only}" && "${repo}" != "${only}" ]]; then
    continue
  fi
  seen_only=1
  if ! current="$(om_lookup_owner "${repo}")"; then
    echo "transfer: ${repo}: cannot resolve current owner; skipping" >&2
    failed=$((failed + 1))
    continue
  fi
  # "login type", exactly two space-free fields. Anything else is unexpected
  # gh output; treat it as a lookup failure rather than POSTing garbage.
  read -r login type <<<"${current}"
  if [[ ! "${current}" =~ ^[^[:space:]]+[[:space:]][^[:space:]]+$ || -z "${login}" || -z "${type}" ]]; then
    echo "transfer: ${repo}: unexpected owner lookup result '${current}'; skipping" >&2
    failed=$((failed + 1))
    continue
  fi
  if [[ "${login,,}" == "${target,,}" && "${type}" == "Organization" ]]; then
    echo "transfer: ${repo}: already under ${target}; skip"
    continue
  fi
  if [[ "${dry_run}" -eq 1 ]]; then
    echo "transfer: DRY RUN would POST repos/${login}/${repo}/transfer new_owner=${target}"
    continue
  fi
  echo "transfer: ${repo}: ${login} (${type}) -> ${target}"
  if ! gh api -X POST "repos/${login}/${repo}/transfer" -f "new_owner=${target}" >/dev/null; then
    echo "transfer: ${repo}: POST failed; skipping" >&2
    failed=$((failed + 1))
    continue
  fi
  ok=0
  n=0
  while [[ "${n}" -lt "${OM_POLL_MAX}" ]]; do
    now_type="$(gh api "repos/${target}/${repo}" --jq '.owner.type' 2>/dev/null || true)"
    if [[ "${now_type}" == "Organization" ]]; then
      ok=1
      break
    fi
    n=$((n + 1))
    sleep "${OM_POLL_SECONDS}"
  done
  if [[ "${ok}" -eq 1 ]]; then
    echo "transfer: ${repo}: now ${target}/${repo} (Organization)"
  else
    echo "transfer: ${repo}: did not resolve under ${target} after ${OM_POLL_MAX} polls" >&2
    failed=$((failed + 1))
  fi
done <<<"${pairs}"

if [[ -n "${only}" && "${seen_only}" -eq 0 ]]; then
  echo "transfer: --only ${only}: not on the move list" >&2
  exit 1
fi
if [[ "${failed}" -gt 0 ]]; then
  echo "transfer: ${failed} repo(s) failed; re-run to retry (completed repos are skipped)" >&2
  exit 1
fi
