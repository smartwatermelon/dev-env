#!/usr/bin/env bash
# Measure a --mode=codebase prompt variant against the #440 regression corpus.
#
# Usage:
#   ./measure.sh --variant=narrowed  [--limit=N] [--only=claude-config#166]
#   ./measure.sh --variant=baseline  [--limit=N]
#   ./measure.sh --variant=control   [--limit=N]
#
# Variants:
#   baseline  the production CODEBASE_PROMPT, unnarrowed (the incumbent)
#   narrowed  the same prompt with step 4 replaced by the four no-successor classes
#   control   a deliberately blind prompt that should find nothing; proves a
#             low score means something rather than being an artifact of the harness
#
# For each corpus member the reviewer is given the historical buggy file and
# asked to review it. A HIT is scored when a returned finding's location names
# the corpus member's file and lands within +/- LINE_TOLERANCE of the known
# line, OR when the finding text unambiguously describes the same defect.
# Location matching is automatic; the text fallback is recorded for hand
# adjudication rather than auto-scored, so the headline number is never
# inflated by a generous string match.

set -euo pipefail

CORPUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_CLI="${CLAUDE_CLI:-${HOME}/.local/bin/claude}"
LINE_TOLERANCE="${LINE_TOLERANCE:-25}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
MODEL="${MODEL:-claude-sonnet-4-6}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

VARIANT=""
LIMIT=0
ONLY=""

for arg in "$@"; do
  case "${arg}" in
    --variant=*) VARIANT="${arg#*=}" ;;
    --limit=*) LIMIT="${arg#*=}" ;;
    --only=*) ONLY="${arg#*=}" ;;
    *)
      printf 'unknown argument: %s\n' "${arg}" >&2
      exit 2
      ;;
  esac
done

case "${VARIANT}" in
  baseline | narrowed | control) : ;;
  *)
    printf 'need --variant=baseline|narrowed|control\n' >&2
    exit 2
    ;;
esac

CORPUS_JSON="${CORPUS_DIR}/corpus.json"
if [[ ! -f "${CORPUS_JSON}" ]]; then
  printf 'corpus not found: %s\n' "${CORPUS_JSON}" >&2
  exit 1
fi

RESULTS_DIR="${CORPUS_DIR}/results/${VARIANT}"
mkdir -p "${RESULTS_DIR}"

REVIEW_JSON_SCHEMA='{"type":"object","required":["verdict","blocking","findings"],"properties":{"verdict":{"type":"string","enum":["PASS","FAIL"]},"blocking":{"type":"boolean"},"findings":{"type":"array","items":{"type":"object","required":["severity","location","issue"],"properties":{"severity":{"type":"string","enum":["BLOCKING","FIX_NOW","WARNING"]},"location":{"type":"string"},"issue":{"type":"string"},"details":{"type":"string"}}}}}}'

# --- Prompt construction -----------------------------------------------------

build_prompt() {
  local variant="$1" file="$2" language="$3"

  local hunt
  case "${variant}" in
    baseline)
      hunt="$(cat "${CORPUS_DIR}/prompt-baseline-step4.txt")"
      ;;
    narrowed)
      hunt="$(cat "${CORPUS_DIR}/prompt-narrowed.txt")"
      ;;
    control)
      hunt="REVIEW PROCEDURE:
1. Read the file.
2. Report only defects relating to indentation consistency and trailing
   whitespace. Report nothing else under any circumstance."
      ;;
    *)
      printf 'build_prompt: unknown variant %s\n' "${variant}" >&2
      return 1
      ;;
  esac

  printf '%s\n' "You are performing a codebase-aware review of a single ${language} file.
You have full tool access: Read, Grep, Glob.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.

File under review: ${file}

Read the file in full and review it.

${hunt}

Report each defect you find with a LOCATION of the form <file>:<line>, naming
the single most relevant line. Use severity BLOCKING for a defect that would
break correctness or security, FIX_NOW for a small mechanical fix, WARNING
otherwise. If you find no defects, return an empty findings array."
}

# --- Scoring -----------------------------------------------------------------

score_member() {
  local id="$1" want_path="$2" want_line="$3" raw="$4"
  local want_base
  want_base="$(basename "${want_path}")"

  # Location hits: same file basename, line within tolerance.
  # Validated against known-good and known-bad inputs before use: a finding on
  # the right file within tolerance scores 1; wrong line, wrong file, and an
  # empty findings array each score 0. An earlier form of this expression
  # scored the known-good case 0, which would have read as total prompt
  # failure for every variant.
  printf '%s' "${raw}" | jq -r --arg base "${want_base}" --argjson want "${want_line}" --argjson tol "${LINE_TOLERANCE}" '
    [ (.structured_output.findings // [])[]
      | (.location // "") | split(":")
      | select(length >= 2)
      | select((.[0] | split("/") | last) == $base)
      | (.[1] | tonumber? // -1)
      | select(. >= ($want - $tol) and . <= ($want + $tol))
    ] | length' 2>/dev/null || echo 0
}

# --- Main loop ---------------------------------------------------------------

total=0
hits=0
errored=0
declare -a rows=()

members="$(jq -c '.[] | select(.status == "CONFIRMED")' "${CORPUS_JSON}")"

while IFS= read -r member <&3; do
  [[ -n "${member}" ]] || continue

  id="$(printf '%s' "${member}" | jq -r '.id')"
  [[ -z "${ONLY}" || "${ONLY}" == "${id}" ]] || continue

  if [[ "${LIMIT}" -gt 0 && "${total}" -ge "${LIMIT}" ]]; then
    break
  fi

  path="$(printf '%s' "${member}" | jq -r '.path')"
  line="$(printf '%s' "${member}" | jq -r '.line')"
  language="$(printf '%s' "${member}" | jq -r '.language')"
  slug="$(printf '%s' "${id}" | tr '#/' '--')"
  filedir="${CORPUS_DIR}/files/${slug}"
  target="${filedir}/$(basename "${path}")"

  if [[ ! -f "${target}" ]]; then
    printf 'SKIP %s — recovered file missing: %s\n' "${id}" "${target}" >&2
    continue
  fi

  total=$((total + 1))
  out="${RESULTS_DIR}/${slug}.json"

  if [[ -f "${out}" && -s "${out}" ]]; then
    printf 'cached %s\n' "${id}" >&2
  else
    prompt="$(build_prompt "${VARIANT}" "${target}" "${language}")"

    # Retry on transient CLI failure. A run can come back with EMPTY stdout and
    # EMPTY stderr — observed when two variants ran concurrently, most likely a
    # rate limit. An empty result is indistinguishable from "the reviewer found
    # nothing", which would silently score as a MISS and understate the variant.
    # That is the exact false-OK shape this corpus exists to catch, so it is
    # treated as a hard failure rather than an empty finding set.
    attempt=0
    rc=0
    while :; do
      attempt=$((attempt + 1))
      printf 'running %s (%s, attempt %d)\n' "${id}" "${VARIANT}" "${attempt}" >&2
      rc=0
      # The prompt is passed via a temp file rather than a pipe, and the loop
      # reads members on FD 3. Both matter: `claude` consumes stdin, so with a
      # plain `while read ... done 3<<<"${members}"` the CLI ate the remaining
      # member list and the loop silently ended after ONE uncached member —
      # while still exiting 0 and printing a re-find rate. That is the same
      # false-OK shape this corpus catalogues.
      prompt_file="$(mktemp)"
      printf '%s' "${prompt}" >"${prompt_file}"
      timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" \
        --agent "adversarial-reviewer" -p \
        --model "${MODEL}" \
        --output-format json \
        --json-schema "${REVIEW_JSON_SCHEMA}" \
        --allowedTools "Read,Grep,Glob" \
        --no-session-persistence \
        <"${prompt_file}" >"${out}" 2>"${out}.err" || rc=$?
      rm -f "${prompt_file}"

      if [[ "${rc}" -eq 0 && -s "${out}" ]] && jq -e '.structured_output' "${out}" >/dev/null 2>&1; then
        break
      fi

      out_bytes=$(wc -c <"${out}")
      out_bytes="${out_bytes// /}"
      printf 'WARN %s attempt %d failed (rc=%d, %s bytes)\n' \
        "${id}" "${attempt}" "${rc}" "${out_bytes}" >&2

      if [[ "${attempt}" -ge "${MAX_ATTEMPTS}" ]]; then
        printf 'ERROR %s: no usable output after %d attempts — recording as ERROR, not as a miss\n' \
          "${id}" "${attempt}" >&2
        printf '%s\n' "${id}" >>"${RESULTS_DIR}/ERRORS.txt"
        rm -f "${out}"
        break
      fi
      sleep $((attempt * 20))
    done

    if [[ ! -s "${out}" ]]; then
      errored=$((errored + 1))
      total=$((total - 1))
      continue
    fi
  fi

  raw="$(cat "${out}")"
  n="$(score_member "${id}" "${path}" "${line}" "${raw}")"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0

  if [[ "${n}" -gt 0 ]]; then
    hits=$((hits + 1))
    rows+=("HIT   ${id} (${path}:${line})")
  else
    rows+=("MISS  ${id} (${path}:${line})")
  fi
done 3<<<"${members}"

# --- Report ------------------------------------------------------------------

# Count members directly from the corpus rather than by counting lines of
# jq output: same answer today (verified 47 = 47), but it cannot drift on a
# trailing-newline or grep-implementation difference, and a miscount here
# would either fire the guard on a clean run or hide a truncated one.
expected="$(jq '[.[] | select(.status == "CONFIRMED")] | length' "${CORPUS_JSON}")"
if [[ "${LIMIT}" -eq 0 && -z "${ONLY}" ]] \
  && [[ $((total + errored)) -lt "${expected}" ]]; then
  printf '\nFATAL: processed %d of %d corpus members. The run ended early and\n' \
    "$((total + errored))" "${expected}" >&2
  printf 'the rate below would be computed over a truncated denominator.\n' >&2
  exit 3
fi

printf '\n=== %s ===\n' "${VARIANT}"
for r in "${rows[@]}"; do printf '%s\n' "${r}"; done

if [[ "${total}" -gt 0 ]]; then
  pct=$((hits * 100 / total))
else
  pct=0
fi
printf '\nre-find rate: %d/%d (%d%%)\n' "${hits}" "${total}" "${pct}"
if [[ "${errored}" -gt 0 ]]; then
  printf 'excluded from denominator: %d member(s) with no usable output (see %s/ERRORS.txt)\n' \
    "${errored}" "${RESULTS_DIR}" >&2
fi
