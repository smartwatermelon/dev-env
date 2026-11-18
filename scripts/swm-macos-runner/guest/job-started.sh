#!/bin/bash
# Job-started hook: exit 0 only for same-repo events in an allowed owner.
# Runs in the guest's /bin/bash 3.2.
set -u
ALLOWED_OWNERS="${ALLOWED_OWNERS:-smartwatermelon}"
JQ="${JQ_BIN:-/usr/bin/jq}"

deny() { echo "job-started hook: DENIED: $*" >&2; exit 1; }

[[ -x "${JQ}" ]] || deny "no jq at ${JQ}"
ev="${GITHUB_EVENT_PATH:-}"
[[ -n "${ev}" && -r "${ev}" ]] || deny "no readable event payload (GITHUB_EVENT_PATH='${ev}')"
name="${GITHUB_EVENT_NAME:-}"
[[ -n "${name}" ]] || deny "GITHUB_EVENT_NAME is empty"

get() { "${JQ}" -r "$1 // empty" "${ev}" 2>/dev/null; }

repo="$(get '.repository.full_name')"
[[ -n "${repo}" ]] || deny "payload has no repository.full_name"
owner="${repo%%/*}"
ok_owner=no
for o in ${ALLOWED_OWNERS}; do [[ "${owner}" == "${o}" ]] && ok_owner=yes; done
[[ "${ok_owner}" == yes ]] || deny "owner '${owner}' is not allowed"
[[ -z "${GITHUB_REPOSITORY:-}" || "${GITHUB_REPOSITORY}" == "${repo}" ]] ||
  deny "GITHUB_REPOSITORY '${GITHUB_REPOSITORY}' does not match payload '${repo}'"

case "${name}" in
  pull_request | pull_request_target)
    head="$(get '.pull_request.head.repo.full_name')"
    [[ -n "${head}" ]] || deny "${name}: head repository is missing (deleted fork?)"
    [[ "${head}" == "${repo}" ]] || deny "${name}: head '${head}' is not '${repo}' (fork PR)"
    ;;
  workflow_run)
    head="$(get '.workflow_run.head_repository.full_name')"
    [[ -n "${head}" ]] || deny "workflow_run: head repository is missing"
    [[ "${head}" == "${repo}" ]] || deny "workflow_run: head '${head}' is not '${repo}' (fork run)"
    ;;
  push | workflow_dispatch | schedule | merge_group)
    # These start only from refs inside the repo or from someone with write access.
    pr_head="$(get '.pull_request.head.repo.full_name')"
    [[ -z "${pr_head}" ]] || deny "${name}: payload carries a pull_request"
    ;;
  *)
    deny "event '${name}' is not on the allowlist"
    ;;
esac
echo "job-started hook: allowed ${name} in ${repo}"
exit 0
