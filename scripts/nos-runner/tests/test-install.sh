#!/usr/bin/env bash
# install.sh and update.sh in a fake HOME with stub id, launchctl, cp, mv and git: libexec copy, plists, idempotence, restarts.
set -uo pipefail
unset CDPATH
# The caller's environment must not reach real paths or change the rendered values.
unset NOS_ORG NOS_SLOTS NOS_CPUS NOS_MEMORY NOS_LABEL NOS_IMAGE NOS_SHUTDOWN_MAX_S NOS_STATE_DIR NOS_ENV_FILE NOS_CLONE NOS_FROM_UPDATER
unset NTFY_TOPIC NTFY_BASE CONTAINER_BIN CURL_BIN
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

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/../install.sh"
UPDATE="${HERE}/../update.sh"
WORK="${TMPDIR:-/tmp}/nos-install-test-$$"
mkdir -p "${WORK}/bin"
trap 'rm -rf "${WORK:?}"' EXIT

cat >"${WORK}/bin/id" <<'STUB'
#!/usr/bin/env bash
echo "${STUB_UID:-501}"
STUB
cat >"${WORK}/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/launchctl"
if [[ "$1" == bootstrap && -n "${STUB_BOOTSTRAP_FAIL:-}" ]]; then exit 5; fi
if [[ "$1" == kill && -n "${STUB_KICK_FAIL:-}" ]]; then exit 6; fi
exit 0
STUB
# cp and mv log their arguments, then delegate to the real binary.
cat >"${WORK}/bin/cp" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/cp"
exec /bin/cp "$@"
STUB
cat >"${WORK}/bin/mv" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/mv"
exec /bin/mv "$@"
STUB
cat >"${WORK}/bin/container" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/container"
case "$1 $2" in
"image inspect") exit "${STUB_INSPECT_RC:-0}" ;;
build*) exit "${STUB_BUILD_RC:-0}" ;;
esac
exit 0
STUB
cat >"${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/curl"
cat >>"${STUB_LOG}/curl.stdin"
STUB
cat >"${WORK}/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/git"
case " $* " in
*" pull "*) exit "${STUB_PULL_RC:-0}" ;;
*" log "*) echo "${STUB_REV:-rev1}" ;;
esac
STUB
cat >"${WORK}/bin/bash-install" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/install-run"
exit "${STUB_INSTALL_RC:-0}"
STUB
chmod +x "${WORK}"/bin/*

new_home() {
  rm -rf "${WORK:?}/home" "${WORK:?}/log"
  mkdir -p "${WORK}/home" "${WORK}/log"
}
run_install() {
  HOME="${WORK}/home" STUB_LOG="${WORK}/log" ID_BIN="${WORK}/bin/id" LAUNCHCTL_BIN="${WORK}/bin/launchctl" \
    CP_BIN="${WORK}/bin/cp" MV_BIN="${WORK}/bin/mv" CONTAINER_BIN="${WORK}/bin/container" CURL_BIN="${WORK}/bin/curl" bash "${INSTALL}" >"${WORK}/out" 2>"${WORK}/err"
}
run_update() {
  HOME="${WORK}/home" STUB_LOG="${WORK}/log" GIT_BIN="${WORK}/bin/git" BASH_BIN="${WORK}/bin/bash-install" \
    NOS_CLONE="${WORK}/clone" bash "${UPDATE}" >"${WORK}/out" 2>"${WORK}/err"
}
lib="${WORK}/home/.local/libexec/nos-runner"
agents="${WORK}/home/Library/LaunchAgents"
sup="${agents}/com.nightowlstudio.nos-runner.plist"
upd="${agents}/com.nightowlstudio.nos-runner-update.plist"
LC="${WORK}/log/launchctl"
# plutil exists only on macOS; elsewhere the lint check is a no-op.
if command -v plutil >/dev/null 2>&1; then LINT=(plutil -lint -s); else LINT=(true); fi

echo "-- first install"
new_home
rc=0
run_install || rc=$?
check "first install exits 0" test "${rc}" -eq 0
check "install_copies_to_libexec_not_volumes: supervisor.sh" test -x "${lib}/supervisor.sh"
check "install_copies_to_libexec_not_volumes: config.sh" test -f "${lib}/config.sh"
check "install_copies_to_libexec_not_volumes: github-app.sh" test -f "${lib}/github-app.sh"
check "install_copies_to_libexec_not_volumes: update.sh" test -x "${lib}/update.sh"
check_not "libexec has no tests dir" test -e "${lib}/tests"
check_not "libexec has no image dir" test -e "${lib}/image"
check_not "libexec has no net dir" test -e "${lib}/net"
check_not "install_copies_to_libexec_not_volumes: no /Volumes in plists" grep -q /Volumes "${sup}" "${upd}"
check "plists_use_bin_bash: supervisor" grep -qF -- '<string>/bin/bash</string>' "${sup}"
check "plists_use_bin_bash: supervisor runs libexec copy" grep -qF -- "<string>${lib}/supervisor.sh</string>" "${sup}"
check "plists_use_bin_bash: supervisor passes run" grep -qF -- '<string>run</string>' "${sup}"
check "plists_use_bin_bash: updater" grep -qF -- '<string>/bin/bash</string>' "${upd}"
check "plists_use_bin_bash: updater runs libexec copy" grep -qF -- "<string>${lib}/update.sh</string>" "${upd}"
check "supervisor PATH has /opt/homebrew/bin" grep -qF -- '<string>/opt/homebrew/bin:' "${sup}"
check "supervisor logs to Library/Logs" grep -qF -- "${WORK}/home/Library/Logs/nos-runner.log" "${sup}"
check "updater logs to Library/Logs" grep -qF -- "${WORK}/home/Library/Logs/nos-runner-update.log" "${upd}"
check "updater StartInterval 600" grep -qF -- '<integer>600</integer>' "${upd}"
check "supervisor KeepAlive true" grep -qF -- '<key>KeepAlive</key>' "${sup}"
check_not "no @ placeholder left in supervisor plist" grep -q '@[A-Z_]*@' "${sup}"
check_not "no @ placeholder left in updater plist" grep -q '@[A-Z_]*@' "${upd}"
check "supervisor plist lints" "${LINT[@]}" "${sup}"
check "updater plist lints" "${LINT[@]}" "${upd}"
check "bootstrap supervisor" grep -qF -- "bootstrap gui/501 ${sup}" "${LC}"
check "bootstrap updater" grep -qF -- "bootstrap gui/501 ${upd}" "${LC}"
check_not "first install does not HUP" grep -qF -- "kill SIGHUP" "${LC}"
check "warns when NTFY_TOPIC is unset" grep -qF -- 'no NTFY_TOPIC' "${WORK}/err"
check_not "no NTFY_TOPIC key without a topic" grep -qF -- '<key>NTFY_TOPIC</key>' "${sup}"

echo "-- ExitTimeOut follows config.sh"
expected="$(bash -c 'source "$1/config.sh" && echo "${NOS_SHUTDOWN_MAX_S}"' _ "${HERE}/..")"
check "plist_exit_timeout_matches_shutdown_max: config default" grep -qF -- "<integer>${expected}</integer>" "${sup}"
check "plist_exit_timeout_matches_shutdown_max: default exceeds 30" test "${expected}" -gt 30
new_home
NOS_SHUTDOWN_MAX_S=4321 run_install
check "plist_exit_timeout_matches_shutdown_max: env override" grep -qF -- '<integer>4321</integer>' "${sup}"
check "NOS_IMAGE rendered from the Containerfile" grep -qF -- '<key>NOS_IMAGE</key>' "${sup}"

echo "-- idempotent"
new_home
run_install
rm -f "${WORK}/log/launchctl"
run_install
check "install_is_idempotent: second run exits 0" test "$?" -eq 0
check_not "install_is_idempotent: no launchctl call at all" test -s "${WORK}/log/launchctl"

echo "-- script change"
new_home
run_install
echo "# changed" >>"${lib}/supervisor.sh"
ln "${lib}/supervisor.sh" "${WORK}/old-inode"
rm -f "${WORK}/log/launchctl" "${WORK}/log/mv"
run_install
check "script_change_sends_hup: kill SIGHUP" grep -qF -- "kill SIGHUP gui/501/com.nightowlstudio.nos-runner" "${LC}"
check_not "script_change_sends_hup: no bootstrap" grep -qF -- bootstrap "${LC}"
check_not "script_change_sends_hup: no bootout" grep -qF -- bootout "${LC}"
check_not "install_replaces_files_by_new_inode: same file as before" test "${WORK}/old-inode" -ef "${lib}/supervisor.sh"
check "install_replaces_files_by_new_inode: mv onto libexec file" grep -qF -- "${lib}/supervisor.sh" "${WORK}/log/mv"
check "changed file restored to the source" cmp -s "${lib}/supervisor.sh" "${HERE}/../supervisor.sh"
echo "# changed" >>"${lib}/update.sh"
rm -f "${WORK}/log/launchctl"
run_install
check_not "update.sh change alone does not restart the supervisor" test -s "${WORK}/log/launchctl"

echo "-- plist change"
new_home
run_install
echo "<!-- stale -->" >>"${sup}"
echo "# changed" >>"${lib}/supervisor.sh"
rm -f "${WORK}/log/launchctl"
run_install
check "plist change: bootout" grep -qF -- "bootout gui/501/com.nightowlstudio.nos-runner" "${LC}"
check "plist change: bootstrap" grep -qF -- "bootstrap gui/501 ${sup}" "${LC}"
check_not "plist change: no HUP" grep -qF -- "kill SIGHUP" "${LC}"
check_not "plist change: updater untouched" grep -qF -- "${upd}" "${LC}"

echo "-- NTFY_TOPIC"
new_home
NTFY_TOPIC=topic-abc.123 run_install
check "topic from env lands in the supervisor plist" grep -qF -- '<string>topic-abc.123</string>' "${sup}"
check "topic from env is saved to the env file" grep -qF -- 'NTFY_TOPIC=topic-abc.123' "${WORK}/home/.config/nos-runner/env"
check "topic plist lints" "${LINT[@]}" "${sup}"
check_not "topic never printed" grep -qF -- 'topic-abc.123' "${WORK}/out"
rm -f "${WORK}/log/launchctl"
run_install
check_not "later run reads the env file: no launchctl call" test -s "${WORK}/log/launchctl"
new_home
rc=0
NTFY_TOPIC='bad topic<' run_install || rc=$?
check "invalid topic is refused" test "${rc}" -eq 1

echo "-- failures"
new_home
rc=0
STUB_UID=0 run_install || rc=$?
check "refuses root" test "${rc}" -eq 1
new_home
rc=0
STUB_BOOTSTRAP_FAIL=1 run_install || rc=$?
check "bootstrap failure exits 1" test "${rc}" -eq 1
check "bootstrap failure keeps the plist" test -e "${sup}"
rm -f "${LC}"
run_install
check "rerun after a failed bootstrap exits 0" test "$?" -eq 0
check "rerun after a failed bootstrap retries bootstrap" grep -qF -- "bootstrap gui/501 ${sup}" "${LC}"

echo "-- a failed step does not lose the restart"
new_home
run_install
echo "# changed" >>"${lib}/supervisor.sh"
rm -f "${agents}/com.nightowlstudio.nos-runner-update.plist" "${LC}"
rc=0
STUB_BOOTSTRAP_FAIL=1 run_install || rc=$?
check "updater bootstrap failure exits 1" test "${rc}" -eq 1
check "updater bootstrap failure still HUPs the supervisor" grep -qF -- "kill SIGHUP gui/501/com.nightowlstudio.nos-runner" "${LC}"
echo "# changed" >>"${lib}/config.sh"
rm -f "${LC}"
rc=0
STUB_KICK_FAIL=1 run_install || rc=$?
check "HUP failure exits 1" test "${rc}" -eq 1
rm -f "${LC}"
run_install
check "rerun retries the HUP though the files now match" grep -qF -- "kill SIGHUP" "${LC}"
rm -f "${LC}"
run_install
check_not "HUP done: next run calls launchctl no more" test -s "${LC}"

echo "-- image build"
new_home
STUB_INSPECT_RC=1 run_install
check "install_builds_image_when_missing: exit 0" test "$?" -eq 0
check "install_builds_image_when_missing: build -t image dir" grep -qE "^build -t nos-runner:[0-9.]+ .*/scripts/nos-runner/image$" "${WORK}/log/container"
check "install_builds_image_when_missing: inspected first" grep -qE "^image inspect nos-runner:" "${WORK}/log/container"
new_home
run_install
check "install_skips_build_when_present: exit 0" test "$?" -eq 0
check_not "install_skips_build_when_present: no build" grep -q '^build' "${WORK}/log/container"
new_home
rc=0
STUB_INSPECT_RC=1 STUB_BUILD_RC=1 run_install || rc=$?
check "build_failure_fails_install: exit 1" test "${rc}" -eq 1
check "build_failure_fails_install: says so" grep -q 'image build failed' "${WORK}/err"
check_not "build_failure_fails_install: no libexec file" test -e "${lib}/supervisor.sh"
check_not "build_failure_fails_install: no plist" test -e "${sup}"
check_not "build_failure_fails_install: no launchctl call" test -s "${LC}"
new_home
rc=0
STUB_INSPECT_RC=2 run_install || rc=$?
check "inspect failure other than 1 is fatal, no build" test "${rc}" -eq 1
check_not "inspect failure other than 1: no build" grep -q '^build' "${WORK}/log/container"

echo "-- updater never reloads itself"
new_home
run_install
echo "<!-- stale -->" >>"${upd}"
rm -f "${LC}" "${WORK}/log/curl" "${WORK}/log/curl.stdin"
rc=0
NOS_FROM_UPDATER=1 NTFY_TOPIC=topic-abc run_install || rc=$?
check "updater_never_reloads_itself: exit 0" test "${rc}" -eq 0
check_not "updater_never_reloads_itself: no bootout of the updater" grep -qF -- "bootout gui/501/com.nightowlstudio.nos-runner-update" "${LC}"
check_not "updater_never_reloads_itself: no bootstrap of the updater" grep -qF -- "bootstrap gui/501 ${upd}" "${LC}"
check_not "updater_never_reloads_itself: new plist written" grep -q 'stale' "${upd}"
check "updater_never_reloads_itself: logged" grep -q 'updater plist changed; run install.sh by hand' "${WORK}/err"
check "updater_never_reloads_itself: one ntfy" test "$(grep -c . "${WORK}/log/curl" || true)" -eq 1
check "updater_never_reloads_itself: topic via stdin" grep -q 'topic-abc' "${WORK}/log/curl.stdin"
check_not "updater_never_reloads_itself: topic not in argv" grep -q 'topic-abc' "${WORK}/log/curl"
rm -f "${LC}"
NOS_FROM_UPDATER=1 run_install
check_not "updater_never_reloads_itself: next run is quiet" test -s "${LC}"
rm -f "${LC}"
run_install
check "updater_never_reloads_itself: a manual run then loads the new plist" grep -qF -- "bootstrap gui/501 ${upd}" "${LC}"
rm -f "${LC}"
run_install
check_not "updater_never_reloads_itself: and only once" test -s "${LC}"
echo "# changed" >>"${lib}/supervisor.sh"
echo "<!-- stale -->" >>"${sup}"
rm -f "${LC}"
NOS_FROM_UPDATER=1 run_install
check "updater run still reloads the supervisor plist" grep -qF -- "bootstrap gui/501 ${sup}" "${LC}"

echo "-- hardening"
new_home
mkdir -p "${WORK}/home/.config/nos-runner"
echo "NTFY_TOPIC=abc" >"${WORK}/home/.config/nos-runner/env"
chmod 644 "${WORK}/home/.config/nos-runner/env"
run_install
envf="${WORK}/home/.config/nos-runner/env"
mode_ok="$(find "${envf}" -perm 600 || true)"
check "env file is chmod 600 on every install" test -n "${mode_ok}"
chmod 644 "${sup}"
run_install
mode_ok="$(find "${sup}" -perm 600 || true)"
check "plist mode drift is repaired" test -n "${mode_ok}"
new_home
mkdir -p "${WORK}/h&m<e"
HOME="${WORK}/h&m<e" STUB_LOG="${WORK}/log" ID_BIN="${WORK}/bin/id" LAUNCHCTL_BIN="${WORK}/bin/launchctl" \
  CONTAINER_BIN="${WORK}/bin/container" bash "${INSTALL}" >/dev/null 2>&1
check "HOME with & and < is XML-escaped" grep -qF 'h&amp;m&lt;e' "${WORK}/h&m<e/Library/LaunchAgents/com.nightowlstudio.nos-runner.plist"
check "escaped plist lints" "${LINT[@]}" "${WORK}/h&m<e/Library/LaunchAgents/com.nightowlstudio.nos-runner.plist"

echo "-- update.sh"
new_home
mkdir -p "${WORK}/home/.local/state/nos-runner"
echo rev1 >"${WORK}/home/.local/state/nos-runner/installed-rev"
rc=0
STUB_REV=rev1 run_update || rc=$?
check "update_skips_install_when_no_change: exit 0" test "${rc}" -eq 0
check_not "update_skips_install_when_no_change: install not run" test -e "${WORK}/log/install-run"
check "update pulls with --ff-only" grep -qF -- 'pull --ff-only' "${WORK}/log/git"
rc=0
STUB_REV=rev2 run_update || rc=$?
check "update_runs_install_on_change: exit 0" test "${rc}" -eq 0
check "update_runs_install_on_change: install ran" grep -qF -- 'scripts/nos-runner/install.sh' "${WORK}/log/install-run"
check "update_runs_install_on_change: rev recorded" grep -qF -- rev2 "${WORK}/home/.local/state/nos-runner/installed-rev"
rm -f "${WORK}/log/install-run"
STUB_REV=rev2 run_update
check_not "update does not rerun install for a recorded rev" test -e "${WORK}/log/install-run"
rc=0
STUB_PULL_RC=1 STUB_REV=rev3 run_update || rc=$?
check "update_pull_failure_exits_0" test "${rc}" -eq 0
check "update_pull_failure_logs" grep -qF -- 'git pull failed' "${WORK}/err"
check_not "update_pull_failure_skips_install" test -e "${WORK}/log/install-run"
rc=0
STUB_INSTALL_RC=1 STUB_REV=rev4 run_update || rc=$?
check "update_install_failure_exits_0" test "${rc}" -eq 0
check "update_install_failure_keeps_old_rev" grep -qF -- rev2 "${WORK}/home/.local/state/nos-runner/installed-rev"

exit "${fail}"
