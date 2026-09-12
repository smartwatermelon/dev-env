#!/usr/bin/env bash
# run-digest.sh must fail rather than publish a digest that understates the
# queue. Every assertion here covers a way the tool could report "nothing needs
# your attention" while actually having lost the ability to tell — which is the
# only failure mode that would make it worse than not existing.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/.."
WORK="/tmp/dd-run-test-$$"
BIN="${WORK}/bin"
mkdir -p "${BIN}"
trap 'rm -rf "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# Stub gh: one owner has an open Dependabot PR, the others have none. Enough
# to drive the pipeline without touching the network.
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  search)
    if [[ "$*" == *"--owner one"* ]]; then
      echo '[{"repository":{"nameWithOwner":"one/repo"},"number":1}]'
    else
      echo '[]'
    fi ;;
  api)
    # The gh wrapper on PATH asks for the current identity before forwarding
    # any command, so a stub that does not answer this never sees the rest.
    if [[ "$*" == "api user"* ]]; then
      echo 'twistedmelonman'
    elif [[ "$*" == *graphql* ]]; then
      if [[ "$*" == *defaultBranchRef* ]]; then
        echo '{"data":{"repository":{"defaultBranchRef":{"target":{"statusCheckRollup":{"contexts":{"nodes":[]}}}}}}}'
      else
        cat <<'JSON'
{"data":{"repository":{"pullRequest":{
  "number":1,"title":"chore: bump left-pad from 1.0.0 to 1.0.1",
  "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z",
  "isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
  "headRefOid":"abc","reviewDecision":null,"autoMergeRequest":null,
  "labels":{"nodes":[]},
  "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
    {"name":"validate","conclusion":"SUCCESS","status":"COMPLETED","isRequired":true}
  ]}}}}]}}}}}
JSON
      fi
    else
      echo '{"name":"probe"}'
    fi ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "${BIN}/gh"

# A missing token means an owner cannot be surveyed. Publishing anyway would
# report that owner's queue as empty, which is a lie the reader cannot detect.
PATH="${BIN}:${PATH}" DIGEST_OWNERS="one two" DIGEST_TOKEN_ONE="t" \
  bash "${DIR}/run-digest.sh" --dry-run >/dev/null 2>"${WORK}/missing.err"
missing_rc=$?
if [[ "${missing_rc}" -ne 0 ]] && grep -q "DIGEST_TOKEN_TWO is not set" "${WORK}/missing.err"; then
  _pass "a missing owner token fails the run instead of omitting that owner"
else
  _fail "a missing owner token did not fail the run"
fi

# The probe exists because a token that has lost private-repo access still
# answers searches successfully, returning only public results. Verified
# against the live API 2026-09-11: an unreadable probe exits 1 and run-digest
# propagates it.
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  api)
    if [[ "$*" == "api user"* ]]; then echo 'twistedmelonman'
    elif [[ "$*" == *"repos/"* && "$*" != *graphql* ]]; then exit 1
    else echo '[]'; fi ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "${BIN}/gh"
PATH="${BIN}:${PATH}" DIGEST_OWNERS="one" DIGEST_TOKEN_ONE="t" \
  DIGEST_PROBE_ONE="one/private" \
  bash "${DIR}/run-digest.sh" --dry-run >/dev/null 2>"${WORK}/probe.err"
probe_rc=$?
if [[ "${probe_rc}" -ne 0 ]] && grep -q "cannot read private probe repo" "${WORK}/probe.err"; then
  _pass "an unreadable private probe fails the run"
else
  _fail "an unreadable private probe did not fail the run (exit ${probe_rc})"
fi

# An empty queue is a real state and must render as an explicit statement, not
# as a crash and not as a silently empty body.
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  api)
    if [[ "$*" == "api user"* ]]; then echo 'twistedmelonman'
    else echo '{"name":"probe"}'; fi ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "${BIN}/gh"
empty_out="$(PATH="${BIN}:${PATH}" DIGEST_OWNERS="one" DIGEST_TOKEN_ONE="t" \
  bash "${DIR}/run-digest.sh" --dry-run 2>/dev/null)"
if grep -q "No open Dependabot pull requests" <<<"${empty_out}"; then
  _pass "a genuinely empty queue renders as an explicit statement"
else
  _fail "an empty queue did not render correctly"
fi

# A populated queue must be surveyed and rendered, not merely "not crash".
# This is the positive case that proves the failure assertions above are not
# passing for the trivial reason that nothing ever works.
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  search)
    if [[ "$*" == *"--owner one"* ]]; then
      echo '[{"repository":{"nameWithOwner":"one/repo"},"number":1}]'
    else
      echo '[]'
    fi ;;
  api)
    if [[ "$*" == "api user"* ]]; then echo 'twistedmelonman'
    elif [[ "$*" == *defaultBranchRef* ]]; then
      echo '{"data":{"repository":{"defaultBranchRef":{"target":{"statusCheckRollup":{"contexts":{"nodes":[]}}}}}}}'
    elif [[ "$*" == *graphql* ]]; then
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{
  "number":1,"title":"chore: bump left-pad from 1.0.0 to 1.0.1",
  "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z",
  "isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
  "headRefOid":"abc","reviewDecision":null,"autoMergeRequest":null,
  "labels":{"nodes":[]},
  "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
    {"name":"validate","conclusion":"SUCCESS","status":"COMPLETED","isRequired":true}
  ]}}}}]}}}}}
JSON
    else echo '{"name":"probe"}'; fi ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "${BIN}/gh"
populated="$(PATH="${BIN}:${PATH}" DIGEST_OWNERS="one" DIGEST_TOKEN_ONE="t" \
  bash "${DIR}/run-digest.sh" --dry-run 2>/dev/null)"
if grep -q "1 open Dependabot PRs" <<<"${populated}" \
  && grep -q "one/repo#1" <<<"${populated}"; then
  _pass "a populated queue is surveyed and rendered"
else
  _fail "a populated queue did not render the PR"
fi
if grep -q "No open Dependabot pull requests" <<<"${populated}"; then
  _fail "a populated queue was reported as empty"
else
  _pass "a populated queue is not reported as empty"
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "test-run-digest: all assertions passed"
else
  echo "test-run-digest: FAILURES"
fi
exit "${fail}"
