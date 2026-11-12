import { decide } from "./decide.js";
import * as gh from "./github.js";

// Free plan allows 50 subrequests a run; KV calls are counted too, for headroom.
export const CAP = 40;
// Kept free while scanning: var PATCH, var POST fallback, ntfy, state put.
const RESERVE_REQUIRED = 4;
// Kept free during optional work: the pendingReruns put.
const RESERVE_FINAL = 1;
// Left free by the scan when a sweep or rerun is likely; unscanned repos wait for the rotation.
const OPTIONAL_SHARE = 10;
// A pending run is dropped after this many failed status or rerun calls.
const MAX_ATTEMPTS = 6;
const FALLBACK = "ubuntu-latest";
const TOKEN_TTL = 3000;
// Skipped ticks in a row (about 30 minutes) before the one "watchdog skipping" alert.
const SKIP_ALERT = 3;
// Sends per alert. A tick sends at most two alerts, so retries fit in the CAP headroom.
const NTFY_TRIES = 3;

const MESSAGES = {
  down: () =>
    "NOS runner down: NOS_RUNNER set to ubuntu-latest; stuck runs cancelled for re-run.",
  recovered: () => "NOS runner recovered: NOS_RUNNER set to mimolette.",
  online: () => "NOS runner online: NOS_RUNNER was unset, now mimolette.",
  held: (v) =>
    `NOS runner held: NOS_RUNNER=${v}; the watchdog leaves it alone.`,
};

// Logs name the failed call and status only, never a URL, token or topic.
const describe = (e) =>
  e instanceof gh.GitHubError ? e.message : (e?.name ?? "Error");
const log = (msg, e) => console.log(e ? `${msg} (${describe(e)})` : msg);
const runKey = (p) => `${p.repo}#${p.runId}`;

function makeBudget(cap) {
  let used = 0;
  return {
    take() {
      used += 1;
    },
    canAfford(n) {
      return used + n <= cap;
    },
  };
}

/** One watchdog tick. deps: {fetch, now}. Every fetch and KV call is counted against CAP. */
export async function runTick(env, { fetch: rawFetch, now }) {
  const budget = makeBudget(CAP);
  const fetchFn = (url, init) => {
    budget.take();
    return rawFetch(url, init);
  };
  const kv = {
    get(k) {
      budget.take();
      return env.STATE.get(k);
    },
    put(k, v, opts) {
      budget.take();
      return env.STATE.put(k, v, opts);
    },
    delete(k) {
      budget.take();
      return env.STATE.delete(k);
    },
  };

  const stateRaw = await kv.get("state");
  const prev = parseOr(
    stateRaw,
    { lastVar: null, misses: 0, goods: 0 },
    "state",
  );
  const pendingRaw = await kv.get("pendingReruns");
  const pending = parseOr(pendingRaw, [], "pendingReruns");
  // Skip tracking lives outside state, which a skipped tick must not touch. A good tick only reads it.
  const skipsRaw = await kv.get("skips");
  const skips = parseOr(skipsRaw, null, "skips");
  // ntfy.sh drops many Worker connections (522), so retry network errors and 5xx.

  // Without the token, Worker posts share one exhausted IP quota (429).
  const headers = { "Content-Type": "text/plain" };
  if (env.NTFY_TOKEN) headers.Authorization = `Bearer ${env.NTFY_TOKEN}`;
  const notify = async (text) => {
    for (let i = 1; i <= NTFY_TRIES && budget.canAfford(1); i += 1) {
      try {
        const res = await fetchFn(`https://ntfy.sh/${env.NTFY_TOPIC}`, {
          method: "POST",
          headers,
          body: text,
        });
        if (res.ok) return true;
        log(`ntfy failed: HTTP ${res.status} (try ${i})`);
        if (res.status < 500) return false;
      } catch (e) {
        log(`ntfy failed (try ${i})`, e);
      }
    }
    return false;
  };
  // On a skipped tick: count it, and alert once at SKIP_ALERT in a row.
  const skipTick = async (msg, e) => {
    log(msg, e);
    const count = (skips?.count ?? 0) + 1;
    let notified = skips?.notified === true;
    if (count >= SKIP_ALERT && !notified) {
      notified = await notify(`watchdog skipping: ${reasonClass(e)}`);
    }
    await kv.put("skips", JSON.stringify({ count, notified }));
  };

  let token = null;
  let cached = false;
  const mint = async () => {
    token = await gh.appToken(env, fetchFn, now);
    cached = false;
    await kv.put("token", token, { expirationTtl: TOKEN_TTL });
  };
  // A cached token that gets 401 is dropped and re-minted once (4 calls; optional work needs budget for them).
  const withToken = async (fn, optionalWork = false) => {
    try {
      return await fn(token);
    } catch (e) {
      if (!(e instanceof gh.GitHubError && e.status === 401 && cached)) throw e;
      if (optionalWork && !budget.canAfford(4 + RESERVE_FINAL)) throw e;
      await kv.delete("token");
      await mint();
      return fn(token);
    }
  };

  // Required phase: any failure skips the tick; state, pendingReruns and GitHub stay untouched (the token cache may change).
  const sweepLikely =
    pending.length > 0 ||
    prev.lastVar === FALLBACK ||
    prev.lastVar === null ||
    (prev.misses ?? 0) >= 1;
  const scanReserve =
    RESERVE_REQUIRED + (skips ? 2 : 0) + (sweepLikely ? OPTIONAL_SHARE : 0);
  let observed;
  let scan;
  let repoOldest;
  try {
    token = await kv.get("token");
    cached = Boolean(token);
    if (!token) await mint();
    const runners = await withToken((t) => gh.getRunners(t, fetchFn));
    const varValue = await withToken((t) => gh.getVar(t, fetchFn));
    const canFetch = (n) => budget.canAfford(n + scanReserve);
    const cursor = prev.cursor ?? 0;
    scan = await withToken((t) =>
      gh.scanQueue(t, fetchFn, { cursor, canFetch }),
    );
    repoOldest = mergeOldest(scan, prev.repoOldest ?? {});
    const times = Object.values(repoOldest);
    observed = {
      varValue,
      runners,
      oldestQueuedMinutes:
        times.length > 0 ? (now - Math.min(...times)) / 60000 : null,
    };
  } catch (e) {
    await skipTick("tick skipped: input failed", e);
    return;
  }

  const decision = decide(prev, observed);
  if (decision.setVar) {
    try {
      await withToken((t) => gh.setVar(t, decision.setVar, fetchFn));
    } catch (e) {
      // State is not saved, so the next tick sees the same variable and decides again.
      await skipTick("tick skipped: var write failed", e);
      return;
    }
  }
  // After a down switch, in_progress mimolette jobs stay in the sweep until the rotation covered every repo.
  const fallback = decision.next.lastVar === FALLBACK;
  const prevLeft = fallback ? (prev.downSweepLeft ?? 0) : 0;
  const downSweep = decision.rerunStuck || prevLeft > 0;
  const downSweepLeft = Math.max(
    0,
    (decision.rerunStuck ? scan.all.length : prevLeft) - scan.repos.length,
  );
  // State goes before ntfy: a failed state put loses at most one alert and never sends two.
  await kv.put(
    "state",
    JSON.stringify({
      ...decision.next,
      cursor: scan.nextCursor,
      repoOldest,
      downSweepLeft,
    }),
  );
  if (decision.notify) {
    await notify(MESSAGES[decision.notify](decision.next.lastVar));
  }
  if (skips) {
    if (skips.notified) await notify("watchdog ok: ticks are running again.");
    await kv.delete("skips");
  }

  // Optional phase. A budget skip leaves work for the next tick; 401/403/429 stop the phase.
  let stopped = false;
  const optional = async (fn, reserve) => {
    if (stopped || !budget.canAfford(1 + reserve)) return { skipped: true };
    try {
      return { ok: true, value: await withToken(fn, true) };
    } catch (e) {
      log("optional call failed", e);
      const status = e instanceof gh.GitHubError ? e.status : 0;
      if (status === 401 || status === 403 || status === 429) stopped = true;
      return { ok: false, status };
    }
  };

  // Pending runs: re-run once completed; drop after MAX_ATTEMPTS failures. Unchecked entries go first next tick.
  const waiting = [];
  const next = [];
  const failed = (p) => {
    const attempts = (p.attempts ?? 0) + 1;
    if (attempts >= MAX_ATTEMPTS) {
      log(`pending dropped after ${attempts} failures: ${runKey(p)}`);
    } else {
      next.push({ ...p, attempts });
    }
  };
  for (const p of pending) {
    const run = await optional(
      (t) => gh.getRun(t, p.repo, p.runId, fetchFn),
      RESERVE_FINAL,
    );
    if (run.skipped) waiting.push(p);
    else if (!run.ok) failed(p);
    else if (run.value?.status !== "completed") next.push(p);
    else if ((run.value.run_attempt ?? 1) >= 2) continue;
    else if (rerunnable(run.value.conclusion, p)) {
      const rr = await optional(
        (t) => gh.rerunFailed(t, p.repo, p.runId, fetchFn),
        RESERVE_FINAL,
      );
      if (rr.skipped) waiting.push(p);
      else if (!rr.ok) failed(p);
    }
  }

  // Plan cancels within the budget: each planned run keeps one call for its cancel.
  const planned = [];
  if (decision.rerunStuck || decision.next.lastVar === FALLBACK) {
    const statuses = downSweep ? ["queued", "in_progress"] : ["queued"];
    const candidates = [];
    for (const r of scan.repos) {
      for (const run of r.runs) {
        // A re-run attempt already moved once; never cancel it again.
        if (run.run_attempt >= 2) continue;
        candidates.push({ repo: r.repo, id: run.id, jobs: r.jobs.get(run.id) });
      }
    }
    candidates.sort((a, b) => (a.jobs ? 0 : 1) - (b.jobs ? 0 : 1));
    for (const c of candidates) {
      let jobs = c.jobs;
      if (!jobs) {
        const r = await optional(
          (t) => gh.getJobs(t, c.repo, c.id, fetchFn),
          RESERVE_FINAL + planned.length + 1,
        );
        if (r.skipped) break;
        if (!r.ok) continue;
        jobs = r.value;
      }
      if (gh.mimoletteJobs(jobs, statuses).length === 0) continue;
      if (!budget.canAfford(RESERVE_FINAL + planned.length + 1)) break;
      planned.push({
        repo: c.repo,
        runId: c.id,
        ...(downSweep && { down: true }),
      });
    }
  }

  // Pending is written before any cancel, so a later failure cannot strand a cancelled run.
  const kept = [...waiting, ...next];
  const known = new Set(kept.map(runKey));
  const toWrite = [
    ...kept,
    ...planned
      .filter((p) => !known.has(runKey(p)))
      .map((p) => ({ ...p, attempts: 0 })),
  ];
  if (JSON.stringify(toWrite) !== JSON.stringify(pending)) {
    await kv.put("pendingReruns", JSON.stringify(toWrite));
  }
  for (const p of planned) {
    await optional((t) => gh.cancelRun(t, p.repo, p.runId, fetchFn), 0);
  }
}

// A run we cancelled is re-run; a failure only when the down sweep cancelled it (a hung job can fail first).
function rerunnable(conclusion, entry) {
  return (
    conclusion === "cancelled" ||
    (conclusion === "failure" && entry.down === true)
  );
}

// Short class for the skip alert: never a URL, token or message body.
function reasonClass(e) {
  if (!(e instanceof gh.GitHubError))
    return e?.name === "TypeError"
      ? "network"
      : `internal ${e?.name ?? "Error"}`;
  if (e.status === 401) return `github auth (${e.what})`;
  if (e.status === 403 || e.status === 429)
    return `github rate limit or permission (${e.what})`;
  if (e.status >= 500) return `github 5xx (${e.what})`;
  return `github ${e.status} (${e.what})`;
}

function parseOr(raw, fallback, key) {
  if (!raw) return fallback;
  try {
    return JSON.parse(raw);
  } catch {
    log(`corrupt KV value ignored: ${key}`);
    return fallback;
  }
}

// Per-repo oldest queued time: fresh for scanned repos, carried for the rest of the installation.
function mergeOldest(scan, carried) {
  const out = {};
  const scanned = new Set(scan.repos.map((r) => r.repo));
  for (const r of scan.repos) if (r.oldestAt !== null) out[r.repo] = r.oldestAt;
  for (const repo of scan.all) {
    if (!scanned.has(repo) && typeof carried[repo] === "number") {
      out[repo] = carried[repo];
    }
  }
  return out;
}

export default {
  async scheduled(event, env) {
    await runTick(env, {
      fetch: (url, init) => fetch(url, init),
      now: event?.scheduledTime ?? Date.now(),
    });
  },
};
