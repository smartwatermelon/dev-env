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

bash "${HERE}/snapshot.sh" "${list}" "${after}" >/dev/null || fail=1

pairs="$(om_read_move_list "${list}")" || exit 1
while read -r repo target; do
  b="${base}/${repo}.json"
  a="${after}/${repo}.json"
  if [[ ! -f "${b}" || ! -f "${a}" ]]; then
    echo "verify: ${repo}: missing snapshot (baseline=${b} after=${a})" >&2
    fail=1
    continue
  fi
  # Every top-level field except owner must be byte-identical.
  changed="$(jq -r -n --slurpfile b "${b}" --slurpfile a "${a}" \
    '($b[0] | del(.owner)) as $x | ($a[0] | del(.owner)) as $y
     | [($x + $y | keys[]) | select($x[.] != $y[.])] | join(",")' || true)"
  if [[ -n "${changed}" ]]; then
    echo "verify: ${repo}: fields changed besides owner: ${changed}" >&2
    fail=1
  fi
  login="$(jq -r '.owner.login' "${a}" || true)"
  type="$(jq -r '.owner.type' "${a}" || true)"
  if [[ "${login,,}" != "${target,,}" || "${type}" != "Organization" ]]; then
    echo "verify: ${repo}: owner is ${login} (${type}), expected ${target} (Organization)" >&2
    fail=1
  else
    echo "verify: ${repo}: ok"
  fi
done <<<"${pairs}"

# Every local clone whose origin is smartwatermelon/* must still resolve.
for gitdir in "${clones}"/*/.git; do
  [[ -e "${gitdir}" ]] || continue
  dir="${gitdir%/.git}"
  url="$(git -C "${dir}" remote get-url origin 2>/dev/null || true)"
  [[ "${url}" =~ github\.com[:/]smartwatermelon/ ]] || continue
  if git -C "${dir}" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    echo "verify: clone ${dir##*/}: ls-remote ok"
  else
    echo "verify: clone ${dir##*/}: ls-remote FAILED (${url})" >&2
    fail=1
  fi
done

exit "${fail}"
