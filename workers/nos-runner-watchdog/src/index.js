import { decide } from "./decide.js";
import * as gh from "./github.js";
import { APPS, POOLS, poolForCron, appEnv } from "./pools.js";
import {
  LOST_WINDOW_MS,
  lostCandidate,
  lostRunner,
  pruneChecked,
} from "./lost.js";

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
const TOKEN_TTL = 3000;
// Skipped ticks in a row (about 30 minutes) before the one "watchdog skipping" alert.
const SKIP_ALERT = 3;
// Sends per alert. A tick sends at most two alerts, so retries fit in the CAP headroom.
const NTFY_TRIES = 3;
// Lost-runner phase, per probe: the jobs GET, the lostChecked put, the rerun POST, and the last lostChecked put.
const PROBE_COST = 4;
// Left free by the scan on a rerunLost pool: the lostChecked get, one failed-runs list, one probe.
const LOST_SHARE = 1 + 1 + PROBE_COST;
// lostChecked also holds the lost-phase repo cursor under this key; a "<repo>#<runId>" key can never equal it.
const CURSOR_KEY = "_cursor";

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

/** One tick for one pool. deps: {fetch, now, pool}. Every fetch and KV call is counted against CAP. */
export async function runTick(env, { fetch: rawFetch, now, pool = POOLS.nos }) {
  // An optional pool without its App secrets touches nothing: no fetch, no KV, not even the skips counter.
  const app = appEnv(env, pool);
  if (!app && pool.optional) {
    log(`pool ${pool.id} not configured: App secrets missing`);
    return;
  }
  // Other pools mint from their own App's raw values, so a missing secret fails the mint and goes through skipTick.
  const a = APPS[pool.app];
  const creds = app ?? {
    APP_ID: env[a.idKey],
    INSTALLATION_ID: env[a.installKey],
    APP_KEY_PKCS8: env[a.keyKey],
  };
  const budget = makeBudget(CAP);
  const fetchFn = (url, init) => {
    budget.take();
    return rawFetch(url, init);
  };
  // Every key carries the pool prefix; NOS has none, so its keys are unchanged.
  const key = (k) => `${pool.prefix}${k}`;
  const kv = {
    get(k) {
      budget.take();
      return env.STATE.get(key(k));
    },
    put(k, v, opts) {
      budget.take();
      return env.STATE.put(key(k), v, opts);
    },
    delete(k) {
      budget.take();
      return env.STATE.delete(key(k));
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
  // A drill request (any value) sends one test alert after the state put. Set it by hand to test delivery.
  const drill = await kv.get("drill");
  // ntfy.sh drops many Worker connections (522), so retry network errors and 5xx.
  // Without the token, Worker posts share one exhausted IP quota (429).
  const headers = { "Content-Type": "text/plain" };
  if (env.NTFY_TOKEN) headers.Authorization = `Bearer ${env.NTFY_TOKEN}`;
  let notifyTries = 0;
  const notify = async (text) => {
    notifyTries = 0;
    for (let i = 1; i <= NTFY_TRIES && budget.canAfford(1); i += 1) {
      notifyTries = i;
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
      notified = await notify(pool.messages.skip(reasonClass(e)));
    }
    await kv.put("skips", JSON.stringify({ count, notified }));
  };

  let token = null;
  let cached = false;
  const mint = async () => {
    token = await gh.appToken(creds, fetchFn, now);
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
    prev.lastVar === pool.fallback ||
    prev.lastVar === null ||
    (prev.misses ?? 0) >= 1;
  const scanReserve =
    RESERVE_REQUIRED +
    (skips ? 2 : 0) +
    (sweepLikely ? OPTIONAL_SHARE : 0) +
    (pool.rerunLost ? LOST_SHARE : 0);
  let observed;
  let scan;
  let repoOldest;
  try {
    token = await kv.get("token");
    cached = Boolean(token);
    if (!token) await mint();
    const runners = await withToken((t) => gh.getRunners(t, fetchFn, pool));
    const varValue = await withToken((t) => gh.getVar(t, fetchFn, pool));
    const canFetch = (n) => budget.canAfford(n + scanReserve);
    const cursor = prev.cursor ?? 0;
    scan = await withToken((t) =>
      gh.scanQueue(t, fetchFn, { cursor, canFetch }, pool),
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

  const decision = decide(prev, observed, {
    selfHosted: pool.label,
    fallback: pool.fallback,
  });
  if (decision.setVar) {
    try {
      await withToken((t) => gh.setVar(t, decision.setVar, fetchFn, pool));
    } catch (e) {
      // State is not saved, so the next tick sees the same variable and decides again.
      await skipTick("tick skipped: var write failed", e);
      return;
    }
  }
  // After a down switch, in_progress mimolette jobs stay in the sweep until the rotation covered every repo.
  const fallback = decision.next.lastVar === pool.fallback;
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
    await notify(pool.messages[decision.notify](decision.next.lastVar));
  }
  if (skips) {
    if (skips.notified) await notify(pool.messages.ok);
    await kv.delete("skips");
  }
  if (drill !== null) {
    const ok = await notify(pool.messages.drill);
    await kv.put(
      "drill-result",
      JSON.stringify({
        at: new Date(now).toISOString(),
        ok,
        tries: notifyTries,
      }),
    );
    await kv.delete("drill");
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
  if (decision.rerunStuck || decision.next.lastVar === pool.fallback) {
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
      if (gh.mimoletteJobs(jobs, statuses, pool).length === 0) continue;
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

  // Lost runners, after the cancels so the sweep keeps its budget. NOS has no rerunLost, so its tick ends above.
  if (!pool.rerunLost || scan.all.length === 0) return;
  if (stopped || !budget.canAfford(LOST_SHARE)) return;
  const loaded = parseOr(await kv.get("lostChecked"), {}, "lostChecked");
  const { [CURSOR_KEY]: savedCursor, ...entries } = loaded ?? {};
  const lostChecked = pruneChecked(entries, now);
  let dirty = Object.keys(lostChecked).length !== Object.keys(entries).length;
  const sinceIso = new Date(now - LOST_WINDOW_MS).toISOString();
  // Runs the pending list re-runs (a down-sweep run can fail first) are left to it, so no run gets two re-runs.
  const pendingKeys = new Set([...pending, ...toWrite].map(runKey));
  // Own cursor: the next tick starts after the last repo listed. Mod n, so a changed repo count is safe.
  const n = scan.all.length;
  const prevCursor = Number.isInteger(savedCursor) ? savedCursor : 0;
  const start = ((prevCursor % n) + n) % n;
  let cursor = start;
  const save = () =>
    kv.put(
      "lostChecked",
      JSON.stringify({ ...lostChecked, [CURSOR_KEY]: cursor }),
    );
  let out = false;
  for (let i = 0; i < n && !out; i += 1) {
    const repo = scan.all[(start + i) % n];
    const list = await optional(
      (t) => gh.listFailedRuns(t, repo, sinceIso, fetchFn),
      PROBE_COST,
    );
    if (list.skipped) break;
    // Listed (or failed): the next tick starts after this repo, even if its probes are cut short.
    cursor = (start + i + 1) % n;
    if (!list.ok) continue;
    for (const run of list.value) {
      const k = `${repo}#${run.id}`;
      if (k in lostChecked || pendingKeys.has(k) || !lostCandidate(run))
        continue;
      const jobs = await optional(
        (t) => gh.getJobs(t, repo, run.id, fetchFn),
        PROBE_COST - 1,
      );
      if (jobs.skipped) {
        out = true;
        break;
      }
      // A failed jobs GET is not marked, so a later tick probes the run again.
      if (!jobs.ok) continue;
      lostChecked[k] = now;
      dirty = true;
      if (!lostRunner(run, jobs.value, pool)) continue;
      // Marked before the POST: a crash after it can never re-run the run twice.
      await save();
      dirty = false;
      const rr = await optional(
        (t) => gh.rerunFailed(t, repo, run.id, fetchFn),
        RESERVE_FINAL,
      );
      // No alert (plan decision 9): re-runs after a restart are routine.
      log(
        rr.ok ? `lost runner re-run: ${k}` : `lost runner re-run failed: ${k}`,
      );
    }
  }
  if ((dirty || cursor !== prevCursor) && budget.canAfford(1)) await save();
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
  // Each cron trigger is one pool, so each pool gets its own invocation and subrequest budget.
  async scheduled(event, env) {
    const pool = poolForCron(event?.cron);
    if (!pool) {
      log(`unknown cron: ${event.cron}`);
      return;
    }
    await runTick(env, {
      fetch: (url, init) => fetch(url, init),
      now: event?.scheduledTime ?? Date.now(),
      pool,
    });
  },
};
