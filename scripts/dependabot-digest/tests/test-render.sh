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

if [[ "${fail}" -eq 0 ]]; then
  echo "test-render: all assertions passed"
else
  echo "test-render: FAILURES"
fi
exit "${fail}"
