#!/bin/bash
# MIMOLETTE only, never CI: build the image, run it with the LAN block on, repeat the Q1 pass checks.
set -uo pipefail
unset CDPATH

CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OK_FILE="${NOS_PF_OK_FILE:-/var/run/nos-runner-pf.ok}"
TAG="nos-runner-smoke:local"

failed() {
  echo "SMOKE FAIL: $1"
  exit 1
}

# probe NAME CMD: run CMD inside a throwaway VM; pass when it exits 0.
probe() {
  local name="$1" cmd="$2"
  "${CONTAINER_BIN}" run --rm --entrypoint /bin/bash "${TAG}" -c "${cmd}" >/dev/null 2>&1 || return 1
  echo "ok: ${name}"
}
# blocked NAME CMD: pass when CMD fails inside the VM.
blocked() {
  local name="$1" cmd="$2"
  if "${CONTAINER_BIN}" run --rm --entrypoint /bin/bash "${TAG}" -c "${cmd}" >/dev/null 2>&1; then
    return 1
  fi
  echo "ok: ${name}"
}

[[ -f "${OK_FILE}" ]] || failed "pf guard ok file missing: ${OK_FILE}"
"${CONTAINER_BIN}" build -t "${TAG}" "${HERE}/image" >/dev/null 2>&1 || failed "image build"

probe "github reachable" "curl -fsS -m 15 -o /dev/null https://api.github.com" || failed "api.github.com unreachable"
probe "npm reachable" "curl -fsS -m 15 -o /dev/null https://registry.npmjs.org" || failed "registry.npmjs.org unreachable"
probe "gateway DNS resolves" "getent hosts github.com | grep -qE '^[0-9a-f]'" || failed "DNS via gateway"
blocked "router HTTP blocked" "curl -s -m 5 -o /dev/null http://10.0.15.1" || failed "router HTTP reachable"
blocked "router ping blocked" "ping -c 1 -W 3 10.0.15.1" || failed "router ping works"
blocked "192.168.0.1 ping blocked" "ping -c 1 -W 3 192.168.0.1" || failed "192.168.0.1 ping works"
blocked "LAN DNS tcp blocked" "timeout 5 bash -c 'echo > /dev/tcp/192.168.0.1/53'" || failed "192.168.0.1:53 reachable"
blocked "host ssh blocked" "timeout 5 bash -c 'echo > /dev/tcp/10.0.15.63/22'" || failed "host 10.0.15.63:22 reachable"

echo "SMOKE PASS"
