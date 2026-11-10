#!/usr/bin/env bash
# install-pf.sh with stub id, install and launchctl: root check, install targets, bootstrap.
set -uo pipefail
unset CDPATH
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
SCRIPT="${HERE}/../net/install-pf.sh"
WORK="${TMPDIR:-/tmp}/nos-installpf-test-$$"
mkdir -p "${WORK}/bin"
trap 'rm -rf "${WORK:?}"' EXIT

cat >"${WORK}/bin/id" <<'STUB'
#!/usr/bin/env bash
echo "${STUB_UID}"
STUB
# install stub: log argv, drop owner flags (non-root cannot chown), delegate to the real install.
cat >"${WORK}/bin/install" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/install"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  -o | -g) shift 2 ;;
  *) args+=("$1"); shift ;;
  esac
done
/usr/bin/install "${args[@]}"
STUB
cat >"${WORK}/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/launchctl"
STUB
chmod +x "${WORK}/bin/id" "${WORK}/bin/install" "${WORK}/bin/launchctl"

run() {
  rm -rf "${WORK:?}/root" "${WORK:?}/log"
  mkdir -p "${WORK}/root" "${WORK}/log"
  STUB_UID="$1" STUB_LOG="${WORK}/log" ID_BIN="${WORK}/bin/id" INSTALL_BIN="${WORK}/bin/install" \
    LAUNCHCTL_BIN="${WORK}/bin/launchctl" INSTALL_ROOT="${WORK}/root" bash "${SCRIPT}" >"${WORK}/out" 2>"${WORK}/err"
}
guard="${WORK}/root/usr/local/libexec/nos-runner/pf-guard.sh"
plist="${WORK}/root/Library/LaunchDaemons/com.nightowlstudio.nos-runner-pf.plist"

echo "-- install-pf refuses a non-root uid"
rc=0
run 501 || rc=$?
check "exit 1 as uid 501" test "${rc}" -eq 1
check_not "nothing installed" test -e "${guard}"
check_not "launchctl not called" test -e "${WORK}/log/launchctl"
check "stderr says run as root" grep -q 'root' "${WORK}/err"

echo "-- install-pf as uid 0"
rc=0
run 0 || rc=$?
check "exit 0 as uid 0" test "${rc}" -eq 0
check "guard installed under INSTALL_ROOT" test -e "${guard}"
check "rules installed" test -e "${WORK}/root/usr/local/libexec/nos-runner/nos-runner.pf"
check "plist installed" test -e "${plist}"
check "guard installed root:wheel mode 0755" grep -q -- "-o root -g wheel -m 0755 .*pf-guard.sh" "${WORK}/log/install"
check "bootstrap into system" grep -q -- "bootstrap system ${plist}" "${WORK}/log/launchctl"

exit "${fail}"
