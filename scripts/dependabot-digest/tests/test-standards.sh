#!/usr/bin/env bash
# dev-env#179: the section must never read "no warnings" when it could not tell.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/.."
FIX="${HERE}/fixtures/standards"
WORK="/tmp/dd-standards-test-$$"
BIN="${WORK}/bin"
mkdir -p "${BIN}"
trap 'rm -rf "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# Stub gh api: fixtures/standards/<path, / as _>.json. No fixture means HTTP 403.
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "api" ]] || { echo '[]'; exit 0; }
shift
path="" expr=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) expr="$2"; shift 2 ;;
    --*) shift ;;
    *) path="$1"; shift ;;
  esac
done
# The gh wrapper on PATH asks for the current identity before forwarding any
# command, as test-run-digest.sh notes; answer it.
[[ "${path}" == "user" ]] && { echo 'twistedmelonman'; exit 0; }
path="${path%%\?*}"
file="${STUB_FIX}/${path//\//_}.json"
[[ "${path}" == "installation/repositories" ]] && file="${file}.${STUB_OWNER}"
if [[ ! -f "${file}" ]]; then
  echo "gh: Resource not accessible by integration (HTTP 403)" >&2
  exit 1
fi
if [[ -n "${expr}" ]]; then jq -r "${expr}" "${file}"; else cat "${file}"; fi
STUB
chmod +x "${BIN}/gh"

survey() {
  PATH="${BIN}:${PATH}" STUB_FIX="${FIX}" STUB_OWNER="$1" GH_TOKEN=t \
    bash "${DIR}/standards.sh" "$1"
}

out="${WORK}/standards.ndjson"
: >"${out}"
for o in o p q; do
  if ! survey "${o}" >>"${out}" 2>"${WORK}/${o}.err"; then
    _fail "standards.sh exited non-zero for owner ${o}; per-repo failures must be records, not crashes"
  fi
done

state_of() { jq -r --arg r "$1" 'select(.repo == $r) | .state' "${out}"; }
_state() {
  local got
  got="$(state_of "$1")"
  if [[ "${got}" == "$2" ]]; then _pass "$3"; else _fail "$3 (state: '${got}', want '$2')"; fi
}

# Every listed repository must yield exactly one record.
o_count="$(jq -s '[.[] | select(.owner == "o")] | length' "${out}")"
if [[ "${o_count}" == "8" ]]; then
  _pass "every listed repo yields one record (8 of 8, across two pages)"
else
  _fail "owner o yielded ${o_count} records for 8 listed repos"
fi

_state o/warned ok "a merged PR's run is found when the default-branch head has none"
_state o/clean ok "a run on the default-branch head itself is used directly"
_state o/norun no-run "a repo with no standards-check run is reported, not dropped"
_state o/nulled unreadable "nulled check-run entries are unreadable, not 'no run'"
_state o/short unreadable "fewer annotations than the run reports is unreadable, not clean"
_state o/direct no-pr "a direct-push head with no run is reported"
_state o/old archived "an archived repo is named as skipped"
_state o/forbidden unreadable "a refused read is unreadable"

# Re-runs leave several runs on one commit. Only the latest counts.
warned_ann="$(jq -c 'select(.repo == "o/warned") | [.annotations[].message]' "${out}")"
if [[ "${warned_ann}" == *"below the floor"* && "${warned_ann}" == *"no shell files"* ]]; then
  _pass "warning and notice annotations are both kept"
else
  _fail "expected warning and notice annotations, got ${warned_ann}"
fi
if [[ "${warned_ann}" == *"SC2086"* ]]; then
  _fail "a failure-level annotation was listed as a warning"
else
  _pass "failure-level annotations are excluded"
fi
if grep -q 'forbidden.*HTTP 403' "${out}"; then
  _pass "the reason a read failed is kept in the record"
else
  _fail "the refused read lost its reason"
fi
q_rec="$(jq -c 'select(.owner == "q")' "${out}")"
q_shape="$(jq -r '.state + " " + (.repo | tostring)' <<<"${q_rec}")"
if [[ "${q_shape}" == "unlisted null" ]]; then
  _pass "an owner whose repos cannot be listed yields one unlisted record"
else
  _fail "an unlistable owner was not reported: ${q_rec}"
fi

# Render the section from the survey.
body="${WORK}/body.md"
: | bash "${DIR}/render.sh" --standards "${out}" >"${body}" 2>"${WORK}/render.err"
_has() { if grep -qF -- "$1" "$3"; then _pass "$2"; else _fail "$2 (missing: $1)"; fi; }
_hasnt() { if grep -qF -- "$1" "$3"; then _fail "$2 (present: $1)"; else _pass "$2"; fi; }

_has '## Standards warnings' "the section is rendered" "${body}"
_has '**3 repositories checked**: 1 with warnings or notices, 2 with none. **6 not checked.**' \
  "the summary counts what is shown: filtered-out repos count as none" "${body}"
_has "| [o/warned](https://github.com/x/runs/11) | 2026-10-03 | warning | \`.github/workflows/ci.yml:12\` | node-version 18 is below the floor 22 |" \
  "a warning row names repo, run date, level, file and message, linked to the run" "${body}"
_has "| notice | \`.github/workflows/build.yml:7\` | node-version is an expression" \
  "a one-off notice is still listed" "${body}"

# Change 1: routine notices are dropped, exact text, notice level only.
_hasnt 'no shell files' "a routine notice (no shell files) is dropped" "${body}"
_hasnt '| notice | — | no workflows |' "a routine notice (no workflows) is dropped" "${body}"
_has '| warning | — | no workflows |' \
  "KNOWN-BAD: a warning-level row with routine text survives" "${body}"

# Change 2: a notice repeated across repos collapses to one line with a count.
_has '- 2 repositories carry the same notice: The ubuntu-latest label will migrate' \
  "a repeated notice is shown once with a repo count" "${body}"
_hasnt '| notice | — | The ubuntu-latest label' "the repeated notice is not a per-repo row" "${body}"
_hasnt 'none shown' "clean repos are counted, not listed as rows" "${body}"
_hasnt '| [p/pwarned](https://github.com/x/runs/70)' \
  "a repo whose only rows were collapsed is not listed as a row" "${body}"

# Change 3: run dates and the stale-run flag.
_hasnt '| [o/clean](https://github.com/x/runs/20)' "a clean stale repo has no table row" "${body}"
_has 'Predate current rules: o/clean.' \
  "KNOWN-BAD: a stale repo with no rows is named in the stale list, not lost" "${body}"
_has '**1 run(s) predate current rules**' "the stale count is stated" "${body}"
_has 'as of 2026-10-02' "the tag is resolved through the annotated tag to its commit date" "${body}"
_hasnt '2026-10-03 — **predates' "a run newer than the tag is not flagged" "${body}"

# A tag that cannot be resolved must be said, not silently skipped.
FIX2="${WORK}/fix-notag"
cp -R "${FIX}" "${FIX2}"
rm -f "${FIX2}"/repos_smartwatermelon_github-workflows_*
PATH="${BIN}:${PATH}" STUB_FIX="${FIX2}" STUB_OWNER=o GH_TOKEN=t \
  bash "${DIR}/standards.sh" o >"${WORK}/notag.ndjson" 2>/dev/null
: | bash "${DIR}/render.sh" --standards "${WORK}/notag.ndjson" >"${WORK}/notag.md" 2>/dev/null
_has '**Rules date unknown**' "an unresolvable tag is reported" "${WORK}/notag.md"
_has 'cannot read tag standards-check-v1' "the reason the tag failed is kept" "${WORK}/notag.md"
_hasnt 'predates current rules' "no stale flag is invented without a rules date" "${WORK}/notag.md"
_has '### Not checked' "unreadable repos get their own subsection" "${body}"
_has '| o/nulled | UNREADABLE:' "a nulled run is shown as unreadable" "${body}"
_has '| o/norun | no standards-check run:' "a repo with no run is shown by name" "${body}"
_has '| all of q | OWNER NOT LISTED:' "an unlistable owner is shown" "${body}"
_has 'Archived, not surveyed: o/old.' "archived repos are named" "${body}"
_has 'not that the whole repository is' "the scope limit of a PR run is stated" "${body}"
_hasnt 'No warnings:' "a section with warnings does not claim none" "${body}"

# All clean: the empty state must be an explicit statement.
clean="${WORK}/clean.ndjson"
jq -c 'select(.repo == "o/clean")' "${out}" >"${clean}"
: | bash "${DIR}/render.sh" --standards "${clean}" >"${WORK}/clean.md" 2>/dev/null
_has 'No warnings: no checked repository' "a clean survey says so explicitly" "${WORK}/clean.md"
_hasnt '### Not checked' "a fully read survey has no not-checked list" "${WORK}/clean.md"
_hasnt '| Repo | Latest run |' "zero warnings renders no table" "${WORK}/clean.md"
_hasnt 'could not be rendered' "zero warnings is not a render failure" "${WORK}/clean.md"
_has 'Predate current rules: o/clean.' "the stale repo is listed when no table is" "${WORK}/clean.md"

# Clean repos alongside an unreadable one: "no warnings" must not hide the gap.
mixed="${WORK}/mixed.ndjson"
jq -c 'select(.repo == "o/clean" or .repo == "o/nulled")' "${out}" >"${mixed}"
: | bash "${DIR}/render.sh" --standards "${mixed}" >"${WORK}/mixed.md" 2>/dev/null
_has '**1 not checked.**' "not-checked repos are counted next to a clean result" "${WORK}/mixed.md"
_has '| o/nulled | UNREADABLE:' "not-checked repos are listed next to a clean result" "${WORK}/mixed.md"

# Every repo unreadable: zero warnings from zero reads is not "no warnings".
jq -c 'select(.repo == "o/nulled")' "${out}" >"${WORK}/allbad.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/allbad.ndjson" >"${WORK}/allbad.md" 2>/dev/null
_has '**No repository could be checked**' "an all-unreadable survey says nothing was checked" "${WORK}/allbad.md"
_hasnt 'No warnings' "an all-unreadable survey never claims no warnings" "${WORK}/allbad.md"

# A survey that produced nothing, or garbage, is not a clean survey.
: >"${WORK}/empty.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/empty.ndjson" >"${WORK}/empty.md" 2>/dev/null
_has '**Not checked.**' "an empty survey renders as not checked" "${WORK}/empty.md"
_hasnt 'No warnings' "an empty survey never claims no warnings" "${WORK}/empty.md"
printf '%s\n' '{"owner":"o","repo":"o/clean","state":"ok","annotations":[]}' '{not json' >"${WORK}/bad.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/bad.ndjson" >"${WORK}/bad.md" 2>/dev/null
_has 'output is malformed' "a malformed survey renders as not checked" "${WORK}/bad.md"
_hasnt 'No warnings' "a malformed survey never claims no warnings" "${WORK}/bad.md"

# Without --standards there was no survey, and the section must not appear.
: | bash "${DIR}/render.sh" >"${WORK}/none.md" 2>/dev/null
_hasnt '## Standards warnings' "no survey, no section" "${WORK}/none.md"

if [[ "${fail}" -eq 0 ]]; then
  echo "test-standards: all assertions passed"
else
  echo "test-standards: FAILURES"
fi
exit "${fail}"
