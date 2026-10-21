#!/usr/bin/env bash
# render.sh must produce a body that tells the truth about what will happen,
# and every script here must parse — an apostrophe inside a comment within a
# single-quoted jq program silently ends the string and breaks the file.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/.."
FIX="${HERE}/fixtures"
WORK="/tmp/dd-render-test-$$"
mkdir -p "${WORK}"
trap 'rm -rf "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# Every shell file in the directory must parse. This exists because the hazard
# is invisible on reading: these scripts embed jq programs in single quotes, and
# a comment containing an apostrophe ends that string early. It happened twice
# while writing them, and both times the file still looked correct.
for f in "${DIR}"/*.sh "${HERE}"/*.sh; do
  base="$(basename "${f}")" || base="${f}"
  if bash -n "${f}" 2>"${WORK}/syn.err"; then
    _pass "${base}: parses"
  else
    first_error="$(head -1 "${WORK}/syn.err")" || first_error="(no detail)"
    _fail "${base}: syntax error — ${first_error}"
  fi
done

# Every jq program embedded in these scripts must parse, and the ones that
# format diagnostics must also say what they mean. `+` binds tighter than `//`
# in jq, so `.type // "?" + ": " + .message` silently parses as
# `.type // ("?: " + .message)` and prints a bare "FORBIDDEN" with the message
# dropped — the failure is invisible until the moment you need the message.
# Extract the error formatter from collect.sh and run it against a real error
# body rather than eyeballing the source.
# The formatter spans several lines, so extract from `jq -r '.errors` to the
# closing quote rather than matching a single line. A line-based grep silently
# found nothing once the program was reformatted, which failed the assertion
# for the wrong reason.
gql_fmt="$(sed -n "/jq -r '\.errors/,/'[[:space:]]*<<</p" "${DIR}/collect.sh" \
  | sed "s/.*jq -r '//; s/'[[:space:]]*<<<.*//")"
if [[ -z "${gql_fmt}" ]]; then
  _fail "could not find the GraphQL error formatter in collect.sh"
else
  # The `path` matters as much as the message. It is what identified the
  # failing field as `commits` on 2026-09-11 — the message alone
  # ("Resource not accessible by personal access token") names no field, and
  # the CI log could not show which read was refused because collect.sh was
  # dropping the path.
  sample='{"errors":[{"type":"FORBIDDEN","path":["repository","pullRequest","commits","nodes",0],"message":"Resource not accessible by integration"}]}'
  formatted="$(jq -r "${gql_fmt}" <<<"${sample}" 2>/dev/null)"
  if [[ "${formatted}" == *"FORBIDDEN"* && "${formatted}" == *"not accessible"* ]]; then
    _pass "the GraphQL error formatter keeps both the type and the message"
  else
    _fail "the error formatter dropped part of the error: '${formatted}'"
  fi
  if [[ "${formatted}" == *"commits"* ]]; then
    _pass "the GraphQL error formatter keeps the field path"
  else
    _fail "the error formatter dropped the path, which names the failing field: '${formatted}'"
  fi
fi

body="${WORK}/body.md"
cat "${FIX}/synthetic.ndjson" "${FIX}/live-2026-09-11.ndjson" \
  | bash "${DIR}/classify.sh" \
  | bash "${DIR}/render.sh" --run-url "https://example/run/1" >"${body}" 2>"${WORK}/render.err"
if [[ ! -s "${body}" ]]; then
  _fail "render.sh produced no output"
  cat "${WORK}/render.err" >&2
fi

_has() {
  if grep -qF "$1" "${body}"; then _pass "$2"; else _fail "$2 (missing: $1)"; fi
}
_hasnt() {
  if grep -qF "$1" "${body}"; then _fail "$2 (present: $1)"; else _pass "$2"; fi
}

_has '<!-- dependabot-digest:v1 -->' \
  "carries the upsert marker, so the issue is matched by marker not title"

# The single most important property: a PR whose builds fail must never appear
# in the authorize block. Merge-lock lines are an invitation to merge, and
# every one of the four real PRs is MERGEABLE with required checks green.
authorize_section="$(sed -n '/^## Authorize/,$p' "${body}")"
for pr in kebab-tax-netlify cleanroom amelia-boone; do
  if grep -qF "${pr}" <<<"${authorize_section}"; then
    _fail "${pr} appears in the authorize block despite failing builds"
  else
    _pass "${pr} is not offered a merge-lock line"
  fi
done

_has 'merge-lock authorize o/ready#1 "ok"' \
  "emits a paste-ready lock line for a genuinely ready PR"

# The digest must not promise a merge it cannot promise: the hook runs an AI
# review that can block on content no classifier can predict.
_has 'not that the merge will succeed' \
  "states that a ready PR may still be blocked by the AI review"

_has 'inherited from a red base branch: audit-gate' \
  "attributes an inherited failure to the base branch"
_has 'base branch state unreadable' \
  "says so when base attribution could not be verified"

# Matrix jobs report one check per leg under one name. Listing it twice makes a
# PR look worse than it is.
if grep -q 'Code standards & build (24), Code standards & build (24)' "${body}"; then
  _fail "duplicate check names are not deduplicated"
else
  _pass "repeated matrix check names are deduplicated"
fi

_hasnt 'undefined' "no undefined values leaked into the body"
_has 'A digest older than a day or two is stale' \
  "carries its own staleness warning"

# Empty input is a real state (the queue does get cleared) and must render as
# a valid body, not a crash or a misleading blank.
empty="${WORK}/empty.md"
: | bash "${DIR}/render.sh" >"${empty}" 2>/dev/null
if grep -q 'No open Dependabot pull requests' "${empty}"; then
  _pass "an empty queue renders as an explicit statement"
else
  _fail "an empty queue did not render correctly"
fi

# dev-env#211: no survey, no protection section; a malformed one must not
# read clean.
_hasnt '## Branch protection' "no survey, no protection section"
printf '%s\n' '{not json' >"${WORK}/bad.ndjson"
: | bash "${DIR}/render.sh" --standards "${WORK}/bad.ndjson" >"${WORK}/bad.md" 2>/dev/null
# Each range stops at the next section, so one section's text cannot pass for another's.
prot_section="$(sed -n '/^## Branch protection/,/^## CodeQL/p' "${WORK}/bad.md")"
if [[ "${prot_section}" == *"**Not checked.**"* && "${prot_section}" != *"No gaps"* ]]; then
  _pass "a malformed survey renders protection as not checked"
else
  _fail "a malformed survey did not render protection as not checked: ${prot_section}"
fi
# dev-env#166: the same for the CodeQL section.
_hasnt '## CodeQL' "no survey, no CodeQL section"
cq_section="$(sed -n '/^## CodeQL/,/^---/p' "${WORK}/bad.md")"
if [[ "${cq_section}" == *"**Not checked.**"* && "${cq_section}" != *"No gaps"* ]]; then
  _pass "a malformed survey renders CodeQL as not checked"
else
  _fail "a malformed survey did not render CodeQL as not checked: ${cq_section}"
fi

# Semgrep CE (2026-10-21): no substitute field or an unknown one is unreadable.
: | bash "${DIR}/render.sh" --standards "${FIX}/codeql-semgrep.ndjson" >"${WORK}/sg.md" 2>/dev/null
_under() {
  awk -v h="$1" '$0 == h {on = 1; next} on && /^(#|---|\*\*Not listed)/ {exit} on {print}' "${WORK}/sg.md"
}
sg_sum="$(sed -n '/^## CodeQL/,/^---/p' "${WORK}/sg.md")"
if [[ "${sg_sum}" == *'**6 repositories surveyed**: 1 configured, 0 exempt, 1 covered by Semgrep, **0 not configured, 1 with no code scanning, 3 with Semgrep coverage unreadable, 0 unreadable.**'* ]]; then
  _pass "the CodeQL summary counts each Semgrep substitute state"
else
  _fail "the CodeQL summary miscounts Semgrep states: ${sg_sum}"
fi
if [[ "${sg_sum}" == *"Code Security is not bought, by decision (2026-10-21"* \
  && "${sg_sum}" == *"Semgrep CE is the substitute"* && "${sg_sum}" != *"open cost decision"* ]]; then
  _pass "the section says Code Security is not bought by decision and names Semgrep CE"
else
  _fail "the section still calls Code Security an open decision: ${sg_sum}"
fi
if [[ "${sg_sum}" == *"No gaps"* ]]; then
  _fail "a survey with repos lacking Code Security claims no gaps"
else
  _pass "a survey with repos lacking Code Security never claims no gaps"
fi
sg_cov="$(_under '#### Covered by Semgrep (CodeQL substitute)')"
sg_none="$(_under '#### No code scanning: paid Code Security not bought, no Semgrep caller')"
sg_unk="$(_under '#### Semgrep coverage unreadable')"
if [[ "${sg_cov}" == *"- [o/sg-covered](https://github.com/o/sg-covered)"* \
  && "${sg_cov}" != *"sg-none"* && "${sg_cov}" != *"sg-unreadable"* \
  && "${sg_cov}" != *"sg-older"* && "${sg_cov}" != *"sg-odd"* ]]; then
  _pass "only a semgrep record is listed as covered"
else
  _fail "the covered list is wrong: ${sg_cov}"
fi
if [[ "${sg_none}" == *"- [o/sg-none](https://github.com/o/sg-none)"* \
  && "${sg_none}" != *"sg-covered"* && "${sg_none}" != *"sg-unreadable"* \
  && "${sg_none}" != *"sg-older"* && "${sg_none}" != *"sg-odd"* ]]; then
  _pass "only a none record is listed as no code scanning"
else
  _fail "the no-code-scanning list is wrong: ${sg_none}"
fi
if [[ "${sg_unk}" == *"- [o/sg-unreadable](https://github.com/o/sg-unreadable): cannot read"*"HTTP 502"* \
  && "${sg_unk}" == *"- [o/sg-older](https://github.com/o/sg-older): no Semgrep result recorded"* \
  && "${sg_unk}" == *"- [o/sg-odd](https://github.com/o/sg-odd): "* \
  && "${sg_unk}" != *"sg-covered"* && "${sg_unk}" != *"sg-none]"* ]]; then
  _pass "unreadable, older-survey and unknown records are listed as unreadable with a reason"
else
  _fail "the Semgrep-unreadable list is wrong: ${sg_unk}"
fi
if [[ "${sg_sum}" == *"[o/configured]"* ]]; then
  _fail "a configured repo is listed in the CodeQL section"
else
  _pass "a configured repo is counted, not listed"
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "test-render: all assertions passed"
else
  echo "test-render: FAILURES"
fi
exit "${fail}"
