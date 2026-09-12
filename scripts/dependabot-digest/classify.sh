#!/usr/bin/env bash
# Read collect.sh output (newline-delimited JSON, one PR per line) on stdin and
# sort each PR into the bucket that names what a human must do about it.
#
# Usage: classify.sh < prs.ndjson > classified.ndjson
#
# The bucket mirrors the gate the user's merges actually pass through —
# ~/.claude/hooks/pre-merge-review.sh — NOT GitHub branch protection. The two
# differ, and the difference is the whole point: measured 2026-09-11, all four
# of the fleet's long-stalled PRs are MERGEABLE with every REQUIRED check green,
# so a bucket built on `isRequired` alone would have told the user to merge PRs
# whose builds genuinely fail. The hook is stricter, and it is what will run.
#
# Hook gates this reproduces (read from the hook, 2026-09-11):
#   - any NEUTRAL check blocks, EXCEPT names starting with "Pages changed",
#     "Header rules", "Redirect rules" (Netlify informational) or "Seer"
#     (advisory by policy).                              [hook lines 643-682]
#   - CHANGES_REQUESTED review decision blocks.          [hook lines 587-628]
#   - a merge-lock is always required.                   [hook lines ~540]
#
# One hook gate is deliberately NOT predicted: the AI pre-merge analysis can
# return BLOCK_MERGE on content grounds. No static classifier can anticipate
# that, so "ready-to-merge" here means "passes the mechanical gates", never
# "will merge". The renderer must say so rather than let the bucket imply it.
#
# Buckets, in the order a human should act on them:
#
#   ready-to-merge   Mechanical gates pass. Needs a merge-lock, then the AI
#                    review still has a vote.
#   update-branch    Mergeable but BEHIND its base; needs a rebase first.
#   conflicted       DIRTY: a real conflict only Dependabot can resolve.
#   needs-work       A REQUIRED check failed: genuinely needs code changes.
#   hook-blocked     GitHub would merge this, but pre-merge-review.sh will
#                    refuse it (a blocking NEUTRAL, or requested changes).
#   advisory-red     GitHub would merge and the hook allows it, but non-required
#                    checks are failing. Merging is possible and probably wrong.
#   waiting-on-ci    Required checks still queued or running.
#   held             A human labelled it to stay put, or it is a draft.
set -uo pipefail
unset CDPATH

# Labels meaning "a human deliberately parked this". These win over any
# computed bucket, so the digest never nags about a PR someone chose to hold.
hold_labels='["hold","on-hold","do-not-merge","blocked","wip"]'

# Check-name prefixes whose NEUTRAL the hook does not treat as blocking. Kept
# byte-identical to the hook's own list; if the hook's list changes, this must.
neutral_ok='["Pages changed","Header rules","Redirect rules","Seer"]'

# Buffer the input so the record count can be compared before and after. jq
# drops any record whose expression raises, and does so without a non-zero exit
# or a message — so "classified 3 of 4 PRs" would otherwise look like success.
# The whole value of this digest is that nothing goes unseen; losing a PR
# silently is the one failure it must not have.
input="$(cat)"

# grep -c exits 1 when it matches nothing and 2 when it cannot read: an empty
# queue is a legitimate state, an unreadable one is not, so the two must not be
# collapsed. A here-string always supplies a trailing newline, so empty input
# still presents one (blank) line to grep.
in_count="$(grep -c . <<<"${input}")"
in_rc=$?
if [[ "${in_rc}" -gt 1 ]]; then
  echo "classify.sh: could not read the input stream (grep exit ${in_rc})" >&2
  exit 1
fi
[[ -z "${in_count}" ]] && in_count=0

# Nothing in, nothing out — and specifically not the single newline that
# printf would otherwise emit, which downstream counts would read as one PR.
if [[ "${in_count}" -eq 0 ]]; then
  exit 0
fi

output="$(jq -c --argjson hold "${hold_labels}" --argjson neutral_ok "${neutral_ok}" '
  # A check counts as failed only on a conclusive negative. SKIPPED and NEUTRAL
  # are deliberately absent: SKIPPED means the job chose not to run, and NEUTRAL
  # is handled separately because the hook treats it as blocking rather than as
  # a failure (CodeQL returns NEUTRAL for "could not compare", not "found a
  # problem" — verified on twistedmelonman/personify#75).
  def failed: .conclusion as $c
    | ($c == "FAILURE" or $c == "TIMED_OUT" or $c == "CANCELLED"
       or $c == "STARTUP_FAILURE" or $c == "ERROR");

  # Still running. StatusContexts (Netlify previews) report an in-flight run as
  # state PENDING or EXPECTED with no separate status field, so those must be
  # caught here or an in-flight deploy would silently read as passed.
  def pending: (.status != "COMPLETED")
    or (.conclusion == null)
    or (.conclusion == "PENDING") or (.conclusion == "EXPECTED");

  # Does this NEUTRAL check block the hook?
  def neutral_blocks: (.conclusion == "NEUTRAL")
    and (.name as $n | any($neutral_ok[]; . as $p | $n | startswith($p)) | not);

  . as $pr
  | ([.checks[] | select(.required)]) as $req
  | ([$req[] | select(failed)]) as $req_failed
  | ([$req[] | select(pending)]) as $req_pending
  | ([.checks[] | select(.required | not) | select(failed)]) as $advisory_failed
  | ([.checks[] | select(neutral_blocks)]) as $neutral_blocking
  | ([.labels[] | select(. as $l | $hold | index($l))]) as $held_by
  | (.reviewDecision == "CHANGES_REQUESTED") as $changes_requested

  | .ageDays = (((now - (.createdAt | fromdateiso8601)) / 86400) | floor)
  | .staleDays = (((now - (.updatedAt | fromdateiso8601)) / 86400) | floor)
  | .requiredCount = ($req | length)
  # Deduplicate: a matrix job reports one check per leg under a single name
  # ("Code standards & build (24)" appears twice on amelia-boone), and listing
  # the same name repeatedly makes a two-failure PR look like a seven-failure
  # one.
  | .blockingFailures = ([$req_failed[].name] | unique)
  | .advisoryFailures = ([$advisory_failed[].name] | unique)

  # Split failures into those the PR inherited from an already-red default
  # branch and those it owns. baseRed == null means the base state could not be
  # read; in that case claim nothing rather than blame every failure on the PR.
  | (($req_failed + $advisory_failed) | map(.name) | unique) as $all_failed
  | .baseRed as $base_red
  | .baseRedKnown = ($base_red != null)
  | .inheritedFailures = (
      if $base_red == null then []
      else [$all_failed[] | select($base_red | index(.))] end)
  | .ownFailures = (
      if $base_red == null then $all_failed
      else [$all_failed[] | select(($base_red | index(.)) | not)] end)
  | .hookBlockers = (
      [$neutral_blocking[] | "NEUTRAL: " + .name]
      + (if $changes_requested then ["review: CHANGES_REQUESTED"] else [] end))

  | .bucket = (
      if ($held_by | length) > 0 or .isDraft then "held"
      elif ($req_failed | length) > 0 then "needs-work"
      elif .mergeStateStatus == "DIRTY" or .mergeable == "CONFLICTING" then "conflicted"
      elif ($req_pending | length) > 0 then "waiting-on-ci"
      elif (.hookBlockers | length) > 0 then "hook-blocked"
      elif .mergeStateStatus == "BEHIND" then "update-branch"
      elif ($advisory_failed | length) > 0 then "advisory-red"
      elif .mergeable == "MERGEABLE" then "ready-to-merge"
      else "waiting-on-ci"
      end)

  # Why this PR is not already merged by the auto-merge workflow. State only
  # what was computed from the title, never a guess: the workflow declines
  # majors and multi-dependency groups by policy, but a title that does not
  # parse is reported as unclassified rather than asserted to be a major.
  # `capture` raises an error when the pattern does not match, and an erroring
  # record is dropped from the output stream entirely — a digest that silently
  # loses PRs is worse than no digest. Grouped-update titles ("bump the npm
  # group across 1 directory with 8 updates") do not match, so this is the
  # common path, not an edge case. `?//` supplies null instead of erroring.
  | (.title | capture("bump (?<dep>[^ ]+) from (?<from>[0-9][^ ]*) to (?<to>[0-9][^ ]*)")? // null) as $bump
  | .whyManual = (
      if .autoMerge then "auto-merge armed"
      elif (.title | test("group across|with [0-9]+ updates")) then "grouped update"
      elif $bump == null then "unclassified (title does not parse)"
      elif (($bump.from | split(".")[0]) != ($bump.to | split(".")[0]))
        then "major: " + $bump.dep + " " + ($bump.from | split(".")[0]) + "→" + ($bump.to | split(".")[0])
      # A patch or minor that did not auto-merge is itself a finding: policy
      # says it should have. Name that rather than shrug, but do not guess at
      # the cause — it is recorded in the auto-merge workflow run logs.
      else "patch/minor that did not auto-merge — check the workflow run"
      end)
' <<<"${input}")"
jq_rc=$?

out_count="$(grep -c . <<<"${output}")"
out_rc=$?
if [[ "${out_rc}" -gt 1 ]]; then
  echo "classify.sh: could not count the classified records (grep exit ${out_rc})" >&2
  exit 1
fi
[[ -z "${output}" || -z "${out_count}" ]] && out_count=0

if [[ "${jq_rc}" -ne 0 ]]; then
  echo "classify.sh: jq failed (exit ${jq_rc})" >&2
  exit 1
fi
if [[ "${out_count}" -ne "${in_count}" ]]; then
  echo "classify.sh: classified ${out_count} of ${in_count} PRs —" \
    "${in_count} in, ${out_count} out. Some record raised an error and was" \
    "dropped; the digest would be incomplete. Refusing to emit it." >&2
  exit 1
fi

printf '%s\n' "${output}"
