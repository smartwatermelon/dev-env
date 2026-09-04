#!/usr/bin/env bash
# Post-transfer verification: re-snapshot, diff against the baseline with
# owner as the only permitted change, confirm each owner is the target org,
# and ls-remote every local smartwatermelon clone. Exit 1 on any failure,
# after checking everything.
# Usage: verify.sh <move-list> <baseline-dir> <after-dir> [--clones <dir>]
# Design: docs/superpowers/specs/2026-09-03-org-migration-design.md, Step 4.
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/org-migration/lib.sh
source "${HERE}/lib.sh"

clones="${HOME}/Developer"
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clones)
      clones="${2:?--clones needs a directory}"
      shift 2
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
if [[ "${#positional[@]}" -ne 3 ]]; then
  echo "usage: verify.sh <move-list> <baseline-dir> <after-dir> [--clones <dir>]" >&2
  exit 2
fi
list="${positional[0]}"
base="${positional[1]}"
after="${positional[2]}"
fail=0

# The baseline dir must exist and hold snapshots. Without this check a wrong
# path is not an error: every repo simply misses its baseline file and the
# comparison loop reports "missing snapshot" for the whole move list, which
# reads as catastrophic drift rather than as a typo. Fail on the path itself
# so the message names the real problem.
if [[ ! -d "${base}" ]]; then
  echo "verify: baseline-dir ${base} does not exist" >&2
  exit 1
fi
if [[ -z "$(ls -A "${base}" 2>/dev/null || true)" ]]; then
  echo "verify: baseline-dir ${base} is empty" >&2
  exit 1
fi

# The after-dir must be ours alone. A leftover JSON from an earlier run would
# be compared as though this run had just written it, so a repo whose snapshot
# failed now could still be reported ok from stale state.
if [[ -e "${after}" ]] && [[ -n "$(ls -A "${after}" 2>/dev/null || true)" ]]; then
  echo "verify: after-dir ${after} is not empty; use a fresh directory" >&2
  exit 1
fi

# A failed snapshot means the after-dir is incomplete. Stop here: comparing a
# partial snapshot would print per-repo ok lines that describe nothing.
if ! bash "${HERE}/snapshot.sh" "${list}" "${after}" >/dev/null; then
  echo "verify: snapshot failed; not comparing against the baseline" >&2
  exit 1
fi

pairs="$(om_read_move_list "${list}")" || exit 1
while read -r repo target; do
  b="${base}/${repo}.json"
  a="${after}/${repo}.json"
  if [[ ! -f "${b}" || ! -f "${a}" ]]; then
    echo "verify: ${repo}: missing snapshot (baseline=${b} after=${a})" >&2
    fail=1
    continue
  fi
  # Every top-level field except owner must be byte-identical. A jq failure
  # here means a snapshot is unreadable, not that nothing changed: swallowing
  # it would leave ${changed} empty and report the repo as ok.
  if ! changed="$(jq -r -n --slurpfile b "${b}" --slurpfile a "${a}" \
    '($b[0] | del(.owner)) as $x | ($a[0] | del(.owner)) as $y
     | [($x + $y | keys[]) | select($x[.] != $y[.])] | join(",")')"; then
    echo "verify: ${repo}: cannot diff snapshots" >&2
    fail=1
    continue
  fi
  if [[ -n "${changed}" ]]; then
    echo "verify: ${repo}: fields changed besides owner: ${changed}" >&2
    fail=1
  fi
  if ! login="$(jq -r '.owner.login' "${a}")" || ! type="$(jq -r '.owner.type' "${a}")"; then
    echo "verify: ${repo}: cannot diff snapshots" >&2
    fail=1
    continue
  fi
  if [[ "${login,,}" != "${target,,}" || "${type}" != "Organization" ]]; then
    echo "verify: ${repo}: owner is ${login} (${type}), expected ${target} (Organization)" >&2
    fail=1
  else
    echo "verify: ${repo}: ok"
  fi
done <<<"${pairs}"

# Every local clone whose origin is smartwatermelon/* must still resolve.
# ~/Developer is not flat: clients/<repo> and netlify/crazy-larry sit one
# level deeper, so scan both depths.
for gitdir in "${clones}"/*/.git "${clones}"/*/*/.git; do
  [[ -e "${gitdir}" ]] || continue
  dir="${gitdir%/.git}"
  url="$(git -C "${dir}" remote get-url origin 2>/dev/null || true)"
  [[ "${url}" =~ github\.com[:/]smartwatermelon/ ]] || continue
  # Name it relative to the clones root, so a nested clone is unambiguous.
  name="${dir#"${clones}"/}"
  if git -C "${dir}" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    echo "verify: clone ${name}: ls-remote ok"
  else
    echo "verify: clone ${name}: ls-remote FAILED (${url})" >&2
    fail=1
  fi
done

exit "${fail}"
