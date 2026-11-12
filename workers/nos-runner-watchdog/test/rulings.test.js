import { test } from "node:test";
import assert from "node:assert/strict";
import { job, minutesAgo, runner } from "./fakes.js";
import {
  NTFY,
  VAR,
  repoUrl,
  full,
  world,
  setup,
  st,
  stateOf,
  pendingOf,
  idsOf,
  subrequests,
} from "./world.js";
import { MAX_JOB_PROBES } from "../src/github.js";

const downWorld = () =>
  world({
    runners: [],
    repos: { a: [{ id: 11, age: 30 }] },
    inProgress: { a: [{ id: 13, age: 40 }] },
  });

test("pending_written_before_cancel", async () => {
  const s = setup(downWorld(), { state: st({ misses: 1 }) });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const put = s.seq.indexOf("kv put pendingReruns");
  const cancels = s.seq.filter((k) => k.endsWith("/cancel"));
  assert.equal(cancels.length, 2);
  for (const c of cancels) assert.ok(put >= 0 && put < s.seq.indexOf(c), c);
  assert.equal(s.store.puts.filter((p) => p.key === "pendingReruns").length, 1);

  // If that write fails, nothing is cancelled.
  const s2 = setup(downWorld(), { state: st({ misses: 1 }) });
  const put2 = s2.store.put;
  s2.store.put = (k, v, o) => {
    if (k === "pendingReruns") return Promise.reject(new Error("kv down"));
    return put2(k, v, o);
  };
  await assert.rejects(s2.tick());
  assert.equal(
    s2.f.calls.some((c) => c.key.endsWith("/cancel")),
    false,
  );
});

test("state_put_before_ntfy", async () => {
  const s = setup(downWorld(), { state: st({ misses: 1 }) });
  await s.tick();
  const patch = s.seq.indexOf(`PATCH ${VAR}`);
  const state = s.seq.indexOf("kv put state");
  const ntfy = s.seq.indexOf(NTFY);
  assert.ok(patch >= 0 && patch < state && state < ntfy, s.seq.join("\n"));

  // A failed state put sends no alert, so the retry next tick alerts only once.
  const s2 = setup(downWorld(), { state: st({ misses: 1 }) });
  const put2 = s2.store.put;
  s2.store.put = (k, v, o) => {
    if (k === "state") return Promise.reject(new Error("kv down"));
    return put2(k, v, o);
  };
  await assert.rejects(s2.tick());
  assert.equal(
    s2.f.calls.some((c) => c.key === NTFY),
    false,
  );
});

test("rotation_covers_all_repos_over_ticks", async () => {
  const repos = {};
  for (let r = 0; r < 12; r += 1) {
    repos[`r${r}`] = [{ id: r + 1, age: r === 11 ? 50 : 1 }];
  }
  const s = setup(world({ repos }), { state: st() });
  const scanned = () =>
    s.seq
      .filter((k) => k.includes("?status=queued"))
      .map((k) => k.match(/nightowlstudiollc\/(r\d+)\//)[1]);
  await s.tick();
  const first = scanned();
  assert.ok(first.length < 12, `tick 1 scanned ${first.length}`);
  assert.ok(!first.includes("r11"));
  assert.equal(stateOf(s.store).misses, 0);
  assert.equal(stateOf(s.store).cursor, first.length);

  s.seq.length = 0;
  await s.tick();
  const second = scanned();
  assert.equal(second[0], `r${first.length}`);
  assert.deepEqual(
    [...new Set([...first, ...second])].sort(),
    Object.keys(repos).sort(),
  );
  // r11 was seen this tick; repos left out keep last tick's oldest time.
  const st2 = stateOf(s.store);
  assert.equal(st2.misses, 1);
  assert.deepEqual(
    Object.keys(st2.repoOldest).sort(),
    Object.keys(repos).map(full).sort(),
  );
  assert.ok(subrequests(s) > 0);
});

test("in_progress_run_with_queued_mimolette_job_counts", async () => {
  const routes = world({
    inProgress: {
      a: [
        {
          id: 5,
          age: 30,
          jobs: [
            job({ id: 1, status: "completed", labels: ["ubuntu-latest"] }),
            job({ id: 2, status: "queued", created_at: minutesAgo(30) }),
          ],
        },
      ],
    },
  });
  const s = setup(routes, { state: st({ misses: 1 }) });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(s.f.calls.filter((c) => c.key === `PATCH ${VAR}`).length, 1);
  assert.deepEqual(idsOf(s.store), [5]);
});

test("rerun_once_never_recancelled", async () => {
  const routes = world({
    varValue: "ubuntu-latest",
    repos: {
      a: [
        { id: 7, age: 30, attempt: 2 },
        { id: 8, age: 5 },
      ],
    },
  });
  const s = setup(routes, { state: st({ lastVar: "ubuntu-latest" }) });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const cancels = s.f.calls.filter((c) => c.key.endsWith("/cancel"));
  assert.deepEqual(
    cancels.map((c) => c.url),
    [`${repoUrl("a")}/8/cancel`],
  );
  assert.deepEqual(idsOf(s.store), [8]);
});

test("pending_dropped_after_6_failures", async () => {
  const routes = world({
    varValue: "ubuntu-latest",
    extra: {
      [`GET ${repoUrl("a")}/1`]: { status: 502 },
      [`GET ${repoUrl("a")}/2`]: { status: 502 },
    },
  });
  const pending = [
    { repo: full("a"), runId: 1, attempts: 5 },
    { repo: full("a"), runId: 2, attempts: 2 },
  ];
  const s = setup(routes, {
    state: st({ lastVar: "ubuntu-latest" }),
    pendingReruns: JSON.stringify(pending),
  });
  const logged = [];
  const saved = console.log;
  console.log = (...a) => logged.push(a.join(" "));
  try {
    await s.tick();
  } finally {
    console.log = saved;
  }
  assert.deepEqual(s.f.unexpected, []);
  assert.deepEqual(pendingOf(s.store), [
    { repo: full("a"), runId: 2, attempts: 3 },
  ]);
  assert.ok(logged.some((l) => l.includes(`${full("a")}#1`)));
});

// Fix round 2 (ruling 28): the reviewer's two repro sequences.
const olderInProgress = (olderJobs, runners) =>
  world({
    runners,
    repos: { k: [{ id: 2, age: 25 }] },
    inProgress: { k: [{ id: 1, age: 40, jobs: olderJobs }] },
  });

const ticksUntilPatch = async (s, max) => {
  for (let i = 1; i <= max; i += 1) {
    await s.tick();
    assert.deepEqual(s.f.unexpected, []);
    if (s.f.calls.some((c) => c.key === `PATCH ${VAR}`)) return i;
  }
  return null;
};

test("older_in_progress_run_does_not_hide_queued_mimolette", async () => {
  const macos = [job({ status: "in_progress", labels: ["macos-15"] })];
  const s = setup(
    olderInProgress(macos, [runner("a", false), runner("b", false)]),
    {
      state: st(),
    },
  );
  // Queued 25 min with idle runners: unhealthy twice, then the switch.
  assert.equal(await ticksUntilPatch(s, 3), 2);
});

test("hung_jobs_in_older_run_still_detected", async () => {
  const hung = [
    job({ id: 1, status: "in_progress", created_at: minutesAgo(40) }),
    job({ id: 2, status: "in_progress", created_at: minutesAgo(40) }),
  ];
  const s = setup(
    olderInProgress(hung, [runner("a", true), runner("b", true)]),
    {
      state: st(),
    },
  );
  // Tick 1 sets the busy names; ticks 2-4 repeat them (3 hung checks); tick 5 is the second miss.
  assert.equal(await ticksUntilPatch(s, 7), 5);
});

test("down_sweep_covers_all_repos_for_in_progress", async () => {
  const inProgress = {};
  for (let r = 0; r < 12; r += 1) {
    inProgress[`r${r}`] = [{ id: 100 + r, age: 30 }];
  }
  const routes = world({ runners: [], inProgress });
  const s = setup(routes, { state: st({ misses: 1 }) });
  const cancelled = new Set();
  for (let i = 0; i < 4; i += 1) {
    s.f.calls.length = 0;
    await s.tick();
    assert.deepEqual(s.f.unexpected, []);
    for (const c of s.f.calls.filter((x) => x.key.endsWith("/cancel"))) {
      const [, r, id] = c.url.match(/\/(r\d+)\/actions\/runs\/(\d+)\/cancel$/);
      assert.ok(!cancelled.has(id), `cancelled twice: ${id}`);
      cancelled.add(id);
      // The run is now cancelling: gone from the in_progress list, not yet completed.
      routes[
        `GET ${repoUrl(r)}?status=in_progress&per_page=100&exclude_pull_requests=true`
      ] = {
        json: { workflow_runs: [] },
      };
      routes[`GET ${repoUrl(r)}/${id}`] = { json: { status: "in_progress" } };
    }
    routes[`GET ${VAR}`] = { json: { value: "ubuntu-latest" } };
    if (stateOf(s.store).downSweepLeft === 0) break;
  }
  assert.equal(stateOf(s.store).downSweepLeft, 0);
  assert.equal(cancelled.size, 12);
});

test("only_cancelled_or_down_failures_rerun", async () => {
  const run = (id) => `${repoUrl("a")}/${id}`;
  const done = (id, conclusion, attempt = 1) => ({
    json: { id, status: "completed", conclusion, run_attempt: attempt },
  });
  const routes = world({
    varValue: "ubuntu-latest",
    extra: {
      [`GET ${run(1)}`]: done(1, "success"),
      [`GET ${run(2)}`]: done(2, "failure"),
      [`GET ${run(3)}`]: done(3, "failure"),
      [`GET ${run(4)}`]: done(4, "cancelled", 2),
      [`POST ${run(3)}/rerun-failed-jobs`]: { status: 201 },
    },
  });
  const pending = [1, 2, 3, 4].map((runId) => ({
    repo: full("a"),
    runId,
    ...(runId === 3 && { down: true }),
  }));
  const s = setup(routes, {
    state: st({ lastVar: "ubuntu-latest" }),
    pendingReruns: JSON.stringify(pending),
  });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const reruns = s.f.calls.filter((c) => c.key.endsWith("/rerun-failed-jobs"));
  assert.deepEqual(
    reruns.map((c) => c.url),
    [`${run(3)}/rerun-failed-jobs`],
  );
  assert.deepEqual(pendingOf(s.store), []);
});

test("corrupt_kv_values_fall_back", async () => {
  const s = setup(world(), { state: "{not json", pendingReruns: "[oops" });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(stateOf(s.store).lastVar, "mimolette");
});

// Ruling 30: a watchdog that skips every tick must not be silent.
const RUNNERS_KEY = (routes) =>
  Object.keys(routes).find((k) => k.includes("/actions/runners"));
const alerts = (s) =>
  s.f.calls.filter((c) => c.key === NTFY).map((c) => c.init.body);

test("three_skips_alert_once", async () => {
  const routes = world();
  routes[RUNNERS_KEY(routes)] = { status: 502 };
  const state = st();
  const s = setup(routes, { state });
  for (let i = 0; i < 5; i += 1) await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const sent = alerts(s);
  assert.equal(sent.length, 1);
  assert.match(sent[0], /^watchdog skipping: github 5xx \(runners\)$/);
  assert.ok(!sent[0].includes("ghs_") && !sent[0].includes("https://"));
  assert.deepEqual(JSON.parse(s.store.map.get("skips")), {
    count: 5,
    notified: true,
  });
  assert.equal(s.store.map.get("state"), state);
});

test("recovery_after_skips_alerts_ok_once", async () => {
  const routes = world();
  const key = RUNNERS_KEY(routes);
  const good = routes[key];
  routes[key] = { status: 500 };
  const s = setup(routes, { state: st() });
  for (let i = 0; i < 3; i += 1) await s.tick();
  routes[key] = good;
  s.f.calls.length = 0;
  await s.tick();
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.deepEqual(alerts(s), ["watchdog ok: ticks are running again."]);
  assert.equal(s.store.map.has("skips"), false);
});

test("short_skip_run_recovers_silently", async () => {
  const routes = world();
  const key = RUNNERS_KEY(routes);
  const good = routes[key];
  routes[key] = { status: 503 };
  const s = setup(routes, { state: st() });
  await s.tick();
  await s.tick();
  routes[key] = good;
  await s.tick();
  assert.deepEqual(alerts(s), []);
  assert.equal(s.store.map.has("skips"), false);
});

test("good_tick_no_skip_write", async () => {
  const s = setup(world(), { state: st() });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.deepEqual(
    s.store.puts.map((p) => p.key),
    ["state"],
  );
  assert.equal(
    s.store.ops.some((o) => o === "delete skips"),
    false,
  );
});

// Ruling 31: jobs are probed run by run, oldest first across both lists, up to MAX_JOB_PROBES per repo.
const newerInProgress = (runners) =>
  world({
    runners,
    inProgress: {
      k: [
        {
          id: 1,
          age: 40,
          jobs: [
            job({ id: 1, status: "in_progress", created_at: minutesAgo(40) }),
            job({ id: 2, status: "in_progress", created_at: minutesAgo(40) }),
          ],
        },
        {
          id: 2,
          age: 25,
          jobs: [
            job({ id: 3, status: "in_progress", labels: ["ubuntu-latest"] }),
            job({ id: 4, status: "queued", created_at: minutesAgo(25) }),
          ],
        },
      ],
    },
  });

test("newer_in_progress_run_with_queued_mimolette_is_seen", async () => {
  // Hung: both slots busy for run 1; run 2's queued mimolette job is the queued work.
  const hung = setup(newerInProgress([runner("a", true), runner("b", true)]), {
    state: st(),
  });
  assert.equal(await ticksUntilPatch(hung, 7), 5);

  // Idle: run 1 replaced by a hosted macOS job; both runners idle.
  const routes = newerInProgress([runner("a", false), runner("b", false)]);
  routes[`GET ${repoUrl("k")}/1/jobs?per_page=100`] = {
    json: { jobs: [job({ status: "in_progress", labels: ["macos-15"] })] },
  };
  const idleTick = setup(routes, { state: st() });
  assert.equal(await ticksUntilPatch(idleTick, 4), 2);
});

const jobFetches = (s, r) =>
  s.f.calls.filter(
    (c) => c.key.startsWith(`GET ${repoUrl(r)}/`) && c.key.includes("/jobs"),
  );

test("job_probe_stops_at_first_mimolette_run", async () => {
  const hosted = [job({ status: "in_progress", labels: ["ubuntu-latest"] })];
  const routes = world({
    repos: { k: [{ id: 3, age: 20 }] },
    inProgress: {
      k: [
        {
          id: 1,
          age: 40,
          jobs: [job({ status: "queued", created_at: minutesAgo(40) })],
        },
        { id: 2, age: 30, jobs: hosted },
      ],
    },
  });
  const s = setup(routes, { state: st() });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.deepEqual(
    jobFetches(s, "k").map((c) => c.url),
    [`${repoUrl("k")}/1/jobs?per_page=100`],
  );
  assert.deepEqual(stateOf(s.store).repoOldest, {
    [full("k")]: Date.parse(minutesAgo(40)),
  });
});

test("job_probes_capped_at_3_per_repo", async () => {
  const hosted = (status) => [job({ status, labels: ["ubuntu-latest"] })];
  const routes = world({
    repos: { k: [{ id: 3, age: 30, jobs: hosted("queued") }] },
    inProgress: {
      k: [
        { id: 1, age: 50, jobs: hosted("in_progress") },
        { id: 2, age: 40, jobs: hosted("in_progress") },
        // Accepted residual: a mimolette job behind 3 hosted runs stays hidden.
        { id: 4, age: 20 },
      ],
    },
  });
  const s = setup(routes, { state: st() });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(MAX_JOB_PROBES, 3);
  assert.deepEqual(
    jobFetches(s, "k").map((c) => c.url.match(/runs\/(\d+)\/jobs/)[1]),
    ["1", "2", "3"],
  );
  assert.deepEqual(stateOf(s.store).repoOldest, {});
});
