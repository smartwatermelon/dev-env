#!/usr/bin/env bash
# install.sh and uninstall.sh in a fake root, all system commands stubbed.
set -uo pipefail
unset CDPATH
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}
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
SRC="${HERE}/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-ro-install-test.XXXXXX")" || exit 1
[[ -d "${WORK}" ]] || exit 1
trap 'rm -rf "${WORK:?}"' EXIT
B="${WORK}/bin"
R="${WORK}/root"
S="${WORK}/state"
mkdir -p "${B}" "${S}"
CALLS="${WORK}/calls"

# stub NAME <<'EOF' ... EOF: a logging stub whose body comes from stdin; it
# sees $S (flag files) and $R (the fake root).
stub() {
  {
    printf '#!/usr/bin/env bash\nS=%q\nR=%q\necho "%s $*" >>%q\n' "${S}" "${R}" "$1" "${CALLS}"
    cat
  } >"${B}/$1"
  chmod +x "${B}/$1"
}
stub id <<'EOF'
if [[ "$*" == "-u" ]]; then cat "$S/uid"; exit 0; fi
case "$*" in
  "-u andrewrich") echo 501 ;;
  "agentro" | "-u agentro")
    [[ -f "$S/user" ]] || exit 1
    if [[ "$1" == "-u" ]]; then echo 502; fi
    ;;
  *) exit 1 ;;
esac
EOF
stub sysadminctl <<'EOF'
case "$1" in -addUser) touch "$S/user" ;; -deleteUser) rm -f "$S/user" ;; esac
EOF
stub dscl <<'EOF'
case "$*" in
  ". -read /Groups/agentro") [[ -f "$S/group" ]] ;;
  ". -read /Groups/agentro PrimaryGroupID") echo "PrimaryGroupID: 502" ;;
  ". -list /Groups PrimaryGroupID") printf "staff 20\nadmin 80\n" ;;
  ". -read /Groups/com.apple.access_ssh") exit 0 ;;
  *) exit 0 ;;
esac
EOF
stub dseditgroup <<'EOF'
case "$2" in
  checkmember) if [[ -f "$S/admin_err" ]]; then echo "Group not found."; exit 64; elif [[ -f "$S/admin" ]]; then echo "yes agentro is a member of admin"; else echo "no agentro is NOT a member of admin"; exit 1; fi ;;
  create) touch "$S/group" ;;
  delete) rm -f "$S/group" ;;
esac
EOF
stub createhomedir <<'EOF'
mkdir -p "$R/Users/agentro"
EOF
stub chown <<'EOF'
:
EOF
stub openssl <<'EOF'
echo not-a-real-password
EOF
stub stat <<'EOF'
cat "$S/stat" 2>/dev/null || echo "0 755"
EOF
# print reports the job loaded for $S/loaded more calls (a draining sweep).
stub launchctl <<'EOF'
if [[ "$1" == print ]]; then
  n="$(cat "$S/loaded" 2>/dev/null || echo 0)"
  if [[ "$n" -gt 0 ]]; then echo "$((n - 1))" >"$S/loaded"; exit 0; fi
  exit 113
fi
if [[ "$1" == bootstrap && -f "$S/bootstrap-fail" ]]; then exit 5; fi
EOF
stub sleep <<'EOF'
:
EOF
stub pkill <<'EOF'
:
EOF
stub visudo <<'EOF'
[[ ! -f "$S/visudo-fail" ]]
EOF
# sshd stub: fixed owner block; agentro settings once the drop-in exists; flags fake bad drop-ins.
stub sshd <<'EOF'
conf="$R/etc/ssh/sshd_config.d/200-agent-ro.conf"
case "$*" in
  "-t") [[ ! -f "$S/sshd-t-fail" ]] ;;
  *user=andrewrich*) echo "permittty yes"; [[ -f "$conf" && -f "$S/sshd-leak" ]] && echo "subsystem none"; exit 0 ;;
  *user=agentro*) if [[ -f "$conf" ]]; then printf "permittty no\npasswordauthentication no\ndisableforwarding yes\nauthenticationmethods publickey\nauthorizedkeysfile /etc/ssh/agent-ro/authorized_keys\n"; else echo "permittty yes"; fi ;;
esac
EOF
# sudo stub for the self-test: reads and the gate work, the rest fails, unless a flag breaks it.
stub sudo <<'EOF'
[[ "$1" == "-u" ]] || exit 1
who="$2"; shift 2
[[ "$who" == "andrewrich" ]] && { [[ -f "$S/sweep-rc" ]] && exit "$(cat "$S/sweep-rc")"; exit 0; }
case "$*" in
  "/bin/ls /Users/andrewrich") exit 0 ;;
  "/bin/ls /Users/andrewrich/.ssh") exit 1 ;;
  "/usr/bin/touch "*) [[ -f "$S/can-write" ]] ;;
  *"/gate help") exit 0 ;;
  *) exit 1 ;;
esac
EOF
# in_root: path under $R with no ".." part. No realpath -m on macOS; $R has no symlinks.
cat >"${WORK}/in_root.sh" <<'EOF'
in_root() { case "$1" in "$R"/*) ;; *) return 1 ;; esac; case "/$1/" in */../*) return 1 ;; esac; }
EOF
# rm/rmdir act only inside the fake root; any other path is refused, never deleted.
stub rm <"${WORK}/in_root.sh"
cat >>"${B}/rm" <<'EOF'
for a in "$@"; do case "$a" in -*) continue ;; esac; in_root "$a" || { echo "rm stub: refused $a" >&2; exit 97; }; done
/bin/rm "$@"
EOF
stub rmdir <"${WORK}/in_root.sh"
cat >>"${B}/rmdir" <<'EOF'
for a in "$@"; do in_root "$a" || { echo "rmdir stub: refused $a" >&2; exit 97; }; done
/bin/rmdir "$@"
EOF
# install: a small stand-in for BSD install (-d, -m; -o/-g ignored).
stub install <"${WORK}/in_root.sh"
cat >>"${B}/install" <<'EOF'
dir=0 mode=""
while [[ $# -gt 0 ]]; do case "$1" in -d) dir=1; shift ;; -o|-g) shift 2 ;; -m) mode="$2"; shift 2 ;; *) break ;; esac; done
if [[ $dir == 1 ]]; then
  for a in "$@"; do in_root "$a" || { echo "install stub: refused $a" >&2; exit 97; }; done
  mkdir -p "$@"; exit
fi
in_root "$2" || { echo "install stub: refused $2" >&2; exit 97; }
/bin/rm -f "$2" && cp "$1" "$2" && { [[ -z "$mode" ]] || chmod "$mode" "$2"; }
EOF
echo "-- stubs refuse paths outside the fake root"
mkdir -p "${WORK}/keep" "${R}"
: >"${WORK}/keep/f"
"${B}/rm" -f "${R}/../keep/f" 2>/dev/null
check "rm stub refuses \$R/.." test -f "${WORK}/keep/f"
"${B}/install" "${KEY:-/dev/null}" "${R}/../keep/f" 2>/dev/null
check "install stub refuses \$R/.." test "$?" -eq 97

env_for_tests() {
  INSTALL_ROOT="${R}" ID_BIN="${B}/id" SYSADMINCTL_BIN="${B}/sysadminctl" DSCL_BIN="${B}/dscl" \
    DSEDITGROUP_BIN="${B}/dseditgroup" CREATEHOMEDIR_BIN="${B}/createhomedir" INSTALL_BIN="${B}/install" \
    CHOWN_BIN="${B}/chown" VISUDO_BIN="${B}/visudo" SSHD_BIN="${B}/sshd" LAUNCHCTL_BIN="${B}/launchctl" \
    SUDO_BIN="${B}/sudo" RM_BIN="${B}/rm" RMDIR_BIN="${B}/rmdir" PKILL_BIN="${B}/pkill" SLEEP_BIN="${B}/sleep" OPENSSL_BIN="${B}/openssl" STAT_BIN="${B}/stat" "$@"
}
reset() {
  rm -rf "${R:?}" "${S:?}"
  mkdir -p "${R}/etc/ssh/sshd_config.d" "${R}/etc/sudoers.d" "${R}/usr/local/libexec" "${R}/Library/LaunchDaemons" "${S}"
  printf '#includedir /private/etc/sudoers.d\n' >"${R}/etc/sudoers"
  echo 0 >"${S}/uid"
  : >"${CALLS}"
}
inst() { env_for_tests bash "${SRC}/install.sh" "$@" >"${WORK}/out" 2>&1; }

KEY="${WORK}/asiago.pub"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly agentro@asiago" >"${KEY}"
SUDOERS="${R}/etc/sudoers.d/agent-ro"
SSHD_CONF="${R}/etc/ssh/sshd_config.d/200-agent-ro.conf"
AK="${R}/etc/ssh/agent-ro/authorized_keys"

echo "-- fresh install"
reset
inst --pubkey "${KEY}" --from "192.168.1.0/24"
rc=$?
check "exit 0" test "${rc}" -eq 0
[[ "${rc}" -eq 0 ]] || cat "${WORK}/out" >&2
check "user created" grep -q "^sysadminctl -addUser agentro " "${CALLS}"
check "own group with GID 502" grep -q "^dseditgroup -o create -i 502 " "${CALLS}"
check "primary group set" grep -q "^dscl . -create /Users/agentro PrimaryGroupID 502" "${CALLS}"
check "hidden" grep -q "^dscl . -create /Users/agentro IsHidden 1" "${CALLS}"
check "Remote Login allowed" grep -q "^dseditgroup -o edit -a agentro -t user com.apple.access_ssh" "${CALLS}"
check "key line has restrict and from" grep -qx 'restrict,from="192.168.1.0/24" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly agentro@asiago' "${AK}"
check "sudoers allows the gate only" grep -qx 'agentro ALL=(root) NOPASSWD: /usr/local/libexec/agent-ro/gate' "${SUDOERS}"
# saw_none NAME STATUS: pass when the command before it found nothing (status 1).
saw_none() { if [[ "$2" == 1 ]]; then _pass "$1"; else _fail "$1"; fi; }
other_rules() { grep -v -e '^#' -e '^Defaults' -e '^agentro ALL=(root) NOPASSWD: /usr/local/libexec/agent-ro/gate$' "${SUDOERS}"; }
other_rules; saw_none "sudoers has no other rule" $?
check "sshd drop-in matches agentro" grep -qx 'Match User agentro' "${SSHD_CONF}"
check "sshd drop-in ends the Match" grep -qx 'Match all' "${SSHD_CONF}"
check "gate installed" test -x "${R}/usr/local/libexec/agent-ro/gate"
check "plist installed" test -f "${R}/Library/LaunchDaemons/com.smartwatermelon.agent-ro-sweep.plist"
check "sweep run as owner" grep -q "^sudo -u andrewrich /bin/bash ${R}/usr/local/libexec/agent-ro/sweep.sh --full" "${CALLS}"
check "job loaded" grep -q "^launchctl bootstrap system " "${CALLS}"
check "self-test passed" grep -q "PASS sudo outside the gate: denied" "${WORK}/out"
check_not "home not chowned recursively" grep -q "^chown -R" "${CALLS}"
test_at="$(grep -n "^sudo -u agentro" "${CALLS}" | tail -1 | cut -d: -f1)"
key_at="$(grep -n "^install .*/authorized_keys " "${CALLS}" | tail -1 | cut -d: -f1)"
check "keys installed after the self-test" test "${test_at:-999}" -lt "${key_at:-0}"

echo "-- re-run without --pubkey keeps the keys"
: >"${CALLS}"
inst
rc=$?
check "exit 0" test "${rc}" -eq 0
check_not "no second user" grep -q "^sysadminctl -addUser" "${CALLS}"
check "keys kept" grep -q "AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly" "${AK}"

echo "-- a failure after the keys exist removes them"
touch "${S}/bootstrap-fail"
inst
check "re-run, bootstrap fails: exit 1" test "$?" -eq 1
check_not "re-run, bootstrap fails: keys removed" test -e "${AK}"

echo "-- refusals"
reset
echo 501 >"${S}/uid"
inst --pubkey "${KEY}"
check "not root: exit 1" test "$?" -eq 1
check_not "not root: no user" grep -q "^sysadminctl" "${CALLS}"

reset
inst --pubkey "${KEY}" --from '1.2.3.4" command="/bin/sh'
check "quote in --from: exit 1" test "$?" -eq 1

reset
inst --from "192.168.1.0/24"
check "--from without --pubkey: exit 1" test "$?" -eq 1

reset
echo 'command="/bin/sh" ssh-ed25519 AAAAC3Nza agentro' >"${WORK}/opts.pub"
inst --pubkey "${WORK}/opts.pub"
check "key with options: exit 1" test "$?" -eq 1
check_not "key with options: no key list" test -f "${AK}"

reset
touch "${S}/admin" "${S}/user"
inst --pubkey "${KEY}"
check "admin account: exit 1" test "$?" -eq 1

reset
touch "${S}/admin_err" "${S}/user"
inst --pubkey "${KEY}"
check "admin check fails: exit 1" test "$?" -eq 1
check_not "admin check fails: no key list" test -f "${AK}"

reset
echo "501 755" >"${S}/stat"
inst --pubkey "${KEY}"
check "gate folder not root-owned: exit 1" test "$?" -eq 1
check_not "gate folder not root-owned: nothing installed" test -e "${R}/usr/local/libexec/agent-ro/gate"

echo "-- a bad sshd drop-in is removed and sudo stays untouched"
reset
touch "${S}/sshd-t-fail"
inst --pubkey "${KEY}"
check "sshd -t failure: exit 1" test "$?" -eq 1
check_not "sshd -t failure: drop-in removed" test -e "${SSHD_CONF}"
check_not "sshd -t failure: no sudoers" test -e "${SUDOERS}"
reset
touch "${S}/sshd-leak"
inst --pubkey "${KEY}"
check "owner settings changed: exit 1" test "$?" -eq 1
check_not "owner settings changed: drop-in removed" test -e "${SSHD_CONF}"

echo "-- visudo rejects: no sudoers file"
reset
touch "${S}/visudo-fail"
inst --pubkey "${KEY}"
check "exit 1" test "$?" -eq 1
check_not "no sudoers" test -e "${SUDOERS}"

echo "-- a failed sweep stops the install, no keys"
reset
echo 1 >"${S}/sweep-rc"
inst --pubkey "${KEY}"
check "sweep fails: exit 1" test "$?" -eq 1
check_not "sweep fails: no key list" test -e "${AK}"
check_not "sweep fails: job not loaded" grep -q "^launchctl bootstrap" "${CALLS}"

echo "-- sweep exit 4 (locked folders only) warns and installs"
reset
echo 4 >"${S}/sweep-rc"
inst --pubkey "${KEY}"
check "sweep gaps: exit 0" test "$?" -eq 0
check "sweep gaps: warns" grep -q "allow pass failed on some entries" "${WORK}/out"
check "sweep gaps: keys installed" test -f "${AK}"

echo "-- bootstrap fails: no keys"
reset
touch "${S}/bootstrap-fail"
inst --pubkey "${KEY}"
check "bootstrap fails: exit 1" test "$?" -eq 1
check_not "bootstrap fails: no key list" test -e "${AK}"

echo "-- self-test catches a writable home"
reset
touch "${S}/can-write"
inst --pubkey "${KEY}"
check "exit 1" test "$?" -eq 1
check "says FAIL" grep -q "FAIL create a file" "${WORK}/out"
check_not "keys removed after a failed self-test" test -e "${AK}"

echo "-- waits for a draining sweep before bootstrap"
reset
echo 3 >"${S}/loaded"
inst --pubkey "${KEY}"
check "exit 0" test "$?" -eq 0
waits="$(grep -c "^sleep 1" "${CALLS}")"
check "slept while the job drained" test "${waits}" -eq 3
last_sleep="$(grep -n "^sleep 1" "${CALLS}" | tail -1 | cut -d: -f1)"
boot_at="$(grep -n "^launchctl bootstrap" "${CALLS}" | head -1 | cut -d: -f1)"
check "drained before bootstrap" test "${last_sleep:-999}" -lt "${boot_at:-0}"

echo "-- uninstall"
reset
inst --pubkey "${KEY}"
env_for_tests bash "${SRC}/uninstall.sh" >/dev/null 2>&1
check "without --yes: exit 1" test "$?" -eq 1
check "without --yes: user kept" test -f "${S}/user"
env_for_tests bash "${SRC}/uninstall.sh" --yes >"${WORK}/out" 2>&1
check "with --yes: exit 0" test "$?" -eq 0
check_not "sudoers removed" test -e "${SUDOERS}"
check_not "sshd drop-in removed" test -e "${SSHD_CONF}"
check_not "gate removed" test -e "${R}/usr/local/libexec/agent-ro/gate"
check_not "user deleted" test -f "${S}/user"
kill_at="$(grep -n "^pkill -KILL -u agentro" "${CALLS}" | head -1 | cut -d: -f1)"
del_at="$(grep -n "^sysadminctl -deleteUser" "${CALLS}" | head -1 | cut -d: -f1)"
check "agentro processes stopped before the user is deleted" test "${kill_at:-999}" -lt "${del_at:-0}"
check_not "group deleted" test -f "${S}/group"

exit "${fail}"
