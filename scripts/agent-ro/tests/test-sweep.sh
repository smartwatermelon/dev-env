#!/usr/bin/env bash
# sweep.sh in a fake home: real find, recording chmod stub.
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
# saw NAME STATUS / saw_not NAME STATUS: for the has/touched helpers.
saw() { if [[ "$2" == 0 ]]; then _pass "$1"; else _fail "$1"; fi; }
saw_not() { if [[ "$2" == 0 ]]; then _fail "$1"; else _pass "$1"; fi; }
check_not() {
  local name="$1"
  shift
  if "$@"; then _fail "${name}"; else _pass "${name}"; fi
}

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-ro-sweep-test.XXXXXX")" || exit 1
[[ -d "${WORK}" ]] || exit 1
# Direct rm is safe here: WORK is a fresh mktemp dir, checked above; H is WORK/home.
trap 'rm -rf "${WORK:?}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/libexec"
ME="$(id -un)"
H="${WORK}/home"
LOG="${WORK}/chmod.log"
REALPATH="$(command -v realpath)"

# chmod +a ACE PATH...: one line per path, "ACE<TAB>PATH"; bumps ctime as the real one does.
cat >"${WORK}/bin/chmod" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "+a" ]] || { echo "unexpected chmod $*" >&2; exit 9; }
ace="$2"; shift 2
for p in "$@"; do
  printf '%s\t%s\n' "${ace}" "${p}" >>"${STUB_LOG}"
  # Like chmod +a, change the status time (ctime) without changing access.
  touch -a "${p}"
done
STUB
chmod +x "${WORK}/bin/chmod"
cat >"${WORK}/bin/chmod-fail" <<'STUB'
#!/usr/bin/env bash
echo "chmod: Operation not permitted" >&2
exit 1
STUB
chmod +x "${WORK}/bin/chmod-fail"

cp "${SRC}/sweep.sh" "${WORK}/libexec/sweep.sh"
sed -e "s|^export AGENT_RO_OWNER=.*|export AGENT_RO_OWNER=\"${ME}\"|" \
  -e "s|^export AGENT_RO_OWNER_HOME=.*|export AGENT_RO_OWNER_HOME=\"${H}\"|" \
  "${SRC}/config.sh" >"${WORK}/libexec/config.sh"
grep -q "^export AGENT_RO_OWNER_HOME=\"${H}\"" "${WORK}/libexec/config.sh" || _fail "test setup: home rewrite missed"

ALLOW_DIR="user:agentro allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
ALLOW_FILE="user:agentro allow read,execute,readattr,readextattr,readsecurity"
DENY_DIR="user:agentro deny list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
DENY_FILE="user:agentro deny read,execute,readattr,readextattr,readsecurity"
NOWRITE_DIR="user:agentro deny add_file,add_subdirectory,delete_child,delete,writeattr,writeextattr,writesecurity,chown,file_inherit,directory_inherit"
NOWRITE_FILE="user:agentro deny write,append,delete,writeattr,writeextattr,writesecurity,chown"

make_home() {
  rm -rf "${H:?}"
  mkdir -p "${H}/Library/Mobile Documents/com~apple~CloudDocs" "${H}/dir" "${H}/.ssh" "${H}/.claude" \
    "${H}/Library/CloudStorage/GoogleDrive" "${H}/Library/Group Containers/2BUA8C4S2C.com.1password" "${WORK}/outside"
  echo i >"${H}/Library/Mobile Documents/com~apple~CloudDocs/doc"
  echo a >"${H}/a.txt"
  echo b >"${H}/dir/b.txt"
  echo k >"${H}/.ssh/id_ed25519"
  echo c >"${H}/.claude/.credentials.json"
  echo s >"${H}/.claude/settings.json"
  echo g >"${H}/Library/CloudStorage/GoogleDrive/doc"
  echo o >"${H}/Library/Group Containers/2BUA8C4S2C.com.1password/data"
  echo x >"${WORK}/outside/target"
  ln -s "${WORK}/outside/target" "${H}/link-out"
  ln -s "${WORK}/outside" "${H}/dirlink-out"
  ln -s "${H}/a.txt" "${H}/.npmrc"
  ln -s "${WORK}/outside/target" "${H}/.netrc"
}

run_sweep() {
  : >"${LOG}"
  STUB_LOG="${LOG}" CHMOD_BIN="${WORK}/bin/chmod" REALPATH_BIN="${REALPATH}" bash "${WORK}/libexec/sweep.sh" "$@"
}
has() { grep -qxF "$1"$'\t'"$2" "${LOG}"; }
touched() { grep -q $'\t'"$1"'$' "${LOG}"; }

echo "-- full sweep"
make_home
run_sweep --full
rc=$?
# Exit 1: the .netrc fixture links outside the home, so that credential is not denied.
check "exit 1 for a deny symlink outside the home" test "${rc}" -eq 1
has "${ALLOW_DIR}" "${H}"
saw "allow on home" $?
has "${ALLOW_DIR}" "${H}/dir"
saw "allow on subfolder" $?
has "${ALLOW_FILE}" "${H}/a.txt"
saw "allow on file" $?
has "${ALLOW_FILE}" "${H}/dir/b.txt"
saw "allow on nested file" $?
has "${ALLOW_DIR}" "${H}/.claude"
saw "allow on .claude" $?
has "${ALLOW_FILE}" "${H}/.claude/settings.json"
saw "allow on .claude/settings.json" $?
has "${ALLOW_DIR}" "${H}/.ssh"
saw_not "no allow on .ssh" $?
has "${ALLOW_FILE}" "${H}/.ssh/id_ed25519"
saw_not "no allow on ssh key" $?
has "${ALLOW_FILE}" "${H}/.claude/.credentials.json"
saw_not "no allow on Claude credentials" $?
has "${DENY_DIR}" "${H}/.ssh"
saw "deny on .ssh" $?
has "${DENY_FILE}" "${H}/.ssh/id_ed25519"
saw "deny on ssh key" $?
has "${DENY_FILE}" "${H}/.claude/.credentials.json"
saw "deny on Claude credentials" $?
has "${DENY_FILE}" "${H}/Library/Group Containers/2BUA8C4S2C.com.1password/data"
saw "deny on path with spaces" $?
touched "${H}/Library/CloudStorage/GoogleDrive/doc"
saw_not "CloudStorage not walked" $?
touched "${H}/Library/CloudStorage"
saw_not "CloudStorage folder untouched" $?
has "${NOWRITE_DIR}" "${H}"
saw "no-write on home" $?
has "${NOWRITE_FILE}" "${H}/a.txt"
saw "no-write on file" $?
touched "${H}/Library/Mobile Documents"
saw_not "iCloud folder not walked" $?
touched "${H}/Library/Mobile Documents/com~apple~CloudDocs/doc"
saw_not "iCloud file not walked" $?
touched "${H}/link-out"
saw_not "file symlink untouched" $?
touched "${H}/dirlink-out"
saw_not "folder symlink untouched" $?
check_not "symlink target untouched" grep -q "${WORK}/outside" "${LOG}"
touched "${H}/.npmrc"
saw_not "deny-list symlink itself untouched" $?
real_a="$("${REALPATH}" "${H}/a.txt")"
has "${DENY_FILE}" "${real_a}"
saw "deny-list symlink: target in home denied" $?
check "deny-list symlink: target outside home reported" grep -q "skipped symlink ${H}/.netrc" "${H}/.local/state/agent-ro/last-errors"
last_allow="$(grep -n 'allow' "${LOG}" | tail -1 | cut -d: -f1)"
first_deny="$(grep -n -e 'deny list,' -e 'deny read,' "${LOG}" | head -1 | cut -d: -f1)"
check "deny pass runs after allow pass" test "${last_allow}" -lt "${first_deny}"
check "full stamp written" test -s "${H}/.local/state/agent-ro/last-full"
check "log line written" grep -q "mode=full full=1 rc=1" "${H}/Library/Logs/agent-ro-sweep.log"

echo "-- a second run within the week touches only what changed"
# Allow pass due (old last-full) but incremental: the run above left a fresh allow-stamp.
mkdir -p "${H}/.local/state/agent-ro"
echo 1000 >"${H}/.local/state/agent-ro/last-full"
echo n >"${H}/dir/new.txt"
echo k2 >"${H}/.ssh/new_key"
run_sweep
has "${ALLOW_FILE}" "${H}/dir/new.txt"
saw "new file gets read" $?
touched "${H}/a.txt"
saw_not "unchanged file left alone" $?
has "${DENY_FILE}" "${H}/.ssh/new_key"
saw "new file in a deny folder denied" $?
touched "${H}/.ssh/id_ed25519"
saw_not "unchanged deny file left alone" $?

echo "-- a failed deny is retried: the deny stamp does not move"
rm -f "${H}/.local/state/agent-ro/deny-stamp"
STUB_LOG="${LOG}" CHMOD_BIN="${WORK}/bin/chmod-fail" REALPATH_BIN="${REALPATH}" \
  bash "${WORK}/libexec/sweep.sh" --deny-only 2>/dev/null
check_not "no deny stamp after a failure" test -e "${H}/.local/state/agent-ro/deny-stamp"

echo "-- deny only"
make_home
run_sweep --deny-only
check_not "no allow entries" grep -q allow "${LOG}"
has "${DENY_FILE}" "${H}/.ssh/id_ed25519"
saw "deny on ssh key" $?

echo "-- auto: recent full sweep means deny pass only"
make_home
mkdir -p "${H}/.local/state/agent-ro"
date +%s >"${H}/.local/state/agent-ro/last-full"
run_sweep
check_not "no allow entries" grep -q allow "${LOG}"
has "${DENY_DIR}" "${H}/.ssh"
saw "deny entries" $?

echo "-- auto: old or broken stamp means a full sweep"
make_home
mkdir -p "${H}/.local/state/agent-ro"
echo 1000 >"${H}/.local/state/agent-ro/last-full"
run_sweep
has "${ALLOW_FILE}" "${H}/a.txt"
saw "allow entries after old stamp" $?
make_home
mkdir -p "${H}/.local/state/agent-ro"
echo garbage >"${H}/.local/state/agent-ro/last-full"
run_sweep
has "${ALLOW_FILE}" "${H}/a.txt"
saw "allow entries after broken stamp" $?

echo "-- a failing chmod is logged, and the stamp is still written"
make_home
STUB_LOG="${LOG}" CHMOD_BIN="${WORK}/bin/chmod-fail" bash "${WORK}/libexec/sweep.sh" --full
rc=$?
check "exit 1" test "${rc}" -eq 1
check "errors counted" grep -q "rc=1 errors=[1-9]" "${H}/Library/Logs/agent-ro-sweep.log"
check "stamp still written" test -s "${H}/.local/state/agent-ro/last-full"

echo "-- refuses the wrong user and unknown options"
make_home
cat >"${WORK}/bin/id-other" <<'STUB'
#!/usr/bin/env bash
echo someoneelse
STUB
chmod +x "${WORK}/bin/id-other"
: >"${LOG}"
STUB_LOG="${LOG}" CHMOD_BIN="${WORK}/bin/chmod" ID_BIN="${WORK}/bin/id-other" bash "${WORK}/libexec/sweep.sh" --full 2>/dev/null
rc=$?
check "wrong user exits 1" test "${rc}" -eq 1
check_not "wrong user changes nothing" test -s "${LOG}"
run_sweep --bogus 2>/dev/null
rc=$?
check "unknown option exits 2" test "${rc}" -eq 2

exit "${fail}"
