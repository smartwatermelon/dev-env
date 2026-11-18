#!/bin/bash
# Tests the job-started hook with crafted payloads. HOOK picks the script.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
real_hook="${HOOK:-${here}/../guest/job-started.sh}"
control_hook="${here}/hook-allow-all.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/jobhook.XXXXXX")"
trap 'rm -r "${t}"' EXIT
# CI runs on Ubuntu, so pass jq explicitly; the hook defaults to /usr/bin/jq (macOS guest).
jq_bin="$(command -v jq)"
pass=0
fail=0
hook=""
quiet=0

run() { # expect(0|1) label event_name payload_json [extra env...]
  local want="$1" label="$2" evn="$3" json="$4"
  shift 4
  printf '%s' "${json}" >"${t}/ev.json"
  env -i PATH=/usr/bin:/bin JQ_BIN="${jq_bin}" GITHUB_EVENT_PATH="${t}/ev.json" GITHUB_EVENT_NAME="${evn}" "$@" \
    /bin/bash "${hook}" >/dev/null 2>&1
  local got=$?
  if [[ "${got}" == "${want}" ]]; then
    pass=$((pass + 1))
    [[ "${quiet}" == 1 ]] || echo "  PASS: ${label}"
  else
    fail=$((fail + 1))
    [[ "${quiet}" == 1 ]] || echo "  FAIL: ${label} (exit ${got}, want ${want})"
  fi
}

R='"repository":{"full_name":"smartwatermelon/dotfiles"}'
same='"pull_request":{"head":{"repo":{"full_name":"smartwatermelon/dotfiles"}}}'
fork='"pull_request":{"head":{"repo":{"full_name":"stranger/dotfiles"}}}'

cases() {
  run 0 "same-repo pull_request" pull_request "{${R},${same}}"
  run 1 "fork pull_request" pull_request "{${R},${fork}}"
  run 1 "fork pull_request_target" pull_request_target "{${R},${fork}}"
  run 1 "deleted head repo" pull_request "{${R},\"pull_request\":{\"head\":{\"repo\":null}}}"
  run 1 "fork in same-named other owner" pull_request "{${R},\"pull_request\":{\"head\":{\"repo\":{\"full_name\":\"smartwatermelon-evil/dotfiles\"}}}}"
  run 0 "push" push "{${R}}"
  run 0 "workflow_dispatch" workflow_dispatch "{${R}}"
  run 0 "schedule" schedule "{${R}}"
  run 0 "merge_group" merge_group "{${R}}"
  run 0 "same-repo workflow_run" workflow_run "{${R},\"workflow_run\":{\"head_repository\":{\"full_name\":\"smartwatermelon/dotfiles\"}}}"
  run 1 "fork workflow_run" workflow_run "{${R},\"workflow_run\":{\"head_repository\":{\"full_name\":\"stranger/dotfiles\"}}}"
  run 1 "issue_comment not allowed" issue_comment "{${R}}"
  run 1 "unknown event" fork "{${R}}"
  run 1 "other owner" push '{"repository":{"full_name":"someone/repo"}}'
  run 1 "no repository in payload" push '{}'
  run 1 "malformed payload" push 'not json'
  run 1 "empty event name" "" "{${R},${same}}"
  run 1 "GITHUB_REPOSITORY mismatch" push "{${R}}" GITHUB_REPOSITORY=smartwatermelon/other
  run 0 "GITHUB_REPOSITORY match" push "{${R}}" GITHUB_REPOSITORY=smartwatermelon/dotfiles
  run 1 "push payload carrying a fork PR" push "{${R},${fork}}"
  run 1 "schedule payload carrying a pull_request" schedule "{${R},${same}}"
  run 1 "missing payload file" push "{${R}}" GITHUB_EVENT_PATH="${t}/none.json"
  run 1 "no jq" pull_request "{${R},${same}}" JQ_BIN=/nonexistent/jq
}

hook="${real_hook}"
cases
echo "passed=${pass} failed=${fail}"
real_fail="${fail}"

# Control: an allow-all hook must fail all 16 deny cases, else a case cannot fail.
echo "== control: allow-all hook"
pass=0
fail=0
quiet=1
hook="${control_hook}"
cases
want_control=16
if [[ "${fail}" == "${want_control}" ]]; then
  echo "  PASS: control failed ${fail} cases (want ${want_control})"
  control_ok=0
else
  echo "  FAIL: control failed ${fail} cases (want ${want_control})"
  control_ok=1
fi

[[ "${real_fail}" == 0 && "${control_ok}" == 0 ]]
