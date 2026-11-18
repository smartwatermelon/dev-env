#!/bin/bash
# Tests guest/run-job.sh against a stub run.sh in a temp runner dir.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
job="${here}/../guest/run-job.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/runjob.XXXXXX")"
trap 'rm -r "${t}"' EXIT
pass=0
fail=0
check() { # label command...
  local label="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
    echo "  PASS: ${label}"
  else
    fail=$((fail + 1))
    echo "  FAIL: ${label}"
  fi
}

# The stub records the PATH and arguments the runner would get.
cat >"${t}/run.sh" <<'EOF'
#!/bin/bash
printf 'PATH=%s\n' "${PATH}" >"${OUT}"
printf 'ARG=%s\n' "$@" >>"${OUT}"
EOF
chmod +x "${t}/run.sh"

out="${t}/out"
printf 'jit-blob' | env -i PATH=/usr/bin:/bin OUT="${out}" SWM_RUNNER_DIR="${t}" /bin/bash "${job}"
rc=$?
check "exit 0 with a JIT config" test "${rc}" = 0
check "Homebrew bin comes first in the job PATH" grep -q '^PATH=/opt/homebrew/bin:' "${out}"
check "system dirs stay in the job PATH" grep -q ':/usr/bin:/bin:' "${out}"
check "JIT config passed as --jitconfig" grep -qx 'ARG=--jitconfig' "${out}"
check "JIT config value passed" grep -qx 'ARG=jit-blob' "${out}"

rm -f "${out}"
env -i PATH=/usr/bin:/bin OUT="${out}" SWM_RUNNER_DIR="${t}" /bin/bash "${job}" </dev/null 2>/dev/null
rc=$?
check "empty stdin exits 2" test "${rc}" = 2
check "empty stdin never starts the runner" test ! -e "${out}"

echo "run-job: ${pass} passed, ${fail} failed"
[[ "${fail}" == 0 ]]
