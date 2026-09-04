#!/usr/bin/env bash
# transfer.sh: idempotent, one POST per repo that needs it, keeps going after
# a failure, exit 1 if anything failed, --dry-run makes no POST.
set -uo pipefail
unset CDPATH
# Hermetic: bash sources BASH_ENV in every non-interactive shell, and this
# machine's profile defines a `gh` shell function there. A function beats
# PATH, so without this the stub below is bypassed and the real gh runs
# against the network. Unset it (and the token/host vars) for the whole test.
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN
export HOME="/tmp/om-transfer-home-$$"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSFER="${HERE}/../transfer.sh"
WORK="/tmp/om-transfer-test-$$"
mkdir -p "${WORK}/bin" "${WORK}/state" "${HOME}"
trap 'rm -rf "${WORK}" "${HOME}"' EXIT
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# Stub gh with per-repo state files: <state>/<repo> holds "login type".
# A POST .../transfer flips the state to "<new_owner> Organization" unless the
# repo is named "stuck", which never flips. Every POST is logged. GET answers
# are JSON piped through the real jq when --jq is given, as gh does.
cat >"${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
STATE="${OM_TEST_STATE:?}"
args=("$@")
path=""; method="GET"; new_owner=""; jqexpr=""
i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    api) ;;
    -X) i=$((i + 1)); method="${args[$i]}" ;;
    -f) i=$((i + 1)); [[ "${args[$i]}" == new_owner=* ]] && new_owner="${args[$i]#new_owner=}" ;;
    --jq) i=$((i + 1)); jqexpr="${args[$i]}" ;;
    -*) ;;
    *) [[ -z "${path}" ]] && path="${args[$i]}" ;;
  esac
  i=$((i + 1))
done
if [[ "${method}" == "POST" && "${path}" == */transfer ]]; then
  repo="${path#repos/*/}"; repo="${repo%/transfer}"
  echo "POST ${path} new_owner=${new_owner}" >>"${STATE}/posts"
  if [[ "${repo}" != "stuck" ]]; then
    echo "${new_owner} Organization" >"${STATE}/${repo}"
  fi
  echo '{}'
  exit 0
fi
# orgs/<name>: an entry in ${STATE}/orgs names one account type per line as
# "<name> <type>". A name absent from that file 404s, as GitHub does.
if [[ "${path}" == orgs/* ]]; then
  want="${path#orgs/}"
  while read -r oname otype; do
    if [[ "${oname}" == "${want}" ]]; then
      json="$(printf '{"login":"%s","type":"%s"}' "${oname}" "${otype}")"
      if [[ -n "${jqexpr}" ]]; then jq -r "${jqexpr}" <<<"${json}"; else echo "${json}"; fi
      exit 0
    fi
  done <"${STATE}/orgs" 2>/dev/null
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
repo="${path#repos/*/}"
# "malformed" answers a lookup with a single field, standing in for any
# unexpected gh output (an empty owner, a truncated body).
if [[ "${repo}" == "malformed" ]]; then
  json='{"name":"malformed","owner":{"login":"","type":""}}'
  if [[ -n "${jqexpr}" ]]; then jq -r "${jqexpr}" <<<"${json}"; else echo "${json}"; fi
  exit 0
fi
if [[ -f "${STATE}/${repo}" ]]; then
  read -r login type <"${STATE}/${repo}"
  # repos/smartwatermelon/<repo> always resolves (the redirect path). A lookup
  # under any other owner resolves only once that owner actually has it.
  if [[ "${path}" == "repos/smartwatermelon/${repo}" || "${path}" == "repos/${login}/${repo}" ]]; then
    json="$(printf '{"name":"%s","owner":{"login":"%s","type":"%s"}}' "${repo}" "${login}" "${type}")"
    if [[ -n "${jqexpr}" ]]; then jq -r "${jqexpr}" <<<"${json}"; else echo "${json}"; fi
    exit 0
  fi
fi
echo "gh: Not Found (HTTP 404)" >&2
exit 1
STUB
chmod +x "${WORK}/bin/gh"

export OM_TEST_STATE="${WORK}/state"
# Both transfer targets exist as real organizations.
printf 'smartwatermelon Organization\nnightowlstudiollc Organization\n' >"${WORK}/state/orgs"
echo "twistedmelonman User" >"${WORK}/state/alpha"
echo "twistedmelonman User" >"${WORK}/state/beta"
echo "nightowlstudiollc Organization" >"${WORK}/state/done"
echo "twistedmelonman User" >"${WORK}/state/stuck"
printf 'alpha\tsmartwatermelon\ndone\tnightowlstudiollc\nbeta\tsmartwatermelon\n' >"${WORK}/list"
printf 'stuck\tsmartwatermelon\nbeta\tsmartwatermelon\n' >"${WORK}/list-stuck"

run() { PATH="${WORK}/bin:${PATH}" OM_POLL_SECONDS=0 OM_POLL_MAX=2 bash "${TRANSFER}" "$@"; }
# Read the POST log into ${log} (empty when no POST was made) and the number
# of POST lines into ${n}.
read_posts() {
  log="$(cat "${WORK}/state/posts" 2>/dev/null || true)"
  n=0
  [[ -n "${log}" ]] && n="$(grep -c '^POST' <<<"${log}" || true)"
}

# Case 1: dry run makes no POST.
run "${WORK}/list" --dry-run >/dev/null 2>&1
if [[ ! -f "${WORK}/state/posts" ]]; then _pass "dry-run: no POST"; else _fail "dry-run: POSTed"; fi

# Case 2: real run POSTs alpha and beta, skips done, exits 0.
if run "${WORK}/list" >/dev/null 2>&1; then _pass "run: exit 0"; else _fail "run: expected exit 0"; fi
read_posts
if [[ "${n}" -eq 2 && "${log}" == *"POST repos/twistedmelonman/alpha/transfer new_owner=smartwatermelon"* && "${log}" == *"POST repos/twistedmelonman/beta/transfer new_owner=smartwatermelon"* && "${log}" != *"/done/"* ]]; then
  _pass "run: exactly alpha and beta POSTed, done skipped"
else
  _fail "run: wrong POSTs: ${log}"
fi

# Case 3: idempotent second run makes no new POST.
run "${WORK}/list" >/dev/null 2>&1
read_posts
if [[ "${n}" -eq 2 ]]; then _pass "rerun: no new POST"; else _fail "rerun: POSTed again: ${log}"; fi

# Case 4: a repo that never resolves under the target is reported, the loop
# continues to beta, and the exit code is 1.
echo "twistedmelonman User" >"${WORK}/state/beta"
rm -f "${WORK}/state/posts"
err="$(run "${WORK}/list-stuck" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *stuck* ]]; then _pass "stuck: reported, exit 1"; else _fail "stuck: rc=${rc} err=${err}"; fi
read_posts
if [[ "${log}" == *"/beta/transfer"* ]]; then _pass "stuck: loop continued to beta"; else _fail "stuck: beta not attempted"; fi

# Case 5: an unexpected lookup result must fail that repo, not POST garbage.
# The old split produced an empty login and POSTed repos//malformed/transfer.
rm -f "${WORK}/state/posts"
printf 'malformed\tsmartwatermelon\n' >"${WORK}/list-malformed"
err="$(run "${WORK}/list-malformed" 2>&1 >/dev/null)"
rc=$?
read_posts
if [[ "${rc}" -eq 1 && "${err}" == *malformed* && -z "${log}" ]]; then
  _pass "malformed lookup: reported, exit 1, no POST"
else
  _fail "malformed lookup: rc=${rc} err=${err} posts=${log}"
fi

# Case 6: --only restricts to one repo.
echo "twistedmelonman User" >"${WORK}/state/alpha"
echo "twistedmelonman User" >"${WORK}/state/beta"
rm -f "${WORK}/state/posts"
run "${WORK}/list" --only beta >/dev/null 2>&1
read_posts
if [[ "${log}" == "POST repos/twistedmelonman/beta/transfer new_owner=smartwatermelon" ]]; then
  _pass "--only: exactly beta POSTed"
else
  _fail "--only: got ${log}"
fi

# Case 7: a target that is not an organization must stop the run before any
# POST. During the rename window a stranger can hold the user name
# `smartwatermelon`; a user-to-user transfer would send them an invitation.
echo "twistedmelonman User" >"${WORK}/state/alpha"
echo "twistedmelonman User" >"${WORK}/state/beta"
rm -f "${WORK}/state/posts"
printf 'nightowlstudiollc Organization\n' >"${WORK}/state/orgs"
err="$(run "${WORK}/list" 2>&1 >/dev/null)"
rc=$?
read_posts
if [[ "${rc}" -eq 1 && "${err}" == *smartwatermelon* && -z "${log}" ]]; then
  _pass "missing target org: exit 1, zero POSTs"
else
  _fail "missing target org: rc=${rc} err=${err} posts=${log}"
fi

# Case 8: a target that resolves but is a User (the squatter case) is refused
# the same way.
printf 'smartwatermelon User\nnightowlstudiollc Organization\n' >"${WORK}/state/orgs"
rm -f "${WORK}/state/posts"
err="$(run "${WORK}/list" 2>&1 >/dev/null)"
rc=$?
read_posts
if [[ "${rc}" -eq 1 && "${err}" == *smartwatermelon* && -z "${log}" ]]; then
  _pass "target is a User: exit 1, zero POSTs"
else
  _fail "target is a User: rc=${rc} err=${err} posts=${log}"
fi

# Case 9: --dry-run runs the pre-flight too. It is read-only and cheap, and a
# dry run that skips it would report a plan that cannot execute.
rm -f "${WORK}/state/posts"
err="$(run "${WORK}/list" --dry-run 2>&1 >/dev/null)"
rc=$?
read_posts
if [[ "${rc}" -eq 1 && "${err}" == *smartwatermelon* && -z "${log}" ]]; then
  _pass "dry-run: pre-flight still enforced"
else
  _fail "dry-run: pre-flight skipped: rc=${rc} err=${err} posts=${log}"
fi

# Case 10: --only with a repo that is not on the move list exits 1 and POSTs
# nothing. A typo must not look like a successful no-op run.
printf 'smartwatermelon Organization\nnightowlstudiollc Organization\n' >"${WORK}/state/orgs"
rm -f "${WORK}/state/posts"
err="$(run "${WORK}/list" --only nosuchrepo 2>&1 >/dev/null)"
rc=$?
read_posts
if [[ "${rc}" -eq 1 && "${err}" == *nosuchrepo* && -z "${log}" ]]; then
  _pass "--only off-list: exit 1, no POST"
else
  _fail "--only off-list: rc=${rc} err=${err} posts=${log}"
fi

exit "${fail}"
