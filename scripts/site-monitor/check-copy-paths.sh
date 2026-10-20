#!/usr/bin/env bash
# Fails when a sites.json repo has no include line in copy-paths.conf. Exit 0 ok, 1 repo missing, 2 bad input.
set -uo pipefail
unset CDPATH

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-}"
SITES="${2:-${HERE}/sites.json}"

die() {
  echo "check-copy-paths: $1" >&2
  exit 2
}

[[ -n "${CONF}" ]] || die "usage: check-copy-paths.sh <copy-paths.conf> [sites.json]"
[[ -r "${CONF}" ]] || die "cannot read ${CONF}"
[[ -r "${SITES}" ]] || die "cannot read ${SITES}"

# Fail closed: a truncated or wrong download must not pass, so the conf needs at least one owner/name include line.
included="$(awk '$1 ~ /^[^#=\/]+\/[^\/]+$/ && $2 == "include" { print $1 }' "${CONF}" | sort -u)"
[[ -n "${included}" ]] || die "${CONF} has no owner/name include lines; refusing to pass on an empty or unreadable conf"

if ! jq -e 'type == "array" and length > 0 and all(.[]; (.repo | type) == "string")' "${SITES}" >/dev/null 2>&1; then
  die "${SITES} is not a non-empty array of objects with a string .repo"
fi
repos="$(jq -r '[.[].repo] | unique | .[]' "${SITES}")" || die "cannot list repos in ${SITES}"

missing=0
while IFS= read -r repo; do
  [[ -n "${repo}" ]] || continue
  if ! grep -qxF -- "${repo}" <<<"${included}"; then
    echo "check-copy-paths: ${repo} is in ${SITES##*/} but has no include line in ${CONF##*/}" >&2
    missing=1
  fi
done <<<"${repos}"

if [[ "${missing}" -ne 0 ]]; then
  echo "check-copy-paths: add include lines for the repos above to smartwatermelon/claude-config copy-paths.conf" >&2
  exit 1
fi
echo "check-copy-paths: every repo in ${SITES##*/} has a copy-paths.conf entry"
exit 0
