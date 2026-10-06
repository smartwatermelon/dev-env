#!/usr/bin/env bash
# run-monitor.sh end to end, with stub gh, curl and baseline-check.sh. Each scenario drives one alert transition.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN NTFY_TOPIC

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/.."
WORK="/tmp/site-monitor-test-$$"
BIN="${WORK}/bin"
mkdir -p "${BIN}"
trap 'rm -rf "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

TOPIC='topic-secret-1f2e3d'

# Two sites keep the assertions readable; the real list is sites.json.
cat >"${WORK}/sites.json" <<'JSON'
[
  { "url": "https://a.example", "repo": "nightowlstudiollc/site-a" },
  { "url": "https://b.example", "repo": "smartwatermelon/site-b" }
]
JSON

# baseline-check.sh stub: a URL listed in $STUB_STATE/down fails, on stderr, as the real script does.
cat >"${WORK}/baseline-check.sh" <<'STUB'
#!/usr/bin/env bash
if grep -qxF "$1" "${STUB_STATE}/down" 2>/dev/null; then
  echo "FAIL: $1/ returned 503 (expected 200)" >&2
  exit 1
fi
echo "ok: $1/ returned 200"
STUB

# curl stub: one line per call holding every argument, plus the message it was given on stdin.
cat >"${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
msg="$(cat)"
printf '%s | MSG=%s\n' "$*" "${msg}" >>"${STUB_STATE}/ntfy.log"
if [[ -f "${STUB_STATE}/curl-fail" ]]; then echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; fi
STUB

# gh stub. The open alert issue is $STUB_STATE/issue.json; check-runs come from $STUB_STATE/checks/<owner>_<repo>.json.
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
st="${STUB_STATE}"
echo "gh $*" >>"${st}/gh.log"
arg_after() { local want="$1" prev=""; shift; for a in "$@"; do [[ "${prev}" == "${want}" ]] && { echo "${a}"; return; }; prev="${a}"; done; }
case "$1 $2" in
  "api user") echo 'twistedmelonman'; exit 0 ;;
  "label create") exit 0 ;;
  "issue list")
    [[ "$*" == *"--label site-down"* && "$*" == *"--state open"* ]] || { echo "stub: unexpected list $*" >&2; exit 1; }
    if [[ -f "${st}/issue.json" ]]; then jq -c '[.]' "${st}/issue.json"; else echo '[]'; fi
    exit 0 ;;
  "issue create")
    jq -n --rawfile b "$(arg_after --body-file "$@")" \
      '{number: 7, url: "https://github.com/o/r/issues/7", body: $b}' >"${st}/issue.json"
    echo "CREATE label=$(arg_after --label "$@") assignee=$(arg_after --assignee "$@")" >>"${st}/issues.log"
    echo "https://github.com/o/r/issues/7"; exit 0 ;;
  "issue edit")
    jq --rawfile b "$(arg_after --body-file "$@")" '.body = $b' "${st}/issue.json" >"${st}/issue.tmp"
    mv "${st}/issue.tmp" "${st}/issue.json"
    echo "EDIT $3" >>"${st}/issues.log"; exit 0 ;;
  "issue close")
    rm -f "${st}/issue.json"
    echo "CLOSE $3 $(arg_after --comment "$@")" >>"${st}/issues.log"; exit 0 ;;
esac
if [[ "$1" == "api" ]]; then
  path="${2%%\?*}"
  [[ -n "${GH_TOKEN-}" ]] || { echo "stub: api call without a token" >&2; exit 1; }
  if [[ "${path}" =~ ^repos/([^/]+)/([^/]+)$ ]]; then echo '{"default_branch":"main"}'; exit 0; fi
  if [[ "${path}" =~ ^repos/([^/]+)/([^/]+)/commits/main/check-runs$ ]]; then
    f="${st}/checks/${BASH_REMATCH[1]}_${BASH_REMATCH[2]}.json"
    if [[ -f "${f}.403" ]]; then echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; fi
    if [[ -f "${f}" ]]; then cat "${f}"; else echo '{"total_count":0,"check_runs":[]}'; fi
    exit 0
  fi
fi
# Any call this stub does not model is a test defect, not a pass.
echo "stub: unmodelled gh call: $*" >&2
exit 1
STUB
chmod +x "${BIN}/gh" "${BIN}/curl"

STATE="${WORK}/state"
reset_state() { rm -rf "${STATE}"; mkdir -p "${STATE}/checks"; : >"${STATE}/ntfy.log"; : >"${STATE}/issues.log"; }

T0=1790000000
# run <epoch> [topic]: runs the monitor; output in ${STATE}/out, exit code in rc.
run() {
  PATH="${BIN}:${PATH}" STUB_STATE="${STATE}" GH_TOKEN=issue-token \
    MONITOR_TOKEN_NIGHTOWLSTUDIOLLC=nos-token MONITOR_TOKEN_SMARTWATERMELON=swm-token \
    NTFY_TOPIC="${2-${TOPIC}}" BASELINE_CHECK="${WORK}/baseline-check.sh" SITES_FILE="${WORK}/sites.json" \
    MONITOR_REPO=o/r RUN_URL=https://run.example/1 MONITOR_NOW="$1" \
    bash "${DIR}/run-monitor.sh" >"${STATE}/out" 2>&1
  rc=$?
}
# count_is <n> <pattern> <file>: exactly n lines of <file> match <pattern>.
count_is() { local n=""; n="$(grep -c -- "$2" "$3")"; [[ "${n}" -eq "$1" ]]; }
pings_are() { count_is "$1" . "${STATE}/ntfy.log"; }
check_run() { # <owner_repo> <status> <conclusion>
  jq -n --arg s "$2" --arg c "$3" '{total_count: 1, check_runs: [{name: "netlify-site-checks / site-check",
    status: $s, conclusion: (if $c == "" then null else $c end), started_at: "2026-10-06T00:00:00Z",
    html_url: "https://github.com/x/runs/1"}]}' >"${STATE}/checks/$1.json"
}
check() { local r=$?; if [[ ${r} -eq 0 ]]; then _pass "$1"; else _fail "$1"; sed "s/^/      /" "${STATE}/out" >&2; fi; }

echo "-- all OK, no issue"
reset_state
run "${T0}"
[[ ${rc} -eq 0 ]]; check "exit 0"
pings_are 0; check "no ntfy"
[[ ! -s "${STATE}/issues.log" ]]; check "no issue writes"

echo "-- absent and in-progress check-runs do not alert"
check_run smartwatermelon_site-b in_progress ""
run "${T0}"
[[ ${rc} -eq 0 ]] && pings_are 0; check "exit 0 with an in-progress run"

echo "-- first failure opens the issue and pages"
echo "https://a.example" >"${STATE}/down"
run "${T0}"
[[ ${rc} -ne 0 ]]; check "exit nonzero while failing"
grep -qx "CREATE label=site-down assignee=twistedmelonman" "${STATE}/issues.log"; check "issue created with label and assignee"
grep -qF "FAIL: https://a.example/ returned 503" "${STATE}/issue.json"; check "issue body carries the FAIL line from stderr"
pings_are 1; check "one ntfy"
grep -q "Priority: 5.*Tags: rotating_light" "${STATE}/ntfy.log"; check "ntfy is priority 5, rotating_light"
grep -q "Title: Site down: a.example" "${STATE}/ntfy.log"; check "ntfy title names the site"
grep -qF "Click: https://github.com/o/r/issues/7" "${STATE}/ntfy.log"; check "ntfy click is the issue"
grep -qF "https://ntfy.sh/${TOPIC}" "${STATE}/ntfy.log"; check "ntfy posts to the topic"
! grep -qF "${TOPIC}" "${STATE}/out"; check "topic never printed"

echo "-- same failure 15 minutes later: body only"
: >"${STATE}/ntfy.log"
run $((T0 + 900))
[[ ${rc} -ne 0 ]]; check "exit nonzero"
grep -qx "EDIT 7" "${STATE}/issues.log"; check "issue edited"
pings_are 0; check "no ntfy"
grep -qF "last-ping=${T0} -->" "${STATE}/issue.json"; check "reminder clock kept"

echo "-- failing set changes: pages again"
check_run nightowlstudiollc_site-a completed failure
run $((T0 + 1800))
pings_are 1 && grep -q "Priority: 5" "${STATE}/ntfy.log"; check "one ntfy at priority 5"
grep -q "Title: Site failures changed: .*site-a site-check" "${STATE}/ntfy.log"; check "title says changed and names the check"
count_is 1 CREATE "${STATE}/issues.log"; check "still one issue"

echo "-- same set, 5h59m after the last alert: quiet"
: >"${STATE}/ntfy.log"
run $((T0 + 1800 + 6 * 3600 - 60))
pings_are 0; check "no ntfy"

echo "-- same set, 6h after the last alert: reminder"
run $((T0 + 1800 + 6 * 3600))
pings_are 1 && grep -q "Title: Still down.*Priority: 5" "${STATE}/ntfy.log"; check "one reminder at priority 5"
grep -qF "last-ping=$((T0 + 1800 + 6 * 3600)) -->" "${STATE}/issue.json"; check "reminder clock advanced"

echo "-- recovery closes the issue and pages at priority 3"
: >"${STATE}/ntfy.log"
rm -f "${STATE}/down" "${STATE}/checks/nightowlstudiollc_site-a.json"
run $((T0 + 30000))
[[ ${rc} -eq 0 ]]; check "exit 0"
grep -q "^CLOSE 7 Recovered:" "${STATE}/issues.log"; check "issue closed with a comment"
pings_are 1 && grep -q "Priority: 3" "${STATE}/ntfy.log"; check "recovered ntfy at priority 3"
run $((T0 + 31000))
[[ ${rc} -eq 0 ]] && pings_are 1; check "next green run is silent"

echo "-- missing NTFY_TOPIC: issue still written, run fails"
reset_state
echo "https://b.example" >"${STATE}/down"
run "${T0}" ""
[[ ${rc} -ne 0 ]]; check "exit nonzero"
grep -q "^CREATE" "${STATE}/issues.log"; check "issue created anyway"
pings_are 0; check "no curl call"
grep -q "NTFY_TOPIC is empty; the alert .* was NOT sent" "${STATE}/out"; check "says the alert was not sent"
grep -qF "last-ping=0 -->" "${STATE}/issue.json"; check "clock not advanced, so the first run with a topic pages"
run $((T0 + 900))
pings_are 1; check "first run with the topic installed pages"
reset_state
run "${T0}" ""
[[ ${rc} -ne 0 ]] && grep -q "cannot alert anyone" "${STATE}/out"; check "green run without a topic still fails"

echo "-- unreadable check-runs are a fault, not green"
reset_state
touch "${STATE}/checks/smartwatermelon_site-b.json.403"
run "${T0}"
[[ ${rc} -ne 0 ]] && pings_are 0; check "403 fails the run without paging"
reset_state
echo '{"total_count":3,"check_runs":null}' >"${STATE}/checks/smartwatermelon_site-b.json"
run "${T0}"
[[ ${rc} -ne 0 ]] && grep -q "unreadable check-runs payload" "${STATE}/out"; check "nulled check_runs fails the run"

echo "-- failed ntfy delivery does not advance the clock, so the next run retries"
reset_state
echo "https://a.example" >"${STATE}/down"
touch "${STATE}/curl-fail"
run "${T0}"
[[ ${rc} -ne 0 ]] && grep -q "ntfy delivery failed" "${STATE}/out"; check "delivery failure is reported"
grep -qF "last-ping=0 -->" "${STATE}/issue.json"; check "clock not advanced"
rm -f "${STATE}/curl-fail"
: >"${STATE}/ntfy.log"
run $((T0 + 900))
pings_are 1 && grep -q "Title: Still down" "${STATE}/ntfy.log"; check "next run re-sends"
grep -qF "last-ping=$((T0 + 900)) -->" "${STATE}/issue.json"; check "clock advanced after delivery"

echo "-- a check that turns unreadable keeps its failing state"
reset_state
check_run nightowlstudiollc_site-a completed failure
run "${T0}"
pings_are 1; check "check failure pages"
rm -f "${STATE}/checks/nightowlstudiollc_site-a.json"
touch "${STATE}/checks/nightowlstudiollc_site-a.json.403"
: >"${STATE}/ntfy.log"
run $((T0 + 900))
[[ ${rc} -ne 0 ]] && pings_are 0; check "no 'changed' page for a fault"
! grep -q "^CLOSE" "${STATE}/issues.log"; check "issue not closed"
grep -qF "failing=check:nightowlstudiollc/site-a -->" "${STATE}/issue.json"; check "failing set carried over"

echo "-- a fault never closes the issue as recovered"
reset_state
echo "https://a.example" >"${STATE}/down"
run "${T0}"
rm -f "${STATE}/down"
touch "${STATE}/checks/smartwatermelon_site-b.json.403"
: >"${STATE}/ntfy.log"
run $((T0 + 900))
[[ ${rc} -ne 0 ]] && pings_are 0; check "no recovered push while a check is unreadable"
! grep -q "^CLOSE" "${STATE}/issues.log"; check "issue left open"

exit "${fail}"
