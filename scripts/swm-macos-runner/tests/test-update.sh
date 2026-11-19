#!/usr/bin/env bash
# update.sh with stub git and a stub bash for install.sh: new commit with job=0/1, failures, github-app.sh version.
set -uo pipefail
unset CDPATH
unset SWM_STATE_DIR SWM_CLONE NTFY_TOPIC
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }
check() {
  local name="$1"
  shift
  if "$@"; then _pass "${name}"; else _fail "${name}"; fi
}
check_not() {
  local name="$1"
  shift
  if "$@"; then _fail "${name}"; else _pass "${name}"; fi
}
# check_is NAME WANT GOT: pass when GOT equals WANT.
check_is() {
  if [[ "$3" == "$2" ]]; then _pass "$1"; else _fail "$1 (got '$3', want '$2')"; fi
}

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE="${HERE}/../update.sh"
WORK="${TMPDIR:-/tmp}/swm-update-test-$$"
mkdir -p "${WORK}/bin"
# WORK is under TMPDIR, never a real clone or state dir.
trap 'rm -rf "${WORK:?}"' EXIT

# git stub: fetch fails on STUB_PULL_FAIL, merge on STUB_MERGE_FAIL; log prints the rev of the first matching "<path> <rev>" line.
cat >"${WORK}/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/git"
args=("$@")
for ((i = 0; i < ${#args[@]}; i += 1)); do
  case "${args[i]}" in
    fetch) if [[ -n "${STUB_PULL_FAIL:-}" ]]; then exit 1; fi; exit 0 ;;
    merge) if [[ -n "${STUB_MERGE_FAIL:-}" ]]; then exit 1; fi; exit 0 ;;
    log)
      while read -r p r; do
        for a in "${args[@]}"; do
          if [[ "${a}" == "${p}" ]]; then echo "${r}"; exit 0; fi
        done
      done <"${STUB_REVS}"
      exit 0
      ;;
    *) ;;
  esac
done
exit 0
STUB
# install.sh runner stub: logs its arguments and the updater flag; fails on STUB_INSTALL_FAIL.
cat >"${WORK}/bin/bashstub" <<'STUB'
#!/usr/bin/env bash
echo "$* from_updater=${SWM_FROM_UPDATER:-}" >>"${STUB_LOG}/install"
if [[ -n "${STUB_INSTALL_FAIL:-}" ]]; then exit 1; fi
exit 0
STUB
# rm stub: logs; removes only files inside this test's WORK dir.
cat >"${WORK}/bin/rm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/rm"
for a in "$@"; do
  case "${a}" in -*) ;; "${STUB_WORK}"/*) ;; *) echo "stub rm: outside WORK: ${a}" >&2; exit 9 ;; esac
done
exec /bin/rm "$@"
STUB
# curl stub: logs the arguments and stdin (the ntfy URL); fails on STUB_CURL_FAIL.
cat >"${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/curl"
cat >>"${STUB_LOG}/curl.stdin"
if [[ -n "${STUB_CURL_FAIL:-}" ]]; then exit 22; fi
exit 0
STUB
chmod +x "${WORK}"/bin/*

# run_update [NAME=value ...]: fresh dirs unless KEEP=1; sets S (state), L (log), OUT, RC.
n=0
run_update() {
  if [[ "${KEEP:-}" != 1 ]]; then
    n=$((n + 1))
    S="${WORK}/state${n}"
    L="${WORK}/log${n}"
    mkdir -p "${S}" "${L}"
    printf '%s\n' "scripts/swm-macos-runner REV1" >"${L}/revs"
    printf 'REV1\n' >"${S}/installed"
    printf 'name=\nid=\nfails=0\nalert=\njob=0\n' >"${S}/slot"
  fi
  OUT="$(env HOME="${WORK}/home" SWM_STATE_DIR="${S}" SWM_CLONE="${WORK}/clone" STUB_LOG="${L}" STUB_REVS="${L}/revs" \
    GIT_BIN="${WORK}/bin/git" RM_BIN="${WORK}/bin/rm" STUB_WORK="${WORK}" BASH_BIN="${WORK}/bin/bashstub" CURL_BIN="${WORK}/bin/curl" "$@" bash "${UPDATE}" 2>&1)"
  RC=$?
}
# again [NAME=value ...]: run again in the same dirs.
again() { KEEP=1 run_update "$@"; }
newrev() { printf '%s\n' "scripts/swm-macos-runner REV2" >"${L}/revs"; }

echo "== no change"
run_update
check "exit 0" test "${RC}" -eq 0
check "fetched without FETCH_HEAD" grep -q -- "-C ${WORK}/clone fetch --quiet --no-write-fetch-head origin" "${L}/git"
check "fast-forwarded to origin/main" grep -q -- "-C ${WORK}/clone merge --quiet --ff-only origin/main" "${L}/git"
check_not "never git pull (it races the NOS updater)" grep -q -- " pull" "${L}/git"
check_not "no install" test -e "${L}/install"
check "mark unchanged" test "$(cat "${S}/installed")" = REV1

echo "== new commit, no job"
run_update
newrev
again
check "exit 0" test "${RC}" -eq 0
check "install ran" test -s "${L}/install"
check "install is the clone's install.sh" grep -q "${WORK}/clone/scripts/swm-macos-runner/install.sh" "${L}/install"
check "install told it runs from the updater" grep -q 'from_updater=1' "${L}/install"
check "mark updated" test "$(cat "${S}/installed")" = REV2

echo "== new commit, job running"
run_update
newrev
printf 'name=mimolette-macos-1\nid=7\nfails=0\nalert=\njob=1\n' >"${S}/slot"
again
check "exit 0" test "${RC}" -eq 0
check_not "no install" test -e "${L}/install"
check "mark unchanged" test "$(cat "${S}/installed")" = REV1
check "logged as waiting" grep -qi 'waiting' <<<"${OUT}"
echo "  (job ends)"
printf 'name=\nid=\nfails=0\nalert=\njob=0\n' >"${S}/slot"
again
check "next run installs" test -s "${L}/install"
check "mark updated then" test "$(cat "${S}/installed")" = REV2

echo "== update-pending marker"
run_update
check_not "no change: no marker" test -e "${S}/update-pending"
printf 'stale\n' >"${S}/update-pending"
again
check_not "no change clears a stale marker" test -e "${S}/update-pending"
run_update
newrev
printf 'name=mimolette-macos-1\nid=7\nfails=0\nalert=\njob=1\n' >"${S}/slot"
again
check "job=1 and a new version writes the marker" test -e "${S}/update-pending"
check_not "the marker is not an install" test -e "${L}/install"
again
check "still waiting keeps the marker" test -e "${S}/update-pending"
printf 'name=\nid=\nfails=0\nalert=\njob=0\n' >"${S}/slot"
again
check "install ran" test -s "${L}/install"
check_not "a successful install clears the marker" test -e "${S}/update-pending"
run_update
newrev
printf 'x\n' >"${S}/update-pending"
again STUB_INSTALL_FAIL=1
check "a failed install keeps the marker" test -e "${S}/update-pending"
run_update
newrev
printf 'name=mimolette-macos-1\nid=7\nfails=0\nalert=\njob=1\n' >"${S}/slot"
again STUB_PULL_FAIL=1
check_not "a failed pull writes no marker" test -e "${S}/update-pending"
check_not "a failed pull installs nothing" test -e "${L}/install"

echo "== no slot file"
run_update
newrev
rm -f "${S}/slot"
again
check "no slot file counts as no job" test -s "${L}/install"

echo "== no mark file (first run)"
run_update
rm -f "${S}/installed"
again
check "installs" test -s "${L}/install"
check "mark written" test "$(cat "${S}/installed")" = REV1

echo "== pull fails"
run_update
newrev
again STUB_PULL_FAIL=1
check "exit 0" test "${RC}" -eq 0
check_not "no install" test -e "${L}/install"
check "mark unchanged" test "$(cat "${S}/installed")" = REV1
check "logged" grep -q 'git update failed' <<<"${OUT}"

echo "== merge fails"
run_update
newrev
again STUB_MERGE_FAIL=1
check "exit 0" test "${RC}" -eq 0
check_not "no install" test -e "${L}/install"
check "mark unchanged" test "$(cat "${S}/installed")" = REV1
check "logged" grep -q 'git update failed' <<<"${OUT}"

echo "== install fails"
run_update
newrev
again STUB_INSTALL_FAIL=1
check "exit 0" test "${RC}" -eq 0
check "install was tried" test -s "${L}/install"
check "mark unchanged" test "$(cat "${S}/installed")" = REV1
check "logged" grep -q 'install.sh failed' <<<"${OUT}"

echo "== github-app.sh change is a new version"
run_update
printf '%s\n%s\n' "scripts/nos-runner/github-app.sh REV3" "scripts/swm-macos-runner REV1" >"${L}/revs"
again
check "install ran" test -s "${L}/install"
check "mark is the github-app.sh commit" test "$(cat "${S}/installed")" = REV3

echo "== unreadable revision"
run_update
: >"${L}/revs"
again
check "exit 0" test "${RC}" -eq 0
check_not "no install" test -e "${L}/install"
check "mark unchanged" test "$(cat "${S}/installed")" = REV1

# fails N [NAME=value ...]: N more failed passes (git fetch fails) in the same dirs.
fails() {
  local i count="$1"
  shift
  for ((i = 0; i < count; i += 1)); do again STUB_PULL_FAIL=1 "$@"; done
}
alerts() { if [[ -e "${L}/curl" ]]; then grep -c . "${L}/curl"; else echo 0; fi; }

echo "== alert after repeated failures"
run_update
fails 5 NTFY_TOPIC=topic-abc
check "5 failures: count is 5" test "$(cat "${S}/update-fails")" = 5
check "5 failures: no alert" test "$(alerts)" -eq 0
fails 1 NTFY_TOPIC=topic-abc
check "6th failure: one alert" test "$(alerts)" -eq 1
check "alert names the runner" grep -q 'macOS runner: the updater has failed 6 passes' "${L}/curl"
check "alert gives the last reason" grep -q 'Last failure: git update failed' "${L}/curl"
check "alert marker written" test -e "${S}/update-alerted"
check "topic via stdin" grep -q 'topic-abc' "${L}/curl.stdin"
check_not "topic not in argv" grep -q 'topic-abc' "${L}/curl"
check "exit 0" test "${RC}" -eq 0
fails 1 NTFY_TOPIC=topic-abc
check "7th failure: still one alert" test "$(alerts)" -eq 1
check "count keeps rising" test "$(cat "${S}/update-fails")" = 7
again NTFY_TOPIC=topic-abc
check "success after alert: recovery alert (two in all)" test "$(alerts)" -eq 2
check "recovery text" grep -q 'macOS runner: the updater works again' "${L}/curl"
check_not "count cleared" test -e "${S}/update-fails"
check_not "marker cleared" test -e "${S}/update-alerted"
again NTFY_TOPIC=topic-abc
check "next success is quiet" test "$(alerts)" -eq 2
fails 6 NTFY_TOPIC=topic-abc
check "a new run of failures alerts again" test "$(alerts)" -eq 3

echo "== success without an alert"
run_update
fails 3 NTFY_TOPIC=topic-abc
again NTFY_TOPIC=topic-abc
check "no alert and no recovery" test "$(alerts)" -eq 0
check_not "count cleared" test -e "${S}/update-fails"

echo "== a job-waiting pass is not a failure"
run_update
fails 2 NTFY_TOPIC=topic-abc
newrev
printf 'name=mimolette-macos-1\nid=7\nfails=0\nalert=\njob=1\n' >"${S}/slot"
again NTFY_TOPIC=topic-abc
check "waiting leaves the count" test "$(cat "${S}/update-fails")" = 2
again NTFY_TOPIC=topic-abc
check "waiting twice still leaves the count" test "$(cat "${S}/update-fails")" = 2
check "waiting sends nothing" test "$(alerts)" -eq 0
run_update
newrev
printf 'name=mimolette-macos-1\nid=7\nfails=0\nalert=\njob=1\n' >"${S}/slot"
fails 5 NTFY_TOPIC=topic-abc
newrev
again NTFY_TOPIC=topic-abc STUB_PULL_FAIL=
check "waiting between failures does not reach the threshold" test "$(alerts)" -eq 0

echo "== install failure counts"
run_update
newrev
for _ in 1 2 3 4 5 6; do again NTFY_TOPIC=topic-abc STUB_INSTALL_FAIL=1; done
check "6 install failures: one alert" test "$(alerts)" -eq 1
check "alert gives the install reason" grep -q 'Last failure: install.sh failed' "${L}/curl"

echo "== unreadable revision counts"
run_update
: >"${L}/revs"
for _ in 1 2 3 4 5 6; do again NTFY_TOPIC=topic-abc; done
check "6 unreadable revisions: one alert" test "$(alerts)" -eq 1
check "alert gives the revision reason" grep -q 'cannot read the scripts/swm-macos-runner revision' "${L}/curl"

echo "== threshold from the environment"
run_update
fails 2 NTFY_TOPIC=topic-abc SWM_UPDATE_ALERT_AFTER=3
check "below a threshold of 3: no alert" test "$(alerts)" -eq 0
fails 1 NTFY_TOPIC=topic-abc SWM_UPDATE_ALERT_AFTER=3
check "threshold of 3: alert on the 3rd" test "$(alerts)" -eq 1
run_update
fails 6 NTFY_TOPIC=topic-abc SWM_UPDATE_ALERT_AFTER=bogus
check "a bad threshold falls back to 6" test "$(alerts)" -eq 1
check "bad threshold is logged" grep -q 'not a positive number' <<<"${OUT}"

echo "== no topic"
run_update
fails 6
check "no curl without NTFY_TOPIC" test "$(alerts)" -eq 0
check "warning logged" grep -q 'NTFY_TOPIC is unset' <<<"${OUT}"
check "exit 0" test "${RC}" -eq 0
check_not "no marker without a delivered alert" test -e "${S}/update-alerted"

echo "== pending-update backstop"
busy() { printf 'name=mimolette-macos-1\nid=7\nfails=0\nalert=\njob=1\n' >"${S}/slot"; }
pend_alerts() { if [[ -e "${L}/curl" ]]; then grep -c 'an update has been pending' "${L}/curl"; else echo 0; fi; }
run_update
newrev
busy
again NTFY_TOPIC=topic-abc
first="$(cat "${S}/update-pending")"
check "marker holds the epoch it was written" grep -qE '^[0-9]{10,}$' "${S}/update-pending"
again NTFY_TOPIC=topic-abc
check_is "a second waiting pass keeps the first epoch" "${first}" "$(cat "${S}/update-pending")"
check_is "young marker: no alert" 0 "$(pend_alerts)"
printf '%s\n' $(($(date +%s) - 21000)) >"${S}/update-pending"
again NTFY_TOPIC=topic-abc
check_is "just under 6 h: no alert" 0 "$(pend_alerts)"
printf '%s\n' $(($(date +%s) - 21700)) >"${S}/update-pending"
again NTFY_TOPIC=topic-abc
check_is "over 6 h: one alert" 1 "$(pend_alerts)"
check "alert text" grep -q 'macOS runner: an update has been pending for 6 h' "${L}/curl"
check "alert marker written" test -e "${S}/update-pending-alerted"
again NTFY_TOPIC=topic-abc
again NTFY_TOPIC=topic-abc
check_is "later waiting passes stay quiet" 1 "$(pend_alerts)"
printf 'name=\nid=\nfails=0\nalert=\njob=0\n' >"${S}/slot"
again NTFY_TOPIC=topic-abc
check_not "install clears the pending marker" test -e "${S}/update-pending"
check_not "install clears the alert marker" test -e "${S}/update-pending-alerted"
printf '%s\n' "scripts/swm-macos-runner REV3" >"${L}/revs"
busy
again NTFY_TOPIC=topic-abc
printf '%s\n' $(($(date +%s) - 21700)) >"${S}/update-pending"
again NTFY_TOPIC=topic-abc
check_is "a new pending period alerts again" 2 "$(pend_alerts)"
run_update
newrev
printf '%s\n' $(($(date +%s) - 21700)) >"${S}/update-pending"
again NTFY_TOPIC=topic-abc STUB_INSTALL_FAIL=1
check_is "failed install with an old marker: alerts" 1 "$(pend_alerts)"
run_update
newrev
busy
printf '%s\n' $(($(date +%s) - 100)) >"${S}/update-pending"
again NTFY_TOPIC=topic-abc SWM_UPDATE_PENDING_ALERT_S=60
check_is "limit from the environment" 1 "$(pend_alerts)"
run_update
newrev
busy
printf '%s\n' $(($(date +%s) - 21700)) >"${S}/update-pending"
again NTFY_TOPIC=topic-abc STUB_CURL_FAIL=1
check_not "failed delivery: no alert marker" test -e "${S}/update-pending-alerted"
again NTFY_TOPIC=topic-abc
check "failed delivery: the next pass sends it" test -e "${S}/update-pending-alerted"
run_update
newrev
busy
printf 'x\n' >"${S}/update-pending"
again NTFY_TOPIC=topic-abc
check "an old empty-style marker gets an epoch" grep -qE '^[0-9]{10,}$' "${S}/update-pending"
check_is "and does not alert at once" 0 "$(pend_alerts)"

echo "== failed delivery is retried"
run_update
fails 6 NTFY_TOPIC=topic-abc STUB_CURL_FAIL=1
check "delivery failure logged" grep -q 'ntfy delivery failed' <<<"${OUT}"
check_not "no marker after a failed delivery" test -e "${S}/update-alerted"
fails 1 NTFY_TOPIC=topic-abc
check "the next failure sends it" test -e "${S}/update-alerted"

exit "${fail}"
