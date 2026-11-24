import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { NOW, fakeKV } from "./fakes.js";
import {
  worldFor,
  setupFor,
  st,
  keyOf,
  repoUrlFor,
  failedUrlFor,
  subrequests,
} from "./pool-world.js";
import { CAP } from "../src/index.js";
import { POOLS } from "../src/pools.js";
import { lostRunner } from "../src/lost.js";

const MAC = POOLS.swmMacos;
const NOS = POOLS.nos;
const HOUR = 3600000;

// Fixtures: three captured from the GitHub API (source field says which run), one hypothesis.
const load = (name) =>
  JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url)));
const fixture = {
  hypothesis: load("hypothesis-runner-lost.json"),
  forkGuard: load("fork-guard-denial.json"),
  realFailure: load("real-test-failure.json"),
  cancelled: load("user-cancelled.json"),
};
const clone = (x) => structuredClone(x);
// The hypothesis fixture with one field changed, so each test fails for its own clause only.
const mutate = (fn) => {
  const f = clone(fixture.hypothesis);
  fn(f);
  return f;
};
// A fixture moved into another repo of the world, under a new run id.
const asRun = (f, repo, id) => {
  const x = clone(f);
  x.run.id = id;
  x.run.repository.full_name = `smartwatermelon/${repo}`;
  if (f.run.head_repository.full_name === f.run.repository.full_name) {
    x.run.head_repository.full_name = `smartwatermelon/${repo}`;
  }
  return x;
};

const rerunKey = (repo, id) =>
  `POST ${repoUrlFor(MAC, repo)}/${id}/rerun-failed-jobs`;
const jobsKey = (repo, id) =>
  `GET ${repoUrlFor(MAC, repo)}/${id}/jobs?per_page=100`;
const reruns = (s) =>
  s.f.calls.filter((c) => c.key.endsWith("/rerun-failed-jobs"));
const healthyKv = (over = {}) => ({
  [keyOf(MAC, "token")]: "ghs_swm",
  [keyOf(MAC, "state")]: st(MAC),
  ...over,
});
// lostChecked entries without the repo cursor it also holds.
const checked = (s) => {
  const all = JSON.parse(s.store.map.get(keyOf(MAC, "lostChecked")) ?? "{}");
  delete all._cursor;
  return all;
};

async function tickWith(failed, kv = healthyKv(), now = NOW, store = null) {
  const s = setupFor(MAC, worldFor(MAC, { failed, now }), kv, {}, store);
  await s.tick(now);
  assert.deepEqual(s.f.unexpected, []);
  return s;
}

test("lost_runner_job_is_rerun", async () => {
  const h = fixture.hypothesis;
  assert.equal(lostRunner(h.run, h.jobs, MAC), true);
  const s = await tickWith({ dotfiles: [h] });
  assert.deepEqual(
    reruns(s).map((c) => c.key),
    [rerunKey("dotfiles", h.run.id)],
  );
  assert.equal(
    typeof checked(s)[`smartwatermelon/dotfiles#${h.run.id}`],
    "number",
  );
});

test("lost_fork_guard_denial_not_rerun", async () => {
  const f = fixture.forkGuard;
  assert.equal(lostRunner(f.run, f.jobs, MAC), false);
  // Derived, not captured: the same jobs on a same-repo run. The failed "Set up runner" step alone must refuse it.
  const sameRepo = clone(f);
  sameRepo.run.head_repository.full_name = sameRepo.run.repository.full_name;
  assert.equal(lostRunner(sameRepo.run, sameRepo.jobs, MAC), false);
  const s = await tickWith({ dotfiles: [f, asRun(sameRepo, "dotfiles", 7)] });
  assert.equal(reruns(s).length, 0);
});

test("lost_real_failure_not_rerun", async () => {
  const f = fixture.realFailure;
  assert.equal(lostRunner(f.run, f.jobs, MAC), false);
  // Derived, not captured: the same failed-step job relabelled to the pool label. The failed step alone must refuse it.
  const relabelled = clone(f);
  for (const j of relabelled.jobs) j.labels = [MAC.label];
  assert.equal(lostRunner(relabelled.run, relabelled.jobs, MAC), false);
  const s = await tickWith({
    "mac-server-setup": [f, asRun(relabelled, "mac-server-setup", 8)],
  });
  assert.equal(reruns(s).length, 0);
});

test("lost_cancelled_run_not_rerun", async () => {
  const f = fixture.cancelled;
  assert.equal(lostRunner(f.run, f.jobs, MAC), false);
  // Derived: a cancelled run is refused by the run conclusion, even with the hypothesis jobs.
  assert.equal(lostRunner(f.run, fixture.hypothesis.jobs, MAC), false);
  const s = await tickWith({ dotfiles: [f] });
  assert.equal(reruns(s).length, 0);
});

test("lost_fork_run_not_rerun", () => {
  const f = mutate((x) => {
    x.run.head_repository.full_name = "someone/dotfiles";
  });
  assert.equal(lostRunner(f.run, f.jobs, MAC), false);
  // A deleted fork head has no head_repository: refused.
  const gone = mutate((x) => {
    x.run.head_repository = null;
  });
  assert.equal(lostRunner(gone.run, gone.jobs, MAC), false);
});

test("lost_dependabot_run_not_rerun", () => {
  const f = mutate((x) => {
    x.run.actor.login = "dependabot[bot]";
  });
  assert.equal(lostRunner(f.run, f.jobs, MAC), false);
});

test("lost_attempt_2_not_rerun", async () => {
  const f = mutate((x) => {
    x.run.run_attempt = 2;
  });
  assert.equal(lostRunner(f.run, f.jobs, MAC), false);
  const s = await tickWith({ dotfiles: [f] });
  assert.equal(reruns(s).length, 0);
});

test("lost_other_label_not_rerun", () => {
  const f = mutate((x) => {
    x.jobs[0].labels = ["macos-latest"];
  });
  assert.equal(lostRunner(f.run, f.jobs, MAC), false);
  // The NOS label is another label too.
  const nos = mutate((x) => {
    x.jobs[0].labels = [NOS.label];
  });
  assert.equal(lostRunner(nos.run, nos.jobs, MAC), false);
});

test("lost_job_conclusion_must_be_failure", () => {
  for (const c of ["success", "cancelled", "skipped", null]) {
    const f = mutate((x) => {
      x.jobs[0].conclusion = c;
    });
    assert.equal(lostRunner(f.run, f.jobs, MAC), false, String(c));
  }
  const run = mutate((x) => {
    x.run.conclusion = "success";
  });
  assert.equal(lostRunner(run.run, run.jobs, MAC), false);
  assert.equal(lostRunner(fixture.hypothesis.run, [], MAC), false);
});

test("lost_nos_pool_never_scans", async () => {
  const routes = worldFor(NOS, { repos: { a: [] } });
  const s = setupFor(NOS, routes, { token: "ghs_nos", state: st(NOS) });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(s.f.calls.length > 0);
  for (const c of s.f.calls) {
    assert.ok(!c.url.includes("status=failure"), c.key);
    assert.ok(!c.url.includes("rerun-failed-jobs"), c.key);
  }
  for (const op of s.store.ops) assert.ok(!op.includes("lostChecked"), op);
});

test("lost_checked_written_before_rerun", async () => {
  const h = fixture.hypothesis;
  const s = setupFor(
    MAC,
    worldFor(MAC, { failed: { dotfiles: [h] } }),
    healthyKv(),
  );
  const seq = [];
  const put = s.store.put.bind(s.store);
  s.store.put = (k, v, o) => {
    seq.push(`kv put ${k}`);
    return put(k, v, o);
  };
  const fetchFn = s.f.fn;
  const { runTick } = await import("../src/index.js");
  await runTick(s.env, {
    fetch: (url, init = {}) => {
      seq.push(`${(init.method || "GET").toUpperCase()} ${url}`);
      return fetchFn(url, init);
    },
    now: NOW,
    pool: MAC,
  });
  assert.deepEqual(s.f.unexpected, []);
  const putAt = seq.indexOf("kv put swm-macos:lostChecked");
  const rerunAt = seq.indexOf(rerunKey("dotfiles", h.run.id));
  assert.ok(putAt >= 0, "lostChecked put");
  assert.ok(rerunAt >= 0, "rerun POST");
  assert.ok(putAt < rerunAt, seq.join("\n"));
  // The put before the POST already holds the run.
  const before = s.store.puts.find((p) => p.key === "swm-macos:lostChecked");
  assert.ok(`smartwatermelon/dotfiles#${h.run.id}` in JSON.parse(before.value));
});

test("lost_run_probed_once", async () => {
  const h = fixture.hypothesis;
  const neg = asRun(fixture.realFailure, "dotfiles", 9);
  const failed = { dotfiles: [h, neg] };
  const first = await tickWith(failed);
  const second = await tickWith(
    failed,
    undefined,
    NOW + 10 * 60000,
    first.store,
  );
  // Second tick: a fresh world at the later time, same store.
  const probes = [...first.f.calls, ...second.f.calls].map((c) => c.key);
  assert.equal(
    probes.filter((k) => k === jobsKey("dotfiles", h.run.id)).length,
    1,
  );
  assert.equal(probes.filter((k) => k === jobsKey("dotfiles", 9)).length, 1);
  assert.equal(
    probes.filter((k) => k === rerunKey("dotfiles", h.run.id)).length,
    1,
  );
});

test("lost_checked_pruned_after_6h", async () => {
  const kv = healthyKv({
    [keyOf(MAC, "lostChecked")]: JSON.stringify({
      "smartwatermelon/old#1": NOW - 7 * HOUR,
      "smartwatermelon/edge#2": NOW - 6 * HOUR - 1,
      "smartwatermelon/recent#3": NOW - 1 * HOUR,
    }),
  });
  const s = await tickWith(
    { dotfiles: [asRun(fixture.realFailure, "dotfiles", 4)] },
    kv,
  );
  assert.deepEqual(Object.keys(checked(s)).sort(), [
    "smartwatermelon/dotfiles#4",
    "smartwatermelon/recent#3",
  ]);
});

// 25 repos with 5 failed runs each. Every run is lost-shaped, so each probe also wants a put and a re-run.
const manyFailed = () => {
  const out = {};
  for (let r = 0; r < 25; r += 1) {
    out[`r${r}`] = Array.from({ length: 5 }, (_, i) =>
      asRun(fixture.hypothesis, `r${r}`, 1000 + r * 10 + i),
    );
  }
  return out;
};

test("lost_budget_never_breaks_cap", async () => {
  // Healthy pool, and a down tick (zero runners after one miss) that also sweeps.
  for (const kv of [
    healthyKv(),
    healthyKv({ [keyOf(MAC, "state")]: st(MAC, { misses: 1 }) }),
  ]) {
    const down = kv[keyOf(MAC, "state")].includes('"misses":1');
    const s = setupFor(
      MAC,
      worldFor(MAC, {
        failed: manyFailed(),
        ...(down && {
          runners: [],
          repos: { r0: [{ id: 1, age: 30 }], r1: [{ id: 2, age: 30 }] },
        }),
      }),
      kv,
    );
    await s.tick();
    assert.deepEqual(s.f.unexpected, []);
    assert.ok(subrequests(s) <= CAP, `subrequests ${subrequests(s)}`);
  }
});

test("lost_idle_tick_reaches_rerun", async () => {
  // The scan must leave room: with 25 repos an idle healthy tick still re-runs at least one lost run.
  const s = await tickWith(manyFailed());
  assert.ok(reruns(s).length >= 1, `subrequests ${subrequests(s)}`);
  assert.ok(subrequests(s) <= CAP, `subrequests ${subrequests(s)}`);
  // Every re-run run is in lostChecked.
  for (const c of reruns(s)) {
    const id = c.url.split("/").at(-2);
    const repo = c.url.split("/repos/")[1].split("/actions")[0];
    assert.equal(typeof checked(s)[`${repo}#${id}`], "number");
  }
});

test("lost_failed_url_shape", async () => {
  // The list call asks GitHub for failed runs of the last 6 hours only.
  const s = await tickWith({ dotfiles: [] });
  const call = s.f.calls.find((c) => c.url.includes("status=failure"));
  assert.ok(call, "failed-runs list");
  assert.equal(call.key, failedUrlFor(MAC, "dotfiles"));
  assert.match(call.url, /created=>=2026-11-10T06:00:00Z/);
});

test("lost_pending_run_left_to_pending", async () => {
  // A down-sweep run that failed first is re-run by the pending list; the lost phase must not re-run it again.
  const h = fixture.hypothesis;
  const routes = worldFor(MAC, {
    varValue: "macos-latest",
    failed: { dotfiles: [h] },
    extra: {
      [`GET ${repoUrlFor(MAC, "dotfiles")}/${h.run.id}`]: {
        json: { status: "completed", conclusion: "failure", run_attempt: 1 },
      },
    },
  });
  const pending = [
    {
      repo: "smartwatermelon/dotfiles",
      runId: h.run.id,
      down: true,
      attempts: 0,
    },
  ];
  const s = setupFor(
    MAC,
    routes,
    healthyKv({
      [keyOf(MAC, "state")]: st(MAC, { lastVar: "macos-latest" }),
      [keyOf(MAC, "pendingReruns")]: JSON.stringify(pending),
    }),
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.deepEqual(
    reruns(s).map((c) => c.key),
    [rerunKey("dotfiles", h.run.id)],
  );
  assert.equal(
    s.f.calls.filter((c) => c.key === jobsKey("dotfiles", h.run.id)).length,
    0,
  );
});

test("lost_any_repo_rerun_within_rotation", async () => {
  // 34 repos, as smartwatermelon has. A lost run in any repo is re-run within ceil(34 / 4) = 9 ticks (90 min).
  const n = 34;
  const names = Array.from({ length: n }, (_, r) => `r${r}`);
  for (let j = 0; j < n; j += 1) {
    const run = asRun(fixture.hypothesis, `r${j}`, 5000 + j);
    const failed = Object.fromEntries(names.map((r) => [r, []]));
    failed[`r${j}`] = [run];
    const store = fakeKV(healthyKv());
    let ticks = 0;
    let done = false;
    while (!done && ticks < 40) {
      const now = NOW + ticks * 10 * 60000;
      const s = setupFor(MAC, worldFor(MAC, { failed, now }), {}, {}, store);
      await s.tick(now);
      assert.deepEqual(s.f.unexpected, []);
      ticks += 1;
      done = reruns(s).length > 0;
    }
    assert.ok(done && ticks <= 9, `repo r${j}: ${ticks} ticks`);
  }
});

test("lost_cursor_reaches_every_repo_on_busy_ticks", async () => {
  // 34 always-busy repos (20 new runs to probe): 1 list a tick. Every repo, odd ones too, is listed in 34 ticks.
  const n = 34;
  const names = Array.from({ length: n }, (_, r) => `r${r}`);
  const busy = (t) =>
    Object.fromEntries(
      names.map((r, i) => [
        r,
        Array.from({ length: 20 }, (_, k) =>
          asRun(fixture.realFailure, r, 1e6 + t * 1e4 + i * 100 + k),
        ),
      ]),
    );
  const store = fakeKV(healthyKv());
  const listed = new Set();
  const perTick = new Set();
  for (let t = 0; t < n; t += 1) {
    const now = NOW + t * 10 * 60000;
    const s = setupFor(
      MAC,
      worldFor(MAC, { failed: busy(t), now }),
      {},
      {},
      store,
    );
    const opsBefore = store.ops.length;
    await s.tick(now);
    assert.deepEqual(s.f.unexpected, []);
    const used = s.f.calls.length + store.ops.length - opsBefore;
    assert.ok(used <= CAP, `subrequests ${used}`);
    const lists = s.f.calls
      .filter((c) => c.url.includes("status=failure"))
      .map((c) => c.url.split("/repos/smartwatermelon/")[1].split("/")[0]);
    perTick.add(lists.length);
    for (const r of lists) listed.add(r);
  }
  assert.ok(Math.max(...perTick) <= 2, `lists a tick: ${[...perTick]}`);
  assert.deepEqual(
    names.filter((r) => !listed.has(r)),
    [],
  );
});

test("lost_cursor_past_repo_count_is_safe", async () => {
  // The installation lost repos since the cursor was saved: start again inside the list.
  const kv = healthyKv({
    [keyOf(MAC, "lostChecked")]: JSON.stringify({ _cursor: 99 }),
  });
  const s = await tickWith({ dotfiles: [fixture.hypothesis] }, kv);
  assert.equal(reruns(s).length, 1);
  const saved = JSON.parse(s.store.map.get(keyOf(MAC, "lostChecked")));
  assert.equal(saved._cursor, 0);
});
