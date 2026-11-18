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
    GIT_BIN="${WORK}/bin/git" RM_BIN="${WORK}/bin/rm" STUB_WORK="${WORK}" BASH_BIN="${WORK}/bin/bashstub" "$@" bash "${UPDATE}" 2>&1)"
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

exit "${fail}"
