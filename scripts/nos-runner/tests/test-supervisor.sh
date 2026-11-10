#!/usr/bin/env bash
# supervisor.sh under /bin/bash with stub container, curl, df, rm, security, openssl, launchctl: slots, JIT handoff, failover.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN NOS_TOKEN GITHUB_API_URL NOS_IMAGE NOS_API_STATUS_FILE

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../supervisor.sh"
WORK="${TMPDIR:-/tmp}/nos-runner-sup-test-$$"
BIN="${WORK}/bin"
S="${WORK}/s"
mkdir -p "${BIN}"
trap '/bin/rm -rf "${WORK}"' EXIT

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
# check_eq NAME WANT CMD...: pass when CMD prints WANT.
check_eq() {
  local name="$1" want="$2" got
  shift 2
  got="$("$@")"
  if [[ "${got}" == "${want}" ]]; then _pass "${name}"; else _fail "${name} (got '${got}', want '${want}')"; fi
}
# count PATTERN FILE: matching lines (0 when the file is missing).
count() {
  if [[ ! -f "$2" ]]; then
    echo 0
    return
  fi
  grep -c -E -e "$1" "$2" || true
}

GB=1048576

# container stub: ls lists $S/running; run records the env file (mode, content, path); stop drops the name.
cat >"${BIN}/container" <<STUB
#!/usr/bin/env bash
S="${S}"
echo "\$*" >>"\${S}/container.argv"
case "\$1" in
  ls)
    [[ -z "\${STUB_LS_FAIL:-}" ]] || exit 1
    echo "ID IMAGE OS ARCH STATE ADDR"
    if [[ -f "\${S}/running" ]]; then
      while read -r n; do echo "\${n} nos-runner:2.338.2 linux arm64 running 192.168.64.2"; done <"\${S}/running"
    fi
    ;;
  image)
    [[ "\$2" == inspect && -z "\${STUB_IMAGE_MISSING:-}" ]] || exit 1
    echo '[{}]'
    ;;
  run)
    name=""
    envf=""
    prev=""
    for a in "\$@"; do
      if [[ "\${prev}" == --name ]]; then name="\${a}"; fi
      if [[ "\${prev}" == --env-file ]]; then envf="\${a}"; fi
      prev="\${a}"
    done
    echo "\${envf}" >>"\${S}/envfile.paths"
    if [[ -f "\${envf}" ]]; then
      stat -f %Lp "\${envf}" >>"\${S}/envfile.mode"
      cat "\${envf}" >>"\${S}/envfile.content"
    else
      echo missing >>"\${S}/envfile.mode"
    fi
    [[ -z "\${STUB_RUN_FAIL:-}" ]] || exit 1
    echo "\${name}" >>"\${S}/running"
    echo "\${name}"
    ;;
  stop)
    shift
    for n in "\$@"; do
      grep -vxF -e "\${n}" "\${S}/running" >"\${S}/running.tmp" || true
      cat "\${S}/running.tmp" >"\${S}/running"
    done
    ;;
esac
STUB

# curl stub: routes by method and URL; the org variable lives in $S/var.value (no file = 404).
cat >"${BIN}/curl" <<STUB
#!/usr/bin/env bash
S="${S}"
echo "\$*" >>"\${S}/curl.argv"
method=""
data=""
url=""
hdr_stdin=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -X) method="\$2"; shift 2 ;;
    -d | --data) data="\$2"; shift 2 ;;
    -H) [[ "\$2" == @- ]] && hdr_stdin=1; shift 2 ;;
    -w | --max-time | --retry) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
if [[ "\${hdr_stdin}" -eq 1 ]]; then cat >>"\${S}/curl.stdin"; fi
case "\${url}" in
  https://ntfy.sh/*)
    echo "\${url} \${data}" >>"\${S}/ntfy.log"
    exit 0
    ;;
esac
echo "\${method} \${url} \${data}" >>"\${S}/requests.log"
echo "\${method} \${url} \${data}" >>"${WORK}/all-requests.log"
reply() { printf '%s\n%s' "\$1" "\$2"; }
setvar() { printf '%s' "\${data}" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p' >"\${S}/var.value"; }
case "\${method} \${url}" in
  "POST "*/app/installations/*/access_tokens) reply '{"token":"ghs_stubtok"}' 201 ;;
  "POST "*/actions/runners/generate-jitconfig)
    n=\$((\$(cat "\${S}/jit.n" 2>/dev/null || echo 0) + 1))
    echo "\${n}" >"\${S}/jit.n"
    id=\$((100 + n))
    reply "{\"runner\":{\"id\":\${id},\"name\":\"x\"},\"encoded_jit_config\":\"JITSECRET-\${id}\"}" 201
    ;;
  "GET "*/actions/variables/NOS_RUNNER)
    if [[ -f "\${S}/var.value" ]]; then
      reply "{\"name\":\"NOS_RUNNER\",\"value\":\"\$(cat "\${S}/var.value")\"}" 200
    else
      reply '{"message":"Not Found"}' 404
    fi
    ;;
  "PATCH "*/actions/variables/NOS_RUNNER)
    if [[ -f "\${S}/var.value" ]]; then setvar; reply '' 204; else reply '{"message":"Not Found"}' 404; fi
    ;;
  "POST "*/actions/variables) setvar; reply '' 201 ;;
  "DELETE "*/actions/runners/*) reply '' 204 ;;
  *) reply '{"message":"unexpected"}' 500 ;;
esac
STUB

# df stub: POSIX output; available KB from STUB_DF_AVAIL_KB (default 100 GB).
cat >"${BIN}/df" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/df.argv"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk3s1 500000000 1 \${STUB_DF_AVAIL_KB:-$((100 * GB))} 50% /"
STUB

# rm stub: logs, and deletes only paths inside this test's state dir.
cat >"${BIN}/rm" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/rm.argv"
for a in "\$@"; do
  case "\${a}" in
    "${S}"/*) [[ -f "\${a}" ]] && /bin/rm -f -- "\${a}" ;;
  esac
done
exit 0
STUB

cat >"${BIN}/security" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/security.argv"
printf '%s' 'STUBKEY' | base64
STUB
cat >"${BIN}/openssl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/openssl.argv"
if [[ "\$1" == base64 ]]; then base64 | tr -d '\n'; exit 0; fi
printf 'SIGNATURE'
STUB
cat >"${BIN}/launchctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/launchctl.argv"
STUB
chmod +x "${BIN}"/*

export PATH="${BIN}:${PATH}"
export CONTAINER_BIN="${BIN}/container" CURL_BIN="${BIN}/curl" DF_BIN="${BIN}/df" RM_BIN="${BIN}/rm"
export SECURITY_BIN="${BIN}/security" OPENSSL_BIN="${BIN}/openssl" LAUNCHCTL_BIN="${BIN}/launchctl"
export NOS_STATE_DIR="${S}/state" NOS_PF_OK_FILE="${S}/pf.ok" NOS_DISK_PATH="${S}" NTFY_TOPIC=stubtopic
export NOS_INTERVAL=60

# reset [VAR_VALUE]: fresh state; pf ok file fresh; the org variable set (default mimolette).
reset() {
  /bin/rm -rf "${S}"
  mkdir -p "${S}"
  touch "${S}/pf.ok"
  printf '%s' "${1:-mimolette}" >"${S}/var.value"
}
sup() { /bin/bash "${SCRIPT}" "$@" 2>>"${S}/sup.err"; }
runs() { count '^run ' "${S}/container.argv"; }

echo "-- starts_two_slots_when_healthy"
reset
sup once
check_eq "starts_two_slots_when_healthy: two container runs" 2 runs
check "starts_two_slots_when_healthy: slot 1 name" grep -qE '^run .*--name mimolette-1-[0-9]+ ' "${S}/container.argv"
check "starts_two_slots_when_healthy: slot 2 name" grep -qE '^run .*--name mimolette-2-[0-9]+ ' "${S}/container.argv"
check "starts_two_slots_when_healthy: flags and image" \
  grep -qE '^run -d --rm --name mimolette-1-[0-9]+ -c 4 -m 4g --env-file [^ ]+ nos-runner:2\.338\.2$' "${S}/container.argv"
check "starts_two_slots_when_healthy: jit body" grep -qE \
  '^POST .*/orgs/nightowlstudiollc/actions/runners/generate-jitconfig \{"name":"mimolette-1-[0-9]+","runner_group_id":1,"labels":\["mimolette"\],"work_folder":"_work"\}$' \
  "${S}/requests.log"
check_eq "starts_two_slots_when_healthy: no variable write" 0 count '^(PATCH|POST) .*/actions/variables' "${S}/requests.log"
check_eq "starts_two_slots_when_healthy: no alert" 0 count . "${S}/ntfy.log"
sup once
check_eq "starts_two_slots_when_healthy: second pass starts nothing" 2 runs

echo "-- restarts_slot_after_container_exits"
reset
sup once
slot1="$(grep -o 'mimolette-1-[0-9]*' "${S}/running")"
grep -vxF -e "${slot1}" "${S}/running" >"${S}/running.tmp"
cat "${S}/running.tmp" >"${S}/running"
sup once
check_eq "restarts_slot_after_container_exits: one more run" 3 runs
last_run="$(grep '^run ' "${S}/container.argv" | tail -n 1)"
check "restarts_slot_after_container_exits: the new run is slot 1" grep -qE -e '--name mimolette-1-' <<<"${last_run}"
check "restarts_slot_after_container_exits: old runner deleted" grep -qE '^DELETE .*/orgs/nightowlstudiollc/actions/runners/101 ' "${S}/requests.log"
check_eq "restarts_slot_after_container_exits: two running" 2 count . "${S}/running"

echo "-- container_run_has_no_mount_or_volume_flags"
check "container_run_has_no_mount_or_volume_flags: runs were made" grep -q '^run ' "${S}/container.argv"
check_not "container_run_has_no_mount_or_volume_flags" \
  grep -qE -e '^run .*( )(-v|--volume|--mount)( |=|$)' "${S}/container.argv"

echo "-- jit_not_in_argv"
check "jit_not_in_argv: env file held NOS_JIT" grep -qx 'NOS_JIT=JITSECRET-101' "${S}/envfile.content"
check_not "jit_not_in_argv: no argv carries the JIT" grep -q JITSECRET "${S}"/*.argv
check_eq "jit_not_in_argv: env file was mode 600" 600 sort -u "${S}/envfile.mode"
gone=0
while read -r f; do
  [[ -e "${f}" ]] && gone=1
  grep -q -e "${f}" "${S}/rm.argv" || gone=1
done <"${S}/envfile.paths"
check "jit_not_in_argv: env files removed with RM_BIN" test "${gone}" -eq 0
check_not "jit_not_in_argv: token not in argv" grep -q ghs_stubtok "${S}"/*.argv

echo "-- selfcheck_failure_stops_slots_and_deregisters"
reset
sup once
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "selfcheck_failure_stops_slots_and_deregisters: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check "selfcheck_failure_stops_slots_and_deregisters: PATCH body" grep -qxF \
  'PATCH https://api.github.com/orgs/nightowlstudiollc/actions/variables/NOS_RUNNER {"name":"NOS_RUNNER","value":"ubuntu-latest","visibility":"private"}' \
  "${S}/requests.log"
check_eq "selfcheck_failure_stops_slots_and_deregisters: one alert" 1 count . "${S}/ntfy.log"
check "selfcheck_failure_stops_slots_and_deregisters: alert URL" grep -q '^https://ntfy.sh/stubtopic ' "${S}/ntfy.log"
check "selfcheck_failure_stops_slots_and_deregisters: slot 1 stopped" grep -qE '^stop mimolette-1-[0-9]+$' "${S}/container.argv"
check "selfcheck_failure_stops_slots_and_deregisters: slot 2 stopped" grep -qE '^stop mimolette-2-[0-9]+$' "${S}/container.argv"
check "selfcheck_failure_stops_slots_and_deregisters: runner 101 deleted" grep -qE '^DELETE .*/orgs/nightowlstudiollc/actions/runners/101 ' "${S}/requests.log"
check "selfcheck_failure_stops_slots_and_deregisters: runner 102 deleted" grep -qE '^DELETE .*/orgs/nightowlstudiollc/actions/runners/102 ' "${S}/requests.log"
check_eq "selfcheck_failure_stops_slots_and_deregisters: no new slot" 2 runs
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "selfcheck_failure_stops_slots_and_deregisters: still one alert" 1 count . "${S}/ntfy.log"
check_eq "selfcheck_failure_stops_slots_and_deregisters: one variable write" \
  1 count '^(PATCH|POST) .*/actions/variables' "${S}/requests.log"
STUB_DF_AVAIL_KB=$((20 * GB)) sup once
check_eq "selfcheck_failure_stops_slots_and_deregisters: 20 GB starts slots again" 4 runs

echo "-- no_alert_when_var_already_ubuntu"
reset ubuntu-latest
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "no_alert_when_var_already_ubuntu: no alert" 0 count . "${S}/ntfy.log"
check "no_alert_when_var_already_ubuntu: GET was made" grep -q '^GET .*/actions/variables/NOS_RUNNER' "${S}/requests.log"
check_eq "no_alert_when_var_already_ubuntu: no write" 0 count '^(PATCH|POST) .*/actions/variables' "${S}/requests.log"

echo "-- variable_missing_uses_post"
reset
/bin/rm -f "${S}/var.value"
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check "variable_missing_uses_post: PATCH tried" grep -q '^PATCH .*/actions/variables/NOS_RUNNER ' "${S}/requests.log"
check "variable_missing_uses_post: POST made" grep -qxF \
  'POST https://api.github.com/orgs/nightowlstudiollc/actions/variables {"name":"NOS_RUNNER","value":"ubuntu-latest","visibility":"private"}' \
  "${S}/requests.log"
check_eq "variable_missing_uses_post: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check_eq "variable_missing_uses_post: one alert" 1 count . "${S}/ntfy.log"

echo "-- no_ntfy_topic_warns"
reset
NTFY_TOPIC='' STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "no_ntfy_topic_warns: variable still written" ubuntu-latest cat "${S}/var.value"
check_eq "no_ntfy_topic_warns: no ntfy call" 0 count . "${S}/ntfy.log"
check "no_ntfy_topic_warns: stderr warning" grep -q 'NTFY_TOPIC' "${S}/sup.err"

echo "-- sigterm_sets_ubuntu_then_exits"
reset
/bin/bash "${SCRIPT}" run 2>>"${S}/sup.err" &
pid=$!
i=0
n_runs=0
while [[ "${n_runs}" -lt 2 && "${i}" -lt 100 ]]; do
  sleep 0.1
  ((i += 1))
  n_runs="$(runs)"
done
check_eq "sigterm_sets_ubuntu_then_exits: run started slots" 2 runs
kill -TERM "${pid}" 2>/dev/null
i=0
while kill -0 "${pid}" 2>/dev/null && [[ "${i}" -lt 100 ]]; do
  sleep 0.1
  ((i += 1))
done
exited=0
if kill -0 "${pid}" 2>/dev/null; then
  kill -9 "${pid}" 2>/dev/null
  exited=1
fi
rc=0
wait "${pid}" 2>/dev/null || rc=$?
check "sigterm_sets_ubuntu_then_exits: exited within 10 s" test "${exited}" -eq 0
check "sigterm_sets_ubuntu_then_exits: exit 0" test "${rc}" -eq 0
check_eq "sigterm_sets_ubuntu_then_exits: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check_eq "sigterm_sets_ubuntu_then_exits: one alert" 1 count . "${S}/ntfy.log"

echo "-- three_failed_slot_starts_is_selfcheck_failure"
reset
STUB_RUN_FAIL=1 sup once || true
STUB_RUN_FAIL=1 sup once || true
check_eq "three_failed_slot_starts_is_selfcheck_failure: two failures do not switch" mimolette cat "${S}/var.value"
check_eq "three_failed_slot_starts_is_selfcheck_failure: no alert after two" 0 count . "${S}/ntfy.log"
STUB_RUN_FAIL=1 sup once || true
check_eq "three_failed_slot_starts_is_selfcheck_failure: third failure switches" ubuntu-latest cat "${S}/var.value"
check_eq "three_failed_slot_starts_is_selfcheck_failure: one alert" 1 count . "${S}/ntfy.log"
check_eq "three_failed_slot_starts_is_selfcheck_failure: failed runners deleted" \
  6 count '^DELETE .*/actions/runners/' "${S}/requests.log"
left=0
while read -r f; do [[ -e "${f}" ]] && left=1; done <"${S}/envfile.paths"
check "three_failed_slot_starts_is_selfcheck_failure: env files removed on failure" test "${left}" -eq 0

echo "-- stale_or_missing_pf_ok_file_starts_no_slot"
reset
/bin/rm -f "${S}/pf.ok"
sup once || true
check_eq "stale_or_missing_pf_ok_file_starts_no_slot: missing starts no slot" 0 runs
check_eq "stale_or_missing_pf_ok_file_starts_no_slot: missing switches to ubuntu" ubuntu-latest cat "${S}/var.value"
reset
touch -t 202001010000 "${S}/pf.ok"
sup once || true
check_eq "stale_or_missing_pf_ok_file_starts_no_slot: stale starts no slot" 0 runs
check_eq "stale_or_missing_pf_ok_file_starts_no_slot: stale switches to ubuntu" ubuntu-latest cat "${S}/var.value"

echo "-- other self-checks"
reset
STUB_LS_FAIL=1 sup once || true
check_eq "apiserver_down_is_selfcheck_failure" ubuntu-latest cat "${S}/var.value"
reset
STUB_IMAGE_MISSING=1 sup once || true
check_eq "missing_image_is_selfcheck_failure" ubuntu-latest cat "${S}/var.value"
check_eq "missing_image_starts_no_slot" 0 runs

echo "-- never_writes_mimolette"
writes="$(grep -E '^(PATCH|POST) [^ ]*/actions/variables' "${WORK}/all-requests.log")"
check "never_writes_mimolette: variable writes were logged" test -n "${writes}"
check_not "never_writes_mimolette" grep -q mimolette <<<"${writes}"
check_not "never_writes_mimolette: launchctl unused" test -e "${S}/launchctl.argv"

echo "-- config"
img="$(
  unset NOS_IMAGE
  # shellcheck source=SCRIPTDIR/../config.sh
  source "${HERE}/../config.sh"
  echo "${NOS_IMAGE}"
)"
check "image_tag_from_containerfile" test "${img}" = nos-runner:2.338.2

exit "${fail}"
