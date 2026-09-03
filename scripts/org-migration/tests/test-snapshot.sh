#!/usr/bin/env bash
# snapshot.sh must write one JSON per repo with the documented shape, and
# must exit non-zero, naming the repo, when a repo cannot be read.
set -uo pipefail
unset CDPATH
# Hermetic: bash sources BASH_ENV in every non-interactive shell, and this
# machine's profile defines a `gh` shell function there. A function beats
# PATH, so without this the stub below is bypassed and the real gh runs
# against the network. Unset it (and GH_TOKEN/GH_HOST) for the whole test.
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN
export HOME="/tmp/om-snapshot-home-$$"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="${HERE}/../snapshot.sh"
WORK="/tmp/om-snapshot-test-$$"
mkdir -p "${WORK}/bin" "${WORK}/out" "${HOME}"
trap 'rm -rf "${WORK}" "${HOME}"' EXIT
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# Stub gh: answers `gh api <path> [--jq <expr>]` from canned responses and
# honors --jq by piping through the real jq, as gh does.
cat >"${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
path="$2"
jqexpr=""
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    *) shift ;;
  esac
done
emit() { if [[ -n "${jqexpr}" ]]; then jq -c "${jqexpr}"; else cat; fi; }
case "${path}" in
  repos/smartwatermelon/dotfiles)
    echo '{"name":"dotfiles","owner":{"login":"smartwatermelon","type":"User"},"default_branch":"main","visibility":"public","archived":false,"has_pages":false}' | emit ;;
  repos/smartwatermelon/dotfiles/topics) echo '{"names":["bash","dotfiles"]}' | emit ;;
  repos/smartwatermelon/dotfiles/actions/secrets) echo '{"secrets":[{"name":"CLAUDE_CODE_OAUTH_TOKEN"},{"name":"ANOTHER"}]}' | emit ;;
  repos/smartwatermelon/dotfiles/branches/main/protection) echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1 ;;
  repos/smartwatermelon/dotfiles/rulesets) echo '[{"id":1,"name":"main"}]' | emit ;;
  repos/smartwatermelon/dotfiles/pages) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  # flaky: the core repo reads fine, but a sub-resource fails with something
  # that is NOT a 404 — a transient error or an expired token.
  repos/smartwatermelon/flaky) echo '{"name":"flaky","owner":{"login":"smartwatermelon","type":"User"},"default_branch":"main","visibility":"public","archived":false}' | emit ;;
  repos/smartwatermelon/flaky/topics) echo '{"names":[]}' | emit ;;
  repos/smartwatermelon/flaky/actions/secrets) echo '{"secrets":[]}' | emit ;;
  repos/smartwatermelon/flaky/rulesets) echo '[]' | emit ;;
  repos/smartwatermelon/flaky/pages) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  repos/smartwatermelon/flaky/branches/main/protection) echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1 ;;
  repos/smartwatermelon/ghost*) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *) echo "stub: unexpected path ${path}" >&2; exit 2 ;;
esac
STUB
chmod +x "${WORK}/bin/gh"

printf 'dotfiles\tsmartwatermelon\n' >"${WORK}/list-good"
printf '# comment\ndotfiles\tsmartwatermelon\nghost\tsmartwatermelon\n' >"${WORK}/list-bad"

# Case 1: good list -> JSON with the documented shape.
if PATH="${WORK}/bin:${PATH}" bash "${SNAPSHOT}" "${WORK}/list-good" "${WORK}/out"; then
  _pass "good list: exit 0"
else
  _fail "good list: expected exit 0"
fi
f="${WORK}/out/dotfiles.json"
if [[ -f "${f}" ]] && jq -e '.repo=="dotfiles" and .owner.login=="smartwatermelon" and .owner.type=="User" and .default_branch=="main" and .visibility=="public" and .archived==false and .topics==["bash","dotfiles"] and .secrets==["ANOTHER","CLAUDE_CODE_OAUTH_TOKEN"] and .protection==null and (.rulesets|length)==1 and .pages==null' "${f}" >/dev/null; then
  _pass "good list: JSON shape"
else
  got="$(cat "${f}" 2>/dev/null)" || got="<missing>"
  _fail "good list: JSON shape wrong: ${got}"
fi

# Case 2 (known-bad): a repo that 404s must fail non-zero and name the repo,
# after still writing the good one.
rm -rf "${WORK}/out" && mkdir -p "${WORK}/out"
err="$(PATH="${WORK}/bin:${PATH}" bash "${SNAPSHOT}" "${WORK}/list-bad" "${WORK}/out" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -ne 0 && "${err}" == *ghost* ]]; then
  _pass "missing repo: non-zero and names ghost"
else
  _fail "missing repo: expected non-zero naming ghost, got rc=${rc} err=${err}"
fi
if [[ -f "${WORK}/out/dotfiles.json" ]]; then
  _pass "missing repo: the good repo was still snapshotted"
else
  _fail "missing repo: good repo skipped"
fi

# Case 3: a sub-resource that fails with something other than 404 must fail
# the snapshot. Recording `null` there would make verify.sh read a transient
# error or an expired token as "no branch protection configured".
rm -rf "${WORK}/out" && mkdir -p "${WORK}/out"
printf 'flaky\tsmartwatermelon\n' >"${WORK}/list-flaky"
err="$(PATH="${WORK}/bin:${PATH}" bash "${SNAPSHOT}" "${WORK}/list-flaky" "${WORK}/out" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -ne 0 && "${err}" == *flaky* ]]; then
  _pass "non-404 sub-resource failure: non-zero and names flaky"
else
  _fail "non-404 sub-resource failure: expected non-zero naming flaky, got rc=${rc} err=${err}"
fi
if [[ ! -f "${WORK}/out/flaky.json" ]]; then
  _pass "non-404 sub-resource failure: no snapshot written"
else
  wrote="$(cat "${WORK}/out/flaky.json" || true)"
  _fail "non-404 sub-resource failure: wrote a snapshot anyway: ${wrote}"
fi

# Case 4: malformed line rejected before any API call.
printf 'dotfiles smartwatermelon\n' >"${WORK}/list-malformed"
if PATH="${WORK}/bin:${PATH}" bash "${SNAPSHOT}" "${WORK}/list-malformed" "${WORK}/out" 2>/dev/null; then
  _fail "malformed line: should fail"
else
  _pass "malformed line: rejected"
fi

exit "${fail}"
