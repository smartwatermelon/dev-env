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
standards="${work}/standards.ndjson"
: >"${standards}"

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

  # Standards never block the queue report. A crash renders as not checked.
  echo "run-digest.sh: reading standards-check annotations for ${owner}" >&2
  if ! GH_TOKEN="${token}" bash "${HERE}/standards.sh" "${owner}" >>"${standards}"; then
    jq -cn --arg o "${owner}" '{owner: $o, repo: null, state: "unlisted",
      detail: "standards.sh failed; see the run log", source: null,
      runUrl: null, annotations: []}' >>"${standards}"
  fi
done

classified="${work}/classified.ndjson"
if ! bash "${HERE}/classify.sh" <"${collected}" >"${classified}"; then
  echo "run-digest.sh: classification failed" >&2
  exit 1
fi

body="${work}/body.md"
render_args=(--standards "${standards}")
[[ -n "${run_url}" ]] && render_args+=(--run-url "${run_url}")
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

# dev-env#228: a daily issue nobody reads is how PRs sat unseen before
# (dev-env#120), so the automatic path's failures also go to ntfy.
nm_count="$(jq -s '[.[] | select(.notMerged == true)] | length' "${classified}" 2>/dev/null)"
if [[ ! "${nm_count}" =~ ^[0-9]+$ ]]; then
  echo "run-digest.sh: could not count PRs that were not merged automatically;" \
    "refusing to publish a digest that may hide them" >&2
  exit 1
fi

if [[ "${dry_run}" == "true" ]]; then
  cat "${body}"
  [[ "${nm_count}" -gt 0 ]] && echo "run-digest.sh: dry run; would push an ntfy alert for ${nm_count} PRs" >&2
  exit 0
fi

upserted="$(GH_TOKEN="${issue_token}" bash "${HERE}/upsert-issue.sh" "${ISSUE_REPO}" "${title}" <"${body}")" || exit $?
printf '%s\n' "${upserted}"
# upsert-issue.sh prints "updated <repo>#<n>" or "created <url>".
issue_url="https://github.com/${ISSUE_REPO}/issues"
if [[ "${upserted}" =~ ^updated\ ([^#[:space:]]+)#([0-9]+)$ ]]; then
  issue_url="https://github.com/${BASH_REMATCH[1]}/issues/${BASH_REMATCH[2]}"
elif [[ "${upserted}" =~ ^created\ (https://[^[:space:]]+)$ ]]; then
  issue_url="${BASH_REMATCH[1]}"
fi

[[ "${nm_count}" -eq 0 ]] && exit 0
# The topic is the secret. It goes only in the URL; curl output is discarded
# so no error can echo it.
if [[ -z "${NTFY_TOPIC-}" ]]; then
  echo "::error::NTFY_TOPIC is empty; ${nm_count} PRs not merged automatically, and no alert was sent. See docs/runbooks/site-monitor-ntfy.md"
  exit 1
fi
main_red="$(jq -s '[.[] | select(.notMerged == true and .notMergedReason == "main-red")] | length' "${classified}" 2>/dev/null)"
nm_title="Dependabot: ${nm_count} PRs not merged automatically"
[[ "${main_red:-0}" -gt 0 ]] && nm_title+=", ${main_red} behind a red default branch"
nm_lines="$(jq -rs '[.[] | select(.notMerged == true)]
  | sort_by((if .notMergedReason == "main-red" then 0 else 1 end), .repo, .number)
  | (.[:10][] | "\(.repo)#\(.number): \(.notMergedReason)"),
    (if length > 10 then "and \(length - 10) more" else empty end)' "${classified}" 2>/dev/null)"
priority=3
[[ "${main_red:-0}" -gt 0 ]] && priority=4
if ! printf '%s' "${nm_lines:-see the digest issue}" | curl -fsS --max-time 20 --retry 2 \
  -H "Title: ${nm_title}" -H "Priority: ${priority}" -H "Tags: package" \
  -H "Click: ${issue_url}" \
  --data-binary @- "${NTFY_BASE:-https://ntfy.sh}/${NTFY_TOPIC}" >/dev/null 2>&1; then
  echo "::error::ntfy delivery failed for '${nm_title}'"
  exit 1
fi
echo "ntfy: sent priority ${priority}: ${nm_title}"
