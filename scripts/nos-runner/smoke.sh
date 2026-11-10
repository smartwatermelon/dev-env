#!/bin/bash
# MIMOLETTE only, never CI: build the image, run it with the LAN block on, repeat the Q1 pass checks.
set -uo pipefail
unset CDPATH

CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OK_FILE="${NOS_PF_OK_FILE:-/var/run/nos-runner-pf.ok}"
TAG="nos-runner-smoke:local"
# shellcheck source=smoke-lib.sh
. "${HERE}/smoke-lib.sh"

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
# blocked NAME URL: pass only when curl exits 28 (connect timeout, what pf "block drop" causes). Any other result fails.
blocked() {
  local name="$1" url="$2" rc=0 verdict
  "${CONTAINER_BIN}" run --rm --entrypoint /bin/bash "${TAG}" -c "curl -s --connect-timeout 5 -m 8 -o /dev/null ${url}" >/dev/null 2>&1 || rc=$?
  verdict="$(classify_block "${rc}")"
  case "${verdict}" in
  blocked) echo "ok: ${name}" ;;
  open) failed "${name}: reachable (curl rc 0)" ;;
  *) failed "${name}: curl rc ${rc}, want 28 (timeout); refused or a broken VM does not prove pf blocked it" ;;
  esac
}

[[ -f "${OK_FILE}" ]] || failed "pf guard ok file missing: ${OK_FILE}"
"${CONTAINER_BIN}" build -t "${TAG}" "${HERE}/image" >/dev/null 2>&1 || failed "image build"

probe "github reachable" "curl -fsS -m 15 -o /dev/null https://api.github.com" || failed "api.github.com unreachable"
probe "npm reachable" "curl -fsS -m 15 -o /dev/null https://registry.npmjs.org" || failed "registry.npmjs.org unreachable"
probe "gateway DNS resolves" "getent hosts github.com | grep -qE '^[0-9a-f]'" || failed "DNS via gateway"
# Positive control: the internet works in this same run, so a dead network cannot pass as "blocked".
probe "internet control" "curl -fsS -m 15 -o /dev/null https://github.com" || failed "positive control: internet unreachable"
blocked "router HTTP blocked" "http://10.0.15.1:80"
blocked "192.168.0.1 HTTP blocked" "http://192.168.0.1:80"
blocked "LAN DNS port blocked" "http://192.168.0.1:53"
blocked "host ssh port blocked" "http://10.0.15.63:22"

echo "SMOKE PASS"
