// Lost runner: a restart stopped the job. It failed, no step did. A hypothesis until the restart drill.

// Failed runs are listed from this far back, and lostChecked entries are kept this long.
export const LOST_WINDOW_MS = 6 * 3600000;

/** Run-level checks only: a first attempt that failed, from this repo, not from Dependabot. Read from the runs list. */
export function lostCandidate(run) {
  return (
    run?.run_attempt === 1 &&
    run.conclusion === "failure" &&
    typeof run.repository?.full_name === "string" &&
    run.head_repository?.full_name === run.repository.full_name &&
    run.actor?.login !== "dependabot[bot]"
  );
}

/** True when the run is a candidate and one of its pool-label jobs failed with no failed step. */
export function lostRunner(run, jobs, pool) {
  if (!lostCandidate(run)) return false;
  return (jobs ?? []).some(
    (j) =>
      (j.labels ?? []).includes(pool.label) &&
      j.conclusion === "failure" &&
      !(j.steps ?? []).some((s) => s.conclusion === "failure"),
  );
}

/** lostChecked without entries older than the window. */
export function pruneChecked(checked, now) {
  const out = {};
  for (const [k, t] of Object.entries(checked ?? {})) {
    if (typeof t === "number" && now - t <= LOST_WINDOW_MS) out[k] = t;
  }
  return out;
}
