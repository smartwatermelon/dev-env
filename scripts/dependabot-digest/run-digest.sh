#!/usr/bin/env bash
# Build the fleet-wide Dependabot digest and upsert it as an issue.
#
# Usage: run-digest.sh [--dry-run] [--run-url URL]
#
# Environment:
#   DIGEST_OWNERS       space-separated owners to survey
#                       (default: smartwatermelon nightowlstudiollc twistedmelonman)
#   DIGEST_TOKEN_<NAME> a token that can read PRs for that owner, where <NAME>
#                       is the owner uppercased with '-' replaced by '_'.
#   DIGEST_PROBE_<NAME> optional: a private repo under that owner, used to prove
#                       the token still has private-repo access.
#   DIGEST_ISSUE_REPO   repo that holds the digest issue
#                       (default: smartwatermelon/dev-env)
#   GH_TOKEN            used for the issue write; must have issues:write there.
#
# One token per owner is not a style choice. A fine-grained PAT is "limited to
# access resources owned by a single user or organization" (GitHub docs), so
# three owners need three tokens. The alternative — one classic PAT — grants
# write on every repo in every org, which is far too much for a read-only
# digest.
#
# Every owner must succeed. A digest that quietly covers two owners out of
# three is worse than none: it reports an empty queue for the owner it could
# not read, and the PRs there stay invisible, which is the exact failure this
# tool exists to prevent.
set -uo pipefail
unset CDPATH

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNERS="${DIGEST_OWNERS:-smartwatermelon nightowlstudiollc twistedmelonman}"
ISSUE_REPO="${DIGEST_ISSUE_REPO:-smartwatermelon/dev-env}"

dry_run=false
run_url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --run-url) run_url="${2-}"; shift 2 ;;
    *) echo "run-digest.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
collected="${work}/collected.ndjson"
: >"${collected}"

issue_token="${GH_TOKEN-}"

for owner in ${OWNERS}; do
  var_suffix="$(tr '[:lower:]-' '[:upper:]_' <<<"${owner}")"
  token_var="DIGEST_TOKEN_${var_suffix}"
  probe_var="DIGEST_PROBE_${var_suffix}"
  token="${!token_var-}"
  probe="${!probe_var-}"

  if [[ -z "${token}" ]]; then
    echo "run-digest.sh: ${token_var} is not set; cannot read ${owner}." \
      "Refusing to publish a digest that would silently omit it." >&2
    exit 1
  fi

  echo "run-digest.sh: collecting ${owner}" >&2
  if ! GH_TOKEN="${token}" DIGEST_PRIVATE_PROBE="${probe}" \
    bash "${HERE}/collect.sh" "${owner}" >>"${collected}"; then
    echo "run-digest.sh: collection failed for ${owner}; not publishing a partial digest" >&2
    exit 1
  fi
done

classified="${work}/classified.ndjson"
if ! bash "${HERE}/classify.sh" <"${collected}" >"${classified}"; then
  echo "run-digest.sh: classification failed" >&2
  exit 1
fi

body="${work}/body.md"
render_args=()
[[ -n "${run_url}" ]] && render_args=(--run-url "${run_url}")
if ! bash "${HERE}/render.sh" "${render_args[@]}" <"${classified}" >"${body}"; then
  echo "run-digest.sh: rendering failed" >&2
  exit 1
fi

# The title claims a queue state, so it must never be computed from a failed
# read. grep -c exits 1 on a file with no matching lines and 2 when the file
# cannot be read: those are different facts, and swallowing both with `|| true`
# would title an unreadable digest "queue: clear" — announcing that nothing
# needs attention precisely when the tool has lost the ability to tell.
count="$(grep -c . "${classified}")"
count_rc=$?
if [[ "${count_rc}" -gt 1 ]]; then
  echo "run-digest.sh: could not read ${classified} (grep exit ${count_rc});" \
    "refusing to publish a digest whose queue state is unknown" >&2
  exit 1
fi
[[ -z "${count}" ]] && count=0

if [[ "${count}" -eq 0 ]]; then
  title="Dependabot queue: clear"
else
  actionable="$(jq -s '[.[] | select(.bucket != "held")] | length' "${classified}")"
  actionable_rc=$?
  if [[ "${actionable_rc}" -ne 0 || -z "${actionable}" ]]; then
    echo "run-digest.sh: could not count actionable PRs in ${classified}" \
      "(jq exit ${actionable_rc}); refusing to publish a digest with a" \
      "title that would misstate the queue" >&2
    exit 1
  fi
  title="Dependabot queue: ${actionable} of ${count} PRs awaiting action"
fi

if [[ "${dry_run}" == "true" ]]; then
  cat "${body}"
  exit 0
fi

GH_TOKEN="${issue_token}" bash "${HERE}/upsert-issue.sh" "${ISSUE_REPO}" "${title}" <"${body}"
