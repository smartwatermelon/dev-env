#!/usr/bin/env bash
# classify.sh must put every PR in the bucket that names what a human has to do
# about it, and must never drop a PR from the stream.
set -uo pipefail
unset CDPATH
# Hermetic: bash sources BASH_ENV in every non-interactive shell, and this
# machine's profile defines a `gh` shell function there. classify.sh does not
# call gh, but the same profile can also alter jq behavior, so unset it.
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY="${HERE}/../classify.sh"
FIX="${HERE}/fixtures"
WORK="/tmp/dd-classify-test-$$"
mkdir -p "${WORK}"
trap 'rm -rf "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

out="${WORK}/synthetic.out"
if ! bash "${CLASSIFY}" <"${FIX}/synthetic.ndjson" >"${out}" 2>"${WORK}/synthetic.err"; then
  _fail "classify.sh exited non-zero on the synthetic fixture"
  cat "${WORK}/synthetic.err" >&2
fi

# bucket_of <repo> -> the bucket assigned to that fixture record
bucket_of() {
  jq -r --arg r "$1" 'select(.repo == $r) | .bucket' "${out}"
}
field_of() {
  jq -r --arg r "$1" --arg f "$2" 'select(.repo == $r) | .[$f] | tostring' "${out}"
}

# Each case states the behavior it pins, not just the expected string, because
# several of these encode a distinction that was got wrong before.
expect_bucket() {
  local repo="$1" want="$2" why="$3" got
  got="$(bucket_of "${repo}")" || got=""
  if [[ "${got}" == "${want}" ]]; then
    _pass "${repo}: ${want} (${why})"
  else
    _fail "${repo}: expected ${want}, got ${got:-<missing>} (${why})"
  fi
}

expect_bucket o/ready ready-to-merge \
  "all required green, nothing advisory red"
expect_bucket o/hookblocked hook-blocked \
  "a non-required NEUTRAL CodeQL does not block GitHub but does block the hook"
expect_bucket o/neutralok ready-to-merge \
  "NEUTRAL on Netlify informational and Seer checks is excluded by the hook"
expect_bucket o/needswork needs-work \
  "a failing REQUIRED check is the only thing that means code changes"
expect_bucket o/behind update-branch "mergeable but BEHIND its base"
expect_bucket o/conflicted conflicted "DIRTY means a real conflict"
expect_bucket o/pendingctx waiting-on-ci \
  "a StatusContext still PENDING must not read as passed"
expect_bucket o/inherited advisory-red "red, but inherited from a red base branch"
expect_bucket o/held held "a hold label wins over any computed bucket"
expect_bucket o/changesreq hook-blocked "CHANGES_REQUESTED blocks the hook"
expect_bucket o/baseunknown advisory-red "base state unknown, still not ready"

# The inherited/own split is what tells a human whether to fix the PR or the
# repo. Getting it backwards sends them to the wrong file.
inherited_of_inherited="$(field_of o/inherited inheritedFailures)" || inherited_of_inherited=""
own_of_inherited="$(field_of o/inherited ownFailures)" || own_of_inherited=""
want_inherited='["audit-gate"]'
want_own='[]'
if [[ "${inherited_of_inherited}" == "${want_inherited}" \
  && "${own_of_inherited}" == "${want_own}" ]]; then
  _pass "o/inherited: audit-gate attributed to the base branch, not the PR"
else
  _fail "o/inherited: inherited/own split wrong (inherited=${inherited_of_inherited}, own=${own_of_inherited})"
fi

# When the base branch could not be read, claiming the PR owns its failures
# would be an assertion the data does not support.
base_known="$(field_of o/baseunknown baseRedKnown)" || base_known=""
base_inherited="$(field_of o/baseunknown inheritedFailures)" || base_inherited=""
if [[ "${base_known}" == "false" && "${base_inherited}" == "${want_own}" ]]; then
  _pass "o/baseunknown: unknown base state claims no attribution"
else
  _fail "o/baseunknown: should report baseRedKnown=false and claim nothing"
fi

# whyManual must state what was computed, never guess. A grouped-update title
# does not parse as a version bump, and saying "major" there would be a claim
# the script never checked.
why_needswork="$(field_of o/needswork whyManual)" || why_needswork=""
if [[ "${why_needswork}" == "major: vitest 3→5" ]]; then
  _pass "whyManual states the computed semver jump"
else
  _fail "whyManual should read 'major: vitest 3→5', got '${why_needswork}'"
fi
why_hookblocked="$(field_of o/hookblocked whyManual)" || why_hookblocked=""
if [[ "${why_hookblocked}" == "grouped update" ]]; then
  _pass "whyManual reports a grouped update as grouped, not as a major"
else
  _fail "whyManual should read 'grouped update', got '${why_hookblocked}'"
fi

# No PR may be silently lost. jq drops a record whose expression raises without
# any error or non-zero exit, so a digest can quietly go incomplete — which
# defeats its only purpose. This is the guard, and the case below proves the
# guard is not vacuous.
in_n="$(grep -c . "${FIX}/synthetic.ndjson")" || in_n=0
out_n="$(grep -c . "${out}")" || out_n=0
if [[ "${in_n}" -eq "${out_n}" ]]; then
  _pass "every input PR appears in the output (${in_n})"
else
  _fail "dropped PRs: ${in_n} in, ${out_n} out"
fi

# Guard the guard: break capture() the way it was actually broken, and confirm
# classify.sh refuses to emit rather than returning a short list. Without this,
# the count assertion above could pass while proving nothing.
broken="${WORK}/broken-classify.sh"
# Build the sed program from a literal dollar rather than writing it inline,
# so the pattern reaches sed unexpanded without a single-quoted dollar for
# the linter to flag. The two forms must be byte-identical to the ones in
# classify.sh; the guard below proves the substitution actually happened.
dollar='\044'
good_form="$(printf '")? // null) as %bbump' "${dollar}")"
bad_form="$(printf '")) as %bbump' "${dollar}")"
sed "s|${good_form}|${bad_form}|" "${CLASSIFY}" >"${broken}"
if ! grep -qF "${bad_form}" "${broken}"; then
  _fail "could not reproduce the known-bad capture form; this test proves nothing"
elif bash "${broken}" <"${FIX}/synthetic.ndjson" >/dev/null 2>&1; then
  _fail "known-bad capture form still exited 0; the drop guard is not working"
else
  _pass "known-bad capture form is caught by the drop guard"
fi

# An empty queue is a real state. classify.sh must emit nothing at all for it:
# a lone newline would be counted downstream as one record, so the digest would
# report a PR that does not exist and the "queue: clear" title would never fire.
empty_out="$(: | bash "${CLASSIFY}" 2>/dev/null; printf 'rc=%s' "$?")"
if [[ "${empty_out}" == "rc=0" ]]; then
  _pass "empty input produces no output and exits 0"
else
  _fail "empty input should emit nothing and exit 0, got '${empty_out}'"
fi

# The real fleet state on 2026-09-11, recorded before it changed. All four of
# these were MERGEABLE with every required check green, which is exactly why a
# bucket built on branch protection alone would have recommended merging PRs
# whose builds fail.
real="${WORK}/real.out"
if bash "${CLASSIFY}" <"${FIX}/live-2026-09-11.ndjson" >"${real}" 2>/dev/null; then
  real_rows="$(grep -c . "${real}")" || real_rows=0
  if [[ "${real_rows}" -eq 4 ]]; then
    _pass "real fixture: all 4 PRs classified"
  else
    _fail "real fixture: expected 4 rows, got ${real_rows}"
  fi
  ready_rows="$(jq -r 'select(.bucket == "ready-to-merge")' "${real}" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${ready_rows}" == "0" ]]; then
    _pass "real fixture: none recommended for merge despite all being MERGEABLE"
  else
    _fail "real fixture: a PR with failing builds was put in ready-to-merge"
  fi
else
  _fail "classify.sh failed on the real fixture"
fi


# A check whose fields came back null is an access failure, not a passing
# check. GitHub returns statusCheckRollup with HTTP 200 and the correct
# totalCount, then nulls every CheckRun a fine-grained token may not read —
# Checks: read cannot be granted to one at all
# (github.com/orgs/community/discussions/129512). Measured 2026-09-11: 11 of 12
# contexts null, and the one survivor was a Netlify StatusContext.
#
# collect.sh refuses that response outright. This asserts the consequence if it
# ever stops doing so: nulled checks must never read as "nothing is failing".
nulled='{"repo":"o/r","number":9,"title":"chore: bump foo from 1.0.0 to 2.0.0","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","reviewDecision":null,"autoMerge":false,"labels":[],"checks":[{"name":null,"conclusion":null,"status":null,"required":null}],"baseRed":[]}'
nulled_bucket="$(bash "${CLASSIFY}" <<<"${nulled}" | jq -r '.bucket')"
if [[ -z "${nulled_bucket}" ]]; then
  _fail "the nulled-checks assertion produced no bucket — it would pass vacuously"
fi
if [[ "${nulled_bucket}" == "ready-to-merge" ]]; then
  _fail "a PR whose checks are all null classified as ready-to-merge — a token that cannot read checks would recommend merging failing PRs"
else
  _pass "nulled checks do not classify as ready-to-merge (got ${nulled_bucket})"
fi


if [[ "${fail}" -eq 0 ]]; then
  echo "test-classify: all assertions passed"
else
  echo "test-classify: FAILURES"
fi
exit "${fail}"