#!/usr/bin/env bash
# verify.sh: owner must be the only change between baseline and after; owner
# must be the target org; every smartwatermelon clone must still ls-remote.
set -uo pipefail
unset CDPATH
# Hermetic: bash sources BASH_ENV in every non-interactive shell, and this
# machine's profile defines a `gh` shell function there. A function beats
# PATH, so without this the stub below is bypassed and the real gh runs
# against the network. Unset it (and the token/host vars) for the whole test.
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN
export HOME="/tmp/om-verify-home-$$"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${HERE}/../verify.sh"
WORK="/tmp/om-verify-test-$$"
mkdir -p "${WORK}/bin" "${WORK}/base" "${WORK}/clones" "${HOME}"
trap 'rm -rf "${WORK}" "${HOME}"' EXIT
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# verify.sh calls snapshot.sh by path, so stub gh (not snapshot.sh): it serves
# whatever JSON the test puts in ${OM_TEST_CORE}/<repo>.json for
# repos/smartwatermelon/<repo>, and honors --jq through the real jq.
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
repo="${path#repos/smartwatermelon/}"
case "${path}" in
  repos/smartwatermelon/*/topics) echo '{"names":[]}' | emit ;;
  repos/smartwatermelon/*/actions/secrets) echo '{"secrets":[]}' | emit ;;
  repos/smartwatermelon/*/branches/*/protection | repos/smartwatermelon/*/pages)
    echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  repos/smartwatermelon/*/rulesets) echo '[]' | emit ;;
  repos/smartwatermelon/*)
    if [[ ! -f "${OM_TEST_CORE:?}/${repo}.json" ]]; then
      echo 'gh: Not Found (HTTP 404)' >&2; exit 1
    fi
    emit <"${OM_TEST_CORE}/${repo}.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
# git stub: ls-remote succeeds unless the remote names "broken".
cat >"${WORK}/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"remote get-url origin"* ]]; then
  dir="$2"; cat "${dir}/.git/ORIGIN"; exit 0
fi
if [[ "$*" == *"ls-remote"* ]]; then
  dir="$2"
  if grep -q broken "${dir}/.git/ORIGIN"; then exit 128; fi
  exit 0
fi
exit 0
STUB
chmod +x "${WORK}/bin/git"

mk_core() { # repo login type visibility
  printf '{"name":"%s","owner":{"login":"%s","type":"%s"},"default_branch":"main","visibility":"%s","archived":false}\n' "$1" "$2" "$3" "$4"
}
printf 'alpha\tsmartwatermelon\ncleanroom\tnightowlstudiollc\n' >"${WORK}/list"

# Baseline: both under the user.
mkdir -p "${WORK}/core-base"
mk_core alpha smartwatermelon User public >"${WORK}/core-base/alpha.json"
mk_core cleanroom smartwatermelon User private >"${WORK}/core-base/cleanroom.json"
OM_TEST_CORE="${WORK}/core-base" PATH="${WORK}/bin:${PATH}" bash "${HERE}/../snapshot.sh" "${WORK}/list" "${WORK}/base" >/dev/null

# Clones: one good smartwatermelon remote, one unrelated, one broken.
for c in good other broken; do mkdir -p "${WORK}/clones/${c}/.git"; done
echo "git@github.com:smartwatermelon/alpha.git" >"${WORK}/clones/good/.git/ORIGIN"
echo "git@github.com:someoneelse/thing.git" >"${WORK}/clones/other/.git/ORIGIN"
echo "git@github.com:smartwatermelon/broken.git" >"${WORK}/clones/broken/.git/ORIGIN"

# verify.sh refuses a non-empty after-dir, so every run gets a fresh one. run()
# is often called inside $(...), where an incremented counter would not survive
# the subshell, so derive the directory from a mktemp -d instead.
run() {
  local out
  out="$(mktemp -d "${WORK}/after-XXXXXX")"
  rmdir "${out}"
  OM_TEST_CORE="$1" PATH="${WORK}/bin:${PATH}" bash "${VERIFY}" \
    "${WORK}/list" "${WORK}/base" "${out}" --clones "$2"
}

# Case 1: owner-only change, all clones fine -> exit 0.
mkdir -p "${WORK}/core-good" "${WORK}/clones-good"
mk_core alpha smartwatermelon Organization public >"${WORK}/core-good/alpha.json"
mk_core cleanroom nightowlstudiollc Organization private >"${WORK}/core-good/cleanroom.json"
cp -R "${WORK}/clones/good" "${WORK}/clones/other" "${WORK}/clones-good/"
if run "${WORK}/core-good" "${WORK}/clones-good" >/dev/null 2>&1; then _pass "owner-only diff: exit 0"; else _fail "owner-only diff: expected exit 0"; fi

# Case 2: visibility changed too -> exit 1 naming the repo and the field.
mkdir -p "${WORK}/core-drift"
cp "${WORK}/core-good/alpha.json" "${WORK}/core-drift/"
mk_core cleanroom nightowlstudiollc Organization public >"${WORK}/core-drift/cleanroom.json"
err="$(run "${WORK}/core-drift" "${WORK}/clones-good" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *cleanroom* && "${err}" == *visibility* ]]; then _pass "drift: exit 1 names cleanroom and the field"; else _fail "drift: rc=${rc} err=${err}"; fi

# Case 3: still a User -> exit 1.
mkdir -p "${WORK}/core-user"
cp "${WORK}/core-good/cleanroom.json" "${WORK}/core-user/"
mk_core alpha twistedmelonman User public >"${WORK}/core-user/alpha.json"
err="$(run "${WORK}/core-user" "${WORK}/clones-good" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *alpha* ]]; then _pass "not transferred: exit 1 names alpha"; else _fail "not transferred: rc=${rc} err=${err}"; fi

# Case 4: a broken smartwatermelon clone -> exit 1; unrelated clone ignored.
err="$(run "${WORK}/core-good" "${WORK}/clones" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *broken* && "${err}" != *other* ]]; then _pass "clones: broken reported, other ignored"; else _fail "clones: rc=${rc} err=${err}"; fi

# Case 5: a non-empty after-dir is refused. Otherwise a stale JSON from an
# earlier run would be compared as if this run had just written it.
mkdir -p "${WORK}/after-stale"
cp "${WORK}/base/alpha.json" "${WORK}/after-stale/alpha.json"
err="$(OM_TEST_CORE="${WORK}/core-good" PATH="${WORK}/bin:${PATH}" bash "${VERIFY}" \
  "${WORK}/list" "${WORK}/base" "${WORK}/after-stale" --clones "${WORK}/clones-good" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *after-stale* ]]; then
  _pass "stale after-dir: refused, exit 1"
else
  _fail "stale after-dir: rc=${rc} err=${err}"
fi

# Case 6: when the snapshot fails, stop before the comparison loop -- never
# print a per-repo ok line based on files this run did not write.
printf 'alpha\tsmartwatermelon\nghost\tsmartwatermelon\n' >"${WORK}/list-ghost"
out="$(OM_TEST_CORE="${WORK}/core-good" PATH="${WORK}/bin:${PATH}" bash "${VERIFY}" \
  "${WORK}/list-ghost" "${WORK}/base" "${WORK}/after-ghost" --clones "${WORK}/clones-good" 2>&1)"
rc=$?
if [[ "${rc}" -eq 1 && "${out}" != *": ok"* ]]; then
  _pass "snapshot failure: exit 1 with no per-repo ok line"
else
  _fail "snapshot failure: rc=${rc} out=${out}"
fi

# Case 7: ~/Developer is not flat -- clients/<repo> and netlify/crazy-larry sit
# one level deeper, so a nested clone must be checked too.
mkdir -p "${WORK}/clones-nested/netlify/crazy-larry/.git"
echo "git@github.com:smartwatermelon/crazy-larry.git" >"${WORK}/clones-nested/netlify/crazy-larry/.git/ORIGIN"
out="$(run "${WORK}/core-good" "${WORK}/clones-nested" 2>&1)"
rc=$?
if [[ "${rc}" -eq 0 && "${out}" == *crazy-larry* ]]; then
  _pass "nested clone: checked one level deeper"
else
  _fail "nested clone: rc=${rc} out=${out}"
fi

# Case 8: a broken nested clone fails the run.
mkdir -p "${WORK}/clones-nested-bad/clients/broken/.git"
echo "git@github.com:smartwatermelon/broken.git" >"${WORK}/clones-nested-bad/clients/broken/.git/ORIGIN"
err="$(run "${WORK}/core-good" "${WORK}/clones-nested-bad" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *broken* ]]; then
  _pass "nested clone: broken one reported, exit 1"
else
  _fail "nested clone broken: rc=${rc} err=${err}"
fi

exit "${fail}"
