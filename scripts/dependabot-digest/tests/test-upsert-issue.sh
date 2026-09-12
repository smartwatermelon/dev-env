#!/usr/bin/env bash
# upsert-issue.sh must find the digest issue it wrote last time, or it opens a
# duplicate every run. That path had no coverage until 2026-09-11, and it was
# broken the whole time: the script searched for the literal marker
# `<!-- dependabot-digest:v1 -->`, which GitHub's body index tokenizes away to
# nothing. Verified against a live probe issue — the full-marker query returned
# empty while the bare word matched immediately.
#
# The stub below reproduces that tokenization rather than assuming it: a search
# whose term contains `<!--` or `:v1` matches nothing, exactly as the real API
# behaves. A fix that merely reorders the code but keeps an untokenizable term
# still fails here.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN GH_HOST GITHUB_TOKEN

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/.."
WORK="/tmp/dd-upsert-test-$$"
BIN="${WORK}/bin"
mkdir -p "${BIN}"
trap 'rm -rf "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

MARKER='<!-- dependabot-digest:v1 -->'
BODY="${MARKER}

## Dependabot queue

Nothing to do."

# Stub gh, emulating GitHub's search tokenization. State lives in files so the
# stub can record what it was asked to do.
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
log="${STUB_LOG}"
case "$1" in
  api)
    if [[ "$*" == "api user"* ]]; then echo 'twistedmelonman'; else echo '{}'; fi ;;
  issue)
    case "$2" in
      list)
        if [[ "$*" == *"--search"* ]]; then
          # Extract the search term as passed.
          term=""
          prev=""
          for a in "$@"; do
            [[ "${prev}" == "--search" ]] && term="${a}"
            prev="${a}"
          done
          # GitHub's index drops HTML-comment punctuation and colon-suffixed
          # tokens. A term still carrying them matches nothing.
          if [[ "${term}" == *"<!--"* || "${term}" == *":v1"* ]]; then
            echo '[]' | jq -r '.[]'
            exit 0
          fi
          if [[ -f "${STUB_STATE}/issue" ]]; then echo "7"; fi
          exit 0
        fi
        # Unfiltered listing: not search-indexed, sees the issue immediately.
        if [[ -f "${STUB_STATE}/issue" ]]; then echo "7"; fi
        exit 0 ;;
      view)
        if [[ -f "${STUB_STATE}/issue" ]]; then cat "${STUB_STATE}/issue"; fi
        exit 0 ;;
      edit)
        echo "EDIT $3" >>"${log}"
        exit 0 ;;
      create)
        echo "CREATE" >>"${log}"
        cp /dev/null "${STUB_STATE}/issue"
        echo "https://github.com/o/r/issues/7"
        exit 0 ;;
    esac ;;
esac
# Any gh call this stub does not model is a test defect, not a pass. Returning
# an empty JSON array here would let an unmodelled call read as "nothing found"
# — the same false-OK shape this whole script exists to prevent.
echo "stub gh: unexpected call: $*" >&2
exit 90
STUB
chmod +x "${BIN}/gh"

export STUB_STATE="${WORK}/state"
export STUB_LOG="${WORK}/log"
mkdir -p "${STUB_STATE}"
: >"${STUB_LOG}"

# --- No existing issue: must create one. ---
out="$(PATH="${BIN}:${PATH}" bash "${DIR}/upsert-issue.sh" o/r "T" <<<"${BODY}" 2>&1)"
if grep -q "CREATE" "${STUB_LOG}" && grep -q "created" <<<"${out}"; then
  _pass "creates the digest issue when none exists"
else
  _fail "did not create an issue when none existed: ${out}"
fi

# --- Existing issue: must EDIT, never create a second. ---
# This is the assertion the shipped code failed. The issue now exists and its
# body carries the marker; a correct search term finds it.
printf '%s\n' "${BODY}" >"${STUB_STATE}/issue"
: >"${STUB_LOG}"
out="$(PATH="${BIN}:${PATH}" bash "${DIR}/upsert-issue.sh" o/r "T" <<<"${BODY}" 2>&1)"
if grep -q "EDIT 7" "${STUB_LOG}" && ! grep -q "CREATE" "${STUB_LOG}"; then
  _pass "updates the existing digest issue instead of duplicating it"
else
  _fail "did not find the existing issue — it would have opened a duplicate: ${out}"
fi

# --- Search index lagging: the unfiltered listing must still find it. ---
# Emulates two runs in quick succession, which is what a human does when
# verifying the workflow. Search returns nothing; the listing carries the day.
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
log="${STUB_LOG}"
case "$1" in
  api)
    if [[ "$*" == "api user"* ]]; then echo 'twistedmelonman'; else echo '{}'; fi ;;
  issue)
    case "$2" in
      list)
        # Search is always cold here; the plain listing still sees the issue.
        if [[ "$*" == *"--search"* ]]; then exit 0; fi
        if [[ -f "${STUB_STATE}/issue" ]]; then echo "7"; fi
        exit 0 ;;
      view) cat "${STUB_STATE}/issue"; exit 0 ;;
      edit) echo "EDIT $3" >>"${log}"; exit 0 ;;
      create) echo "CREATE" >>"${log}"; echo "https://github.com/o/r/issues/8"; exit 0 ;;
    esac ;;
esac
# Any gh call this stub does not model is a test defect, not a pass. Returning
# an empty JSON array here would let an unmodelled call read as "nothing found"
# — the same false-OK shape this whole script exists to prevent.
echo "stub gh: unexpected call: $*" >&2
exit 90
STUB
chmod +x "${BIN}/gh"
: >"${STUB_LOG}"
out="$(PATH="${BIN}:${PATH}" bash "${DIR}/upsert-issue.sh" o/r "T" <<<"${BODY}" 2>&1)"
if grep -q "EDIT 7" "${STUB_LOG}" && ! grep -q "CREATE" "${STUB_LOG}"; then
  _pass "finds the issue via the listing when the search index is cold"
else
  _fail "a cold search index would have opened a duplicate: ${out}"
fi

# --- A failed search must abort, not fall through to creating a duplicate. ---
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  api)
    if [[ "$*" == "api user"* ]]; then echo 'twistedmelonman'; else echo '{}'; fi ;;
  issue)
    case "$2" in
      list) exit 1 ;;
      create) echo "CREATE" >>"${STUB_LOG}"; echo "https://github.com/o/r/issues/9"; exit 0 ;;
    esac ;;
esac
# Any gh call this stub does not model is a test defect, not a pass. Returning
# an empty JSON array here would let an unmodelled call read as "nothing found"
# — the same false-OK shape this whole script exists to prevent.
echo "stub gh: unexpected call: $*" >&2
exit 90
STUB
chmod +x "${BIN}/gh"
: >"${STUB_LOG}"
PATH="${BIN}:${PATH}" bash "${DIR}/upsert-issue.sh" o/r "T" <<<"${BODY}" >/dev/null 2>&1
rc=$?
if [[ "${rc}" -ne 0 ]] && ! grep -q "CREATE" "${STUB_LOG}"; then
  _pass "a failed issue query aborts instead of creating a duplicate"
else
  _fail "a failed issue query did not abort (exit ${rc})"
fi

# --- A body missing the marker must be refused. ---
PATH="${BIN}:${PATH}" bash "${DIR}/upsert-issue.sh" o/r "T" <<<"no marker here" >/dev/null 2>&1
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  _pass "a body without the marker is refused"
else
  _fail "a body without the marker was accepted"
fi

# --- The marker the script writes must be findable by the term it searches. ---
# The structural guarantee, independent of any stub: whatever term the script
# searches for must literally occur in the marker it requires. This is the
# invariant the shipped code violated.
script_marker="$(grep -m1 "^marker=" "${DIR}/upsert-issue.sh" | sed "s/^marker='//; s/'$//")"
script_term="$(grep -m1 "^search_term=" "${DIR}/upsert-issue.sh" | sed "s/^search_term='//; s/'$//")"
if [[ -n "${script_term}" ]] && grep -qF "${script_term}" <<<"${script_marker}"; then
  _pass "the search term occurs in the marker (${script_term})"
else
  _fail "search term '${script_term}' does not occur in marker '${script_marker}'"
fi
# And it must be a plain token GitHub can index: no HTML-comment punctuation.
if [[ "${script_term}" != *"<"* && "${script_term}" != *"!"* && "${script_term}" != *":"* ]]; then
  _pass "the search term is a plain indexable token"
else
  _fail "search term '${script_term}' contains punctuation GitHub's index drops"
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "test-upsert-issue: all assertions passed"
else
  echo "test-upsert-issue: FAILURES"
fi
exit "${fail}"
