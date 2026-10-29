#!/usr/bin/env bash
# dev-env#179: the section must never read "no warnings" when it could not tell.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN
# Inside a Claude Code session gh can be an exported function, which a child
# bash runs instead of the stub on PATH (dev-env#215).
unset -f gh

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/.."
FIX="${HERE}/fixtures/standards"
WORK="${TMPDIR:-/tmp}/dd-standards-test-$$"
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
# <name>.403.json: a refusal with a body, written to both streams as real gh does.
if [[ -f "${file%.json}.403.json" ]]; then
  cat "${file%.json}.403.json"
  echo "gh: $(jq -r '.message' "${file%.json}.403.json") (HTTP 403)" >&2
  exit 1
fi
# <name>.404.json: a 404 with a body; gh prints its message
# to stderr (2026-10-21 captures).
if [[ -f "${file%.json}.404.json" ]]; then
  cat "${file%.json}.404.json"
  echo "gh: $(jq -r '.message' "${file%.json}.404.json") (HTTP 404)" >&2
  exit 1
fi
# <name>.204: 204 No Content. Real gh prints nothing and exits 0.
[[ -f "${file%.json}.204" ]] && exit 0
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
if [[ "${o_count}" == "9" ]]; then
  _pass "every listed repo yields one record (9 of 9, across two pages)"
else
  _fail "owner o yielded ${o_count} records for 9 listed repos"
fi

_state o/warned ok "a merged PR's run is found when the default-branch head has none"
_state o/clean ok "a run on the default-branch head itself is used directly"
_state o/norun no-run "a repo with no standards-check run is reported, not dropped"
_state o/nulled unreadable "nulled check-run entries are unreadable, not 'no run'"
_state o/short unreadable "fewer annotations than the run reports is unreadable, not clean"
_state o/direct no-pr "a direct-push head with no run is reported"
_state o/old archived "an archived repo is named as skipped"
_state o/sleepy dormant "a repo with the dormant topic is named as skipped"
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
_has 'Dormant, not surveyed: o/sleepy.' "dormant repos are named" "${body}"
_hasnt '| o/sleepy |' "a dormant repo is not listed as not checked" "${body}"
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

# dev-env#211: real owner names, since exempt classes key on them. Branch
# fixtures: real 2026-10-21 captures, some with one field changed.
prot="${WORK}/prot.ndjson"
: >"${prot}"
for o in smartwatermelon nightowlstudiollc twistedmelonman; do
  if ! survey "${o}" >>"${prot}" 2>"${WORK}/${o}.err"; then
    _fail "standards.sh exited non-zero for owner ${o}"
  fi
done
_prot() {
  local got
  got="$(jq -r --arg r "$1" 'select(.repo == $r) | (.protection.state // "none") + " " + (.protection.exemptClass // "-")' "${prot}")"
  if [[ "${got}" == "$2" ]]; then _pass "$3"; else _fail "$3 (protection: '${got}', want '$2')"; fi
}
_prot smartwatermelon/dev-env "required -" "a real protected repo requiring standards-check is required"
_prot nightowlstudiollc/tnjcleaning "required -" "a real repo requiring only standards-check is required"
_prot nightowlstudiollc/cleanroom "required -" "a check with a null app_id still counts as required"
_prot nightowlstudiollc/nostd "protected-no-standards -" "a protected repo requiring other checks is flagged"
_prot nightowlstudiollc/offcheck "protected-no-standards -" "standards-check listed but enforcement off is not required"
_prot smartwatermelon/claude-config-backup "exempt smartwatermelon-private" \
  "a private unprotected smartwatermelon repo is exempt"
_prot twistedmelonman/Instapaper-MCP "exempt fork" "an unprotected fork is exempt"
_prot twistedmelonman/tm-private "exempt twistedmelonman-private" \
  "a private unprotected twistedmelonman repo is exempt"
_prot nightowlstudiollc/nos-private "unprotected -" \
  "a private unprotected nightowlstudiollc repo is unprotected, not exempt"
_prot twistedmelonman/tm-public "unprotected -" "a public unprotected repo is unprotected"
_prot smartwatermelon/withheld "unreadable -" \
  "protected with the protection object withheld is unreadable, not fine"
_prot smartwatermelon/nullflag "unreadable -" "a non-boolean protected flag is unreadable"
_prot smartwatermelon/noflags "unreadable -" \
  "unprotected with no fork or private flag is unreadable, not unprotected or exempt"
_prot smartwatermelon/refused "unreadable -" "a refused branch read is unreadable, not unprotected"
_prot twistedmelonman/tm-old "none -" "an archived repo has no protection result"
if jq -e 'select(.repo == "smartwatermelon/refused") | .protection.detail | test("HTTP 403")' "${prot}" >/dev/null 2>&1; then
  _pass "the reason a branch read failed is kept"
else
  _fail "the refused branch read lost its reason"
fi
# The protection probe must not depend on the standards survey: these repos
# have no commit fixtures, so their standards state is unreadable.
dev_env="$(jq -r 'select(.repo == "smartwatermelon/dev-env") | .state + " " + .protection.state' "${prot}")"
if [[ "${dev_env}" == "unreadable required" ]]; then
  _pass "a repo whose standards read failed still gets a protection result"
else
  _fail "the protection result depends on the standards read (got '${dev_env}')"
fi

pbody="${WORK}/prot.md"
: | bash "${DIR}/render.sh" --standards "${prot}" >"${pbody}" 2>/dev/null
_has '## Branch protection' "the protection section is rendered" "${pbody}"
_has '**17 repositories surveyed**: 6 require standards-check, 3 exempt, **4 need attention, 4 unreadable.**' \
  "the protection summary counts each state" "${pbody}"
_has '- fork: 1 — a fork is not ours to govern (decided 2026-10-21, dev-env#211)' "exempt repos are counted by class with the reason" "${pbody}"
# The alerts section lists repos too, so look only at the protection section.
sed -n '/^## Branch protection/,/^## CodeQL/p' "${pbody}" >"${WORK}/prot-section.md"
_hasnt '[twistedmelonman/Instapaper-MCP]' "exempt repos are not listed" "${WORK}/prot-section.md"
_hasnt '[smartwatermelon/dev-env]' "required repos are not listed" "${WORK}/prot-section.md"
_has '| [nightowlstudiollc/nos-private](https://github.com/nightowlstudiollc/nos-private) | UNPROTECTED: the default branch has no protection |' \
  "an unprotected repo is listed with a link" "${pbody}"
_has '| [nightowlstudiollc/nostd](https://github.com/nightowlstudiollc/nostd) | standards-check not required: requires only: test |' \
  "a protected repo without standards-check is listed with its checks" "${pbody}"
_has '| [smartwatermelon/withheld](https://github.com/smartwatermelon/withheld) | UNREADABLE:' \
  "an unreadable repo is listed as unreadable" "${pbody}"
_hasnt 'No gaps' "a survey with gaps does not claim none" "${pbody}"

# Every protection read failed (the o and p fixtures have no branch
# responses): an under-scoped token must not render as a clean fleet.
_has '**Protection could not be verified for any of 8 repositories.**' \
  "an all-unreadable protection survey says it verified nothing" "${body}"
_hasnt 'need attention' "an all-unreadable protection survey prints no counts" "${body}"
_hasnt 'No gaps' "an all-unreadable protection survey never claims no gaps" "${body}"
_has '**Not listed, so not surveyed:** q.' "an unlistable owner is named in the protection section" "${body}"

# All clean: an explicit statement, and no table.
jq -c 'select(.repo == "smartwatermelon/dev-env" or .repo == "twistedmelonman/Instapaper-MCP")' "${prot}" >"${WORK}/pclean.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/pclean.ndjson" >"${WORK}/pclean.md" 2>/dev/null
_has 'No gaps: every surveyed repository' "a fully protected survey says so" "${WORK}/pclean.md"
_hasnt '| Repo | Protection |' "a fully protected survey has no table" "${WORK}/pclean.md"

# A record with no protection field (a crashed survey) is unreadable.
printf '%s\n' '{"owner":"o","repo":"o/legacy","state":"ok","annotations":[]}' >"${WORK}/legacy.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/legacy.ndjson" >"${WORK}/legacy.md" 2>/dev/null
_has '| [o/legacy](https://github.com/o/legacy) | UNREADABLE: no protection result recorded |' \
  "a record without a protection field is unreadable, not clean" "${WORK}/legacy.md"
_hasnt 'No gaps' "a record without a protection field never reads as no gaps" "${WORK}/legacy.md"

# dev-env#166. Real 2026-10-21 captures: dev-env, cleanroom,
# claude-config-backup. The rest change one field of a real body.
_cq() {
  local got
  got="$(jq -r --arg r "$1" 'select(.repo == $r) | (.codeql.state // "none") + " " + (.codeql.exemptClass // "-")' "${prot}")"
  if [[ "${got}" == "$2" ]]; then _pass "$3"; else _fail "$3 (codeql: '${got}', want '$2')"; fi
}
_cq smartwatermelon/dev-env "configured -" "a real configured repo is configured"
_cq twistedmelonman/tm-private "configured -" "configured with no languages yet is still configured"
_cq nightowlstudiollc/tnjcleaning "not-configured -" "a public non-fork repo with default setup off is flagged"
_cq nightowlstudiollc/cleanroom "no-code-security -" \
  "a real private 'Code Security must be enabled' 403 is no-code-security, not exempt"
_cq smartwatermelon/claude-config-backup "no-code-security -" \
  "a real private 'Advanced Security must be enabled' 403 is no-code-security, not exempt"
_cq nightowlstudiollc/nos-private "unreadable -" \
  "a private 'Resource not accessible by integration' 403 is unreadable, never no-code-security"
_cq smartwatermelon/refused "unreadable -" "a refused read with no body is unreadable"
_cq twistedmelonman/tm-public "unreadable -" \
  "a paid-product 403 on a public repo is unreadable, not no-code-security"
_cq smartwatermelon/noflags "unreadable -" \
  "a paid-product 403 with no private flag is unreadable, not no-code-security"
_cq nightowlstudiollc/nostd "exempt no-supported-language" "not configured with no languages is exempt"
_cq twistedmelonman/Instapaper-MCP "exempt fork" "a fork with default setup off is exempt"
_cq nightowlstudiollc/offcheck "unreadable -" "an unknown state is unreadable"
_cq smartwatermelon/withheld "unreadable -" "malformed JSON is unreadable"
_cq twistedmelonman/tm-old "none -" "an archived repo has no CodeQL result"
if jq -e 'select(.repo == "nightowlstudiollc/nos-private") | .codeql.detail | test("Resource not accessible by integration")' "${prot}" >/dev/null 2>&1; then
  _pass "the reason a default-setup read failed is kept"
else
  _fail "the refused default-setup read lost its reason"
fi
o_clean_cq="$(jq -r 'select(.repo == "o/clean") | .codeql.state + ": " + .codeql.detail' "${out}")"
if [[ "${o_clean_cq}" == "unreadable: not configured, but the repository listing gave no fork flag"* ]]; then
  _pass "not configured with no fork flag is unreadable, not flagged or exempt"
else
  _fail "not configured with no fork flag was decided anyway (got '${o_clean_cq}')"
fi

# Semgrep CE replaces Code Security (2026-10-21). A failed read is unreadable.

# _sg <repo> <substitute> <detail substring, or - for none> <message>
_sg() {
  local st det
  st="$(jq -r --arg r "$1" 'select(.repo == $r) | .codeql.substitute // "-"' "${prot}")"
  det="$(jq -r --arg r "$1" 'select(.repo == $r) | .codeql.substituteDetail // "-"' "${prot}")"
  if [[ "${st}" == "$2" ]] && { [[ "$3" == "-" && "${det}" == "-" ]] \
    || [[ "$3" != "-" && "${det}" == *"$3"* ]]; }; then
    _pass "$4"
  else
    _fail "$4 (substitute: '${st}: ${det}', want '$2' with detail '$3')"
  fi
}
_sg nightowlstudiollc/cleanroom semgrep - "a caller of the reusable Semgrep workflow is semgrep"
_sg smartwatermelon/claude-config-backup none - "a 404 on the caller file is none"
_sg nightowlstudiollc/sg-other none "does not call" \
  "KNOWN-BAD: a caller whose only reference is commented out is none, not semgrep"
_sg nightowlstudiollc/sg-refused unreadable "HTTP 403" \
  "a refused caller read is unreadable with its reason, never none"
_sg nightowlstudiollc/sg-badenc unreadable "encoding: none" \
  "a caller that cannot be decoded is unreadable, never none or semgrep"
_sg smartwatermelon/dev-env - - "a repo with CodeQL configured gets no substitute probe"
_sg nightowlstudiollc/tnjcleaning - - "a not-configured repo gets no substitute probe"

_has '## CodeQL' "the CodeQL section is rendered" "${pbody}"
_has '**17 repositories surveyed**: 2 configured, 2 exempt, 1 covered by Semgrep, **1 not configured, 2 with no code scanning, 2 with Semgrep coverage unreadable, 7 unreadable.**' \
  "the CodeQL summary counts each state" "${pbody}"
_has '- fork: 1 — a fork is not ours to scan (decided 2026-10-21, dev-env#166)' \
  "CodeQL exemptions are counted by class with the reason" "${pbody}"
_hasnt '- no-code-security:' "no-code-security is not an exempt class" "${pbody}"
_hasnt '| [nightowlstudiollc/cleanroom](' "a repo without Code Security is not a table row" "${pbody}"
nocs_list="$(sed -n '/^### Without paid Code Security/,/^## Dependabot alerts/p' "${pbody}")"
if [[ "${nocs_list}" == *"not bought, by decision (2026-10-21"* \
  && "${nocs_list}" == *"Semgrep CE is the substitute"* \
  && "${nocs_list}" != *"open cost decision"* \
  && "${nocs_list}" == *"- [nightowlstudiollc/cleanroom](https://github.com/nightowlstudiollc/cleanroom)"* \
  && "${nocs_list}" == *"- [smartwatermelon/claude-config-backup](https://github.com/smartwatermelon/claude-config-backup)"* \
  && "${nocs_list}" != *"nos-private"* && "${nocs_list}" != *"tm-public"* ]]; then
  _pass "repos without Code Security are listed by name under their own heading, and only they are"
else
  _fail "the no-Code-Security list is wrong: ${nocs_list}"
fi
# Each sub-list stops at the next heading, so a repo cannot pass for another bucket.
_under() {
  awk -v h="$1" '$0 == h {on = 1; next} on && /^(#|---|\*\*Not listed)/ {exit} on {print}' "$2"
}
sg_cov="$(_under '#### Covered by Semgrep (CodeQL substitute)' "${pbody}")"
sg_none="$(_under '#### No code scanning: paid Code Security not bought, no Semgrep caller' "${pbody}")"
sg_unk="$(_under '#### Semgrep coverage unreadable' "${pbody}")"
if [[ "${sg_cov}" == *"[nightowlstudiollc/cleanroom]"* && "${sg_cov}" != *"claude-config-backup"* \
  && "${sg_cov}" != *"sg-"* ]]; then
  _pass "only the Semgrep caller is listed as covered"
else
  _fail "the covered-by-Semgrep list is wrong: ${sg_cov}"
fi
if [[ "${sg_none}" == *"[smartwatermelon/claude-config-backup]"* \
  && "${sg_none}" == *"[nightowlstudiollc/sg-other](https://github.com/nightowlstudiollc/sg-other): "*"does not call"* \
  && "${sg_none}" != *"cleanroom"* && "${sg_none}" != *"sg-refused"* && "${sg_none}" != *"sg-badenc"* ]]; then
  _pass "repos with no Semgrep caller are listed as no code scanning, with the reason when the file exists"
else
  _fail "the no-code-scanning list is wrong: ${sg_none}"
fi
if [[ "${sg_unk}" == *"[nightowlstudiollc/sg-refused]"*"HTTP 403"* && "${sg_unk}" == *"[nightowlstudiollc/sg-badenc]"* \
  && "${sg_unk}" == *"unknown"* && "${sg_unk}" != *"cleanroom"* && "${sg_unk}" != *"claude-config-backup"* ]]; then
  _pass "repos whose caller could not be read are listed as unreadable, in neither clean bucket"
else
  _fail "the Semgrep-unreadable list is wrong: ${sg_unk}"
fi
_has '| [nightowlstudiollc/tnjcleaning](https://github.com/nightowlstudiollc/tnjcleaning) | NOT CONFIGURED: default setup is off; languages: actions |' \
  "a not-configured repo is listed with its languages" "${pbody}"
_has '| [nightowlstudiollc/nos-private](https://github.com/nightowlstudiollc/nos-private) | UNREADABLE: cannot read default setup: ' \
  "a permission 403 is listed as unreadable with its reason" "${pbody}"
cq_body="$(sed -n '/^## CodeQL/,/^## Dependabot alerts/p' "${pbody}")"
for r in smartwatermelon/dev-env twistedmelonman/Instapaper-MCP nightowlstudiollc/nostd; do
  if [[ "${cq_body}" == *"[${r}]"* ]]; then _fail "configured or exempt repo ${r} is listed"; else _pass "configured or exempt repo ${r} is counted, not listed"; fi
done

# Every o and p read failed: a token without Administration: Read must not
# render as a clean fleet.
cq_all="$(sed -n '/^## CodeQL/,/^## Dependabot alerts/p' "${body}")"
if [[ "${cq_all}" == *"**CodeQL setup could not be verified for any of 8 repositories.**"* \
  && "${cq_all}" == *'Administration: Read'* && "${cq_all}" != *"No gaps"* \
  && "${cq_all}" != *"repositories surveyed"* ]]; then
  _pass "an all-unreadable CodeQL survey says it verified nothing and names the likely permission"
else
  _fail "an all-unreadable CodeQL survey read as a result: ${cq_all}"
fi

jq -c 'select(.repo == "smartwatermelon/dev-env" or .repo == "twistedmelonman/Instapaper-MCP")' "${prot}" >"${WORK}/cqclean.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/cqclean.ndjson" >"${WORK}/cqclean.md" 2>/dev/null
_has 'No gaps: every surveyed repository has default setup on' "a fully configured CodeQL survey says so" "${WORK}/cqclean.md"
_hasnt '| Repo | CodeQL default setup |' "a fully configured CodeQL survey has no table" "${WORK}/cqclean.md"
# A repo without Code Security alone is a gap, not "No gaps", and not a table row.
jq -c 'select(.repo == "smartwatermelon/dev-env" or .repo == "nightowlstudiollc/cleanroom")' "${prot}" >"${WORK}/cqnocs.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/cqnocs.ndjson" >"${WORK}/cqnocs.md" 2>/dev/null
sed -n '/^## CodeQL/,/^## Dependabot alerts/p' "${WORK}/cqnocs.md" >"${WORK}/cqnocs-section.md"
_hasnt 'No gaps' "a repo without Code Security is never reported as no gaps" "${WORK}/cqnocs-section.md"
_has '- [nightowlstudiollc/cleanroom]' "a lone repo without Code Security is listed by name" "${WORK}/cqnocs.md"
_hasnt '| Repo | CodeQL default setup |' "a repo without Code Security is not a table row" "${WORK}/cqnocs.md"
_has '| [o/legacy](https://github.com/o/legacy) | UNREADABLE: no CodeQL result recorded |' \
  "a record without a codeql field is unreadable, not clean" "${WORK}/legacy.md"

# Dependabot alerts. 2026-10-21 captures: dev-env 204,
# Instapaper-MCP 404. The 403 is modeled, not captured.
_al() {
  local got
  got="$(jq -r --arg r "$1" 'select(.repo == $r) | .alerts.state // "none"' "${prot}")"
  if [[ "${got}" == "$2" ]]; then _pass "$3"; else _fail "$3 (alerts: '${got}', want '$2')"; fi
}
_al smartwatermelon/dev-env on "a 204 is on"
_al nightowlstudiollc/cleanroom on "a 204 on a private repo is on"
_al twistedmelonman/Instapaper-MCP exempt "a fork with alerts off is exempt, not a gap"
_al smartwatermelon/noflags unreadable \
  "alerts off with no fork flag is unreadable: exemption cannot be decided"
if jq -e 'select(.repo == "smartwatermelon/noflags") | .alerts.detail | test("no fork flag, so exemption cannot be decided")' "${prot}" >/dev/null 2>&1; then
  _pass "the missing-fork-flag reason is kept for alerts"
else
  _fail "the missing-fork-flag alerts reason is wrong"
fi
_al nightowlstudiollc/tnjcleaning off "a disabled 404 on a public non-fork repo is off"
_al nightowlstudiollc/nos-private unreadable \
  "KNOWN-BAD: a bare 'Not Found' 404 is unreadable, never off"
_al smartwatermelon/refused unreadable \
  "KNOWN-BAD: a 'Resource not accessible by integration' 403 is unreadable, never off"
_al smartwatermelon/nullflag unreadable \
  "KNOWN-BAD: the disabled message on a 403 is unreadable, never off"
_al smartwatermelon/withheld unreadable "a read that returns a body is unreadable, not on"
_al twistedmelonman/tm-old none "an archived repo has no alerts result"
if jq -e 'select(.repo == "smartwatermelon/refused") | .alerts.detail | test("Resource not accessible by integration")' "${prot}" >/dev/null 2>&1; then
  _pass "the reason an alerts read failed is kept"
else
  _fail "the refused alerts read lost its reason"
fi

al_body="$(sed -n '/^## Dependabot alerts/,/^---/p' "${pbody}")"
if [[ "${al_body}" == *'**17 repositories surveyed**: 2 on, 1 exempt, **1 off, 13 unreadable.**'* ]]; then
  _pass "the alerts summary counts each state"
else
  _fail "the alerts summary is wrong: ${al_body}"
fi
if [[ "${al_body}" == *'| [nightowlstudiollc/tnjcleaning](https://github.com/nightowlstudiollc/tnjcleaning) | OFF: Dependabot security alerts are turned off |'* \
  && "${al_body}" == *'- fork: 1 — a fork is not ours to govern (decided 2026-10-21)'* \
  && "${al_body}" != *'[twistedmelonman/Instapaper-MCP]'* \
  && "${al_body}" == *'| [nightowlstudiollc/nos-private](https://github.com/nightowlstudiollc/nos-private) | UNREADABLE: cannot read the alerts setting: gh: Not Found (HTTP 404) |'* \
  && "${al_body}" != *'[smartwatermelon/dev-env]'* && "${al_body}" != *'[nightowlstudiollc/cleanroom]'* \
  && "${al_body}" != *'No gaps'* ]]; then
  _pass "off and unreadable repos are listed; on repos are counted, not listed"
else
  _fail "the alerts table is wrong: ${al_body}"
fi
# Off rows sort above unreadable rows.
first_row="$(grep -m1 '^| \[' <<<"${al_body}")"
if [[ "${first_row}" == *"| OFF:"* ]]; then
  _pass "off repos are listed before unreadable ones"
else
  _fail "the first alerts row is not an off repo: ${first_row}"
fi

# Every o and p read failed: a token without Administration: Read must not
# render as alerts on everywhere.
al_all="$(sed -n '/^## Dependabot alerts/,/^---/p' "${body}")"
if [[ "${al_all}" == *"**Alerts could not be verified for any of 8 repositories.**"* \
  && "${al_all}" == *'Administration: Read'* && "${al_all}" != *"No gaps"* \
  && "${al_all}" != *"repositories surveyed"* && "${al_all}" == *'**Not listed, so not surveyed:** q.'* ]]; then
  _pass "an all-unreadable alerts survey says it verified nothing and names the likely permission"
else
  _fail "an all-unreadable alerts survey read as a result: ${al_all}"
fi

jq -c 'select(.repo == "smartwatermelon/dev-env" or .repo == "nightowlstudiollc/cleanroom")' "${prot}" >"${WORK}/alclean.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/alclean.ndjson" >"${WORK}/alclean.md" 2>/dev/null
_has 'No gaps: every surveyed repository has Dependabot security alerts on or is exempt.' \
  "an all-on alerts survey says so" "${WORK}/alclean.md"
_hasnt '| Repo | Dependabot alerts |' "an all-on alerts survey has no table" "${WORK}/alclean.md"
_has '| [o/legacy](https://github.com/o/legacy) | UNREADABLE: no alerts result recorded |' \
  "a record without an alerts field is unreadable, not on" "${WORK}/legacy.md"

if [[ "${fail}" -eq 0 ]]; then
  echo "test-standards: all assertions passed"
else
  echo "test-standards: FAILURES"
fi
exit "${fail}"
