#!/usr/bin/env bash
# gate.sh with stubs: each allowed verb runs its fixed argv; everything else is refused unrun.
set -uo pipefail
unset CDPATH
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-ro-gate-test.XXXXXX")" || exit 1
[[ -d "${WORK}" ]] || exit 1
# Direct rm is safe here: WORK is a fresh mktemp dir, checked above.
trap 'rm -rf "${WORK:?}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/libexec"
LOG="${WORK}/calls"

# One logging stub for every binary the gate may run.
for b in launchctl sudo container pfctl env; do
  cat >"${WORK}/bin/${b}" <<STUB
#!/usr/bin/env bash
echo "${b} \$*" >>"${LOG}"
STUB
done
cat >"${WORK}/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == "-u" ]]; then cat "${0%/*}/../uid"; exit 0; fi
if [[ "$1" == "-u" && "$2" == "andrewrich" ]]; then echo 501; exit 0; fi
exit 1
STUB
chmod +x "${WORK}/bin/"*
echo 0 >"${WORK}/uid"

# The gate reads binary paths only from its own config.sh; point them at stubs.
cp "${SRC}/gate.sh" "${WORK}/libexec/gate"
sed -e "s|^export AGENT_RO_LAUNCHCTL=.*|export AGENT_RO_LAUNCHCTL=\"${WORK}/bin/launchctl\"|" \
  -e "s|^export AGENT_RO_SUDO=.*|export AGENT_RO_SUDO=\"${WORK}/bin/sudo\"|" \
  -e "s|^export AGENT_RO_CONTAINER=.*|export AGENT_RO_CONTAINER=\"${WORK}/bin/container\"|" \
  -e "s|^export AGENT_RO_PFCTL=.*|export AGENT_RO_PFCTL=\"${WORK}/bin/pfctl\"|" \
  -e "s|^export AGENT_RO_ID=.*|export AGENT_RO_ID=\"${WORK}/bin/id\"|" \
  -e "s|^export AGENT_RO_ENV=.*|export AGENT_RO_ENV=\"${WORK}/bin/env\"|" \
  "${SRC}/config.sh" >"${WORK}/libexec/config.sh"
for v in LAUNCHCTL SUDO CONTAINER PFCTL ID ENV; do
  grep -q "^export AGENT_RO_${v}=\"${WORK}/bin/" "${WORK}/libexec/config.sh" || _fail "test setup: config rewrite missed AGENT_RO_${v}"
done
GATE="${WORK}/libexec/gate"

# allow NAME WANT_LOG_LINE ARGS...: exit 0 and exactly WANT_LOG_LINE logged.
allow() {
  local name="$1" want="$2"
  shift 2
  : >"${LOG}"
  if ! bash "${GATE}" "$@" >/dev/null 2>&1; then
    _fail "${name}: refused"
    return
  fi
  local got
  got="$(cat "${LOG}")"
  if [[ "${got}" == "${want}" ]]; then _pass "${name}"; else _fail "${name}: ran '${got}', want '${want}'"; fi
}
# refuse NAME ARGS...: non-zero exit and nothing run.
refuse() {
  local name="$1"
  shift
  : >"${LOG}"
  if bash "${GATE}" "$@" >/dev/null 2>&1; then
    _fail "${name}: allowed"
    return
  fi
  local ran
  ran="$(cat "${LOG}")"
  if [[ -n "${ran}" ]]; then _fail "${name}: refused but ran: ${ran}"; else _pass "${name}"; fi
}

W="${WORK}/bin"
OWNER_SUDO="sudo -n -u andrewrich -- ${W}/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin HOME=/Users/andrewrich USER=andrewrich LOGNAME=andrewrich"

echo "-- allowed verbs map to fixed argv"
allow "launchctl-print system" "launchctl print system" launchctl-print system
allow "launchctl-print gui/501" "launchctl print gui/501" launchctl-print gui/501
allow "launchctl-print user/501/label" "launchctl print user/501/com.example.job" launchctl-print user/501/com.example.job
allow "launchctl-print system/label" "launchctl print system/com.nightowlstudio.nos-runner-pf" launchctl-print system/com.nightowlstudio.nos-runner-pf
allow "launchctl-print-disabled system" "launchctl print-disabled system" launchctl-print-disabled system
# as_owner execs launchctl asuser; the stub logs that one call.
allow "launchctl-list runs as owner" "launchctl asuser 501 ${W}/sudo -n -u andrewrich -- ${W}/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin HOME=/Users/andrewrich USER=andrewrich LOGNAME=andrewrich ${W}/launchctl list" launchctl-list
allow "container ls" "launchctl asuser 501 ${W}/${OWNER_SUDO} ${W}/container ls" container ls
allow "container ls-all" "launchctl asuser 501 ${W}/${OWNER_SUDO} ${W}/container ls -a" container ls-all
allow "container system-status" "launchctl asuser 501 ${W}/${OWNER_SUDO} ${W}/container system status" container system-status
allow "container version" "launchctl asuser 501 ${W}/${OWNER_SUDO} ${W}/container --version" container version
allow "pfctl-show rules" "pfctl -s rules" pfctl-show rules
allow "pfctl-show anchors" "pfctl -s Anchors" pfctl-show anchors
allow "pfctl-show rules in anchor" "pfctl -a com.apple/nos-runner -s rules" pfctl-show rules com.apple/nos-runner

echo "-- help runs nothing"
: >"${LOG}"
if bash "${GATE}" help >/dev/null 2>&1 && [[ ! -s "${LOG}" ]]; then _pass "help"; else _fail "help"; fi

echo "-- refused"
refuse "no verb"
refuse "unknown verb" bootout system/x
refuse "launchctl-print other uid" launchctl-print gui/502
refuse "launchctl-print root gui" launchctl-print gui/0
refuse "launchctl-print nested path" launchctl-print gui/501/a/b
refuse "launchctl-print shell text" "launchctl-print" "system;id"
refuse "launchctl-print option" launchctl-print -h
refuse "launchctl-print empty" launchctl-print ""
refuse "launchctl-print two args" launchctl-print system gui/501
refuse "launchctl-print-disabled label" launchctl-print-disabled system/x
refuse "launchctl-list with args" launchctl-list gui/501
refuse "container exec" container exec mimolette-1 sh
refuse "container stop" container stop
refuse "container run" container run
refuse "container two words" container system stop
refuse "container shell text" container "ls; id"
refuse "pfctl flush" pfctl-show flush
refuse "pfctl -F" pfctl-show -F
refuse "pfctl anchor dotdot" pfctl-show rules ../x
refuse "pfctl anchor option" pfctl-show rules -F
refuse "pfctl three args" pfctl-show rules a b
refuse "help with args" help x

echo "-- refuses to run unless root"
echo 501 >"${WORK}/uid"
refuse "not root" launchctl-print system
echo 0 >"${WORK}/uid"

echo "-- ignores binary paths from the environment"
: >"${LOG}"
AGENT_RO_LAUNCHCTL=/bin/false bash "${GATE}" launchctl-print system >/dev/null 2>&1
if grep -q "^launchctl print system$" "${LOG}"; then _pass "env cannot override binaries"; else _fail "env cannot override binaries"; fi

exit "${fail}"
