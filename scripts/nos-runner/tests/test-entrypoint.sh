#!/usr/bin/env bash
# entrypoint.sh against a stub run.sh: JIT handoff and the missing-JIT failure.
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

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../image/entrypoint.sh"
WORK="${TMPDIR:-/tmp}/nos-entrypoint-test-$$"
mkdir -p "${WORK}/home"
trap 'rm -rf "${WORK:?}"' EXIT

# Stub run.sh records its argv and whether NOS_JIT is still in its environment.
cat >"${WORK}/home/run.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_OUT}/argv"
printf '%s\n' "${NOS_JIT-UNSET}" >"${STUB_OUT}/env"
STUB
chmod +x "${WORK}/home/run.sh"

run() {
  env -u NOS_JIT "$@" STUB_OUT="${WORK}" RUNNER_HOME="${WORK}/home" bash "${SCRIPT}" >"${WORK}/out" 2>"${WORK}/err"
}

echo "-- entrypoint_passes_jitconfig_and_unsets_env"
rc=0
run NOS_JIT='ENC0DED+jit/config==' || rc=$?
check "exit 0" test "${rc}" -eq 0
got_argv="$(cat "${WORK}/argv")"
got_env="$(cat "${WORK}/env")"
check "run.sh got --jitconfig and the value" test "${got_argv}" = $'--jitconfig\nENC0DED+jit/config=='
check "NOS_JIT unset in run.sh environment" test "${got_env}" = UNSET

echo "-- entrypoint_fails_when_jit_missing"
rm -f "${WORK:?}/argv" "${WORK:?}/env"
rc=0
run NOS_JIT= || rc=$?
check "exit 2 on empty NOS_JIT" test "${rc}" -eq 2
check "stderr names NOS_JIT" grep -q NOS_JIT "${WORK}/err"
check "run.sh not started" test ! -e "${WORK}/argv"
rc=0
run FOO=bar || rc=$?
check "exit 2 on unset NOS_JIT" test "${rc}" -eq 2

exit "${fail}"
