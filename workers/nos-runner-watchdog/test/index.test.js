import { test } from "node:test";
import assert from "node:assert/strict";
import {
  fakeFetch,
  fakeKV,
  pkcs8Pem,
  job,
  minutesAgo,
  GH,
  ORG,
  NOW,
} from "./fakes.js";
import {
  TOPIC,
  NTFY,
  VAR,
  RUNNERS,
  REPOS,
  repoUrl,
  full,
  world,
  setup,
  st,
  writes,
  stateOf,
  pendingOf,
  subrequests,
} from "./world.js";
import worker, { CAP } from "../src/index.js";

test("healthy_tick_makes_no_writes", async () => {
  const s = setup(world(), { state: st() });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.deepEqual(writes(s.f), []);
  assert.deepEqual(
    s.store.puts.map((p) => p.key),
    ["state"],
  );
  assert.equal(stateOf(s.store).lastVar, "mimolette");
});

test("down_tick_sets_var_cancels_and_alerts_once", async () => {
  const routes = world({
    runners: [],
    repos: {
      a: [
        { id: 11, age: 5 },
        { id: 12, age: 3 },
      ],
      b: [{ id: 21, age: 1, jobs: [job({ labels: ["ubuntu-latest"] })] }],
    },
    inProgress: { a: [{ id: 13, age: 8 }], b: [] },
  });
  const s = setup(routes, { state: st({ misses: 1 }) });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const patch = s.f.calls.find((c) => c.key === `PATCH ${VAR}`);
  assert.deepEqual(JSON.parse(patch.init.body), {
    name: "NOS_RUNNER",
    value: "ubuntu-latest",
    visibility: "private",
  });
  const cancels = s.f.calls
    .filter((c) => c.key.endsWith("/cancel"))
    .map((c) => c.url);
  assert.deepEqual(
    cancels.sort(),
    [11, 12, 13].map((id) => `${repoUrl("a")}/${id}/cancel`),
  );
  const pend = pendingOf(s.store).sort((x, y) => x.runId - y.runId);
  assert.deepEqual(
    pend,
    [11, 12, 13].map((runId) => ({
      repo: full("a"),
      runId,
      down: true,
      attempts: 0,
    })),
  );
  const alerts = s.f.calls.filter((c) => c.key === NTFY);
  assert.equal(alerts.length, 1);
  assert.match(alerts[0].init.body, /down/i);
  assert.equal(stateOf(s.store).lastVar, "ubuntu-latest");

  // Next tick, still down: no second alert and no second var write.
  routes[`GET ${VAR}`] = { json: { value: "ubuntu-latest" } };
  for (const id of [11, 12, 13])
    routes[`GET ${repoUrl("a")}/${id}`] = {
      json: { id, status: "in_progress" },
    };
  s.f.calls.length = 0;
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(s.f.calls.filter((c) => c.key === NTFY).length, 0);
  assert.equal(s.f.calls.filter((c) => c.key === `PATCH ${VAR}`).length, 0);
});

test("next_tick_reruns_completed_pending", async () => {
  const run = (id) => `${repoUrl("a")}/${id}`;
  const routes = world({
    varValue: "ubuntu-latest",
    extra: {
      [`GET ${run(1)}`]: {
        json: { id: 1, status: "completed", conclusion: "cancelled" },
      },
      [`GET ${run(2)}`]: { json: { id: 2, status: "in_progress" } },
      [`POST ${run(1)}/rerun-failed-jobs`]: { status: 201 },
    },
  });
  const pending = [
    { repo: full("a"), runId: 1 },
    { repo: full("a"), runId: 2 },
  ];
  const s = setup(routes, {
    state: st({ lastVar: "ubuntu-latest" }),
    pendingReruns: JSON.stringify(pending),
  });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(
    s.f.calls.filter((c) => c.key === `POST ${run(1)}/rerun-failed-jobs`)
      .length,
    1,
  );
  assert.deepEqual(pendingOf(s.store), [{ repo: full("a"), runId: 2 }]);
});

test("rate_limited_rerun_keeps_pending", async () => {
  const run = (id) => `${repoUrl("a")}/${id}`;
  const routes = world({
    varValue: "ubuntu-latest",
    extra: {
      [`GET ${run(1)}`]: {
        json: { id: 1, status: "completed", conclusion: "cancelled" },
      },
      [`POST ${run(1)}/rerun-failed-jobs`]: { status: 403 },
    },
  });
  const pending = [
    { repo: full("a"), runId: 1 },
    { repo: full("a"), runId: 2 },
  ];
  const raw = JSON.stringify(pending);
  const s = setup(routes, {
    state: st({ lastVar: "ubuntu-latest" }),
    pendingReruns: raw,
  });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  // 403 stops optional work: run 2 is not read, stays pending and moves to the front.
  assert.equal(
    s.f.calls.some((c) => c.key === `GET ${run(2)}`),
    false,
  );
  assert.deepEqual(pendingOf(s.store), [
    { repo: full("a"), runId: 2 },
    { repo: full("a"), runId: 1, attempts: 1 },
  ]);
});

test("token_401_in_optional_work_keeps_pending", async () => {
  const { pem } = await pkcs8Pem();
  const run = (id) => `${repoUrl("a")}/${id}`;
  const routes = world({
    varValue: "ubuntu-latest",
    extra: {
      [`GET ${run(1)}`]: { status: 401 },
      [`POST ${GH}/app/installations/77/access_tokens`]: {
        status: 201,
        json: { token: "ghs_new" },
      },
    },
  });
  const raw = JSON.stringify([{ repo: full("a"), runId: 1 }]);
  const s = setup(
    routes,
    { state: st({ lastVar: "ubuntu-latest" }), pendingReruns: raw },
    { APP_KEY_PKCS8: pem },
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.deepEqual(pendingOf(s.store), [
    { repo: full("a"), runId: 1, attempts: 1 },
  ]);
  assert.ok(stateOf(s.store));
});

// Every decide input, failing, must leave KV and GitHub untouched.
for (const [name, status] of [
  ["api_error_skips_tick", 502],
  ["rate_limited_403_skips_tick", 403],
]) {
  test(name, async () => {
    const inputs = [
      RUNNERS,
      `GET ${VAR}`,
      REPOS,
      `GET ${repoUrl("a")}?status=queued&per_page=100&exclude_pull_requests=true`,
      `GET ${repoUrl("a")}?status=in_progress&per_page=100&exclude_pull_requests=true`,
      `GET ${repoUrl("a")}/11/jobs?per_page=100`,
    ];
    for (const key of inputs) {
      const routes = world({
        runners: [],
        repos: { a: [{ id: 11, age: 30 }] },
      });
      routes[key] = { status, json: { message: "nope" } };
      const pending = JSON.stringify([{ repo: full("a"), runId: 9 }]);
      const state = st({ misses: 1 });
      const s = setup(routes, { state, pendingReruns: pending });
      await s.tick();
      assert.deepEqual(s.f.unexpected, [], key);
      assert.deepEqual(writes(s.f), [], key);
      assert.equal(s.store.map.get("state"), state, key);
      assert.equal(s.store.map.get("pendingReruns"), pending, key);
      // Only the skips counter may change on a skipped tick.
      assert.deepEqual(
        s.store.puts.map((p) => p.key),
        ["skips"],
        key,
      );
    }
  });
}

const tenByFive = () => {
  const repos = {};
  for (let r = 0; r < 10; r += 1) {
    repos[`r${r}`] = Array.from({ length: 5 }, (_, i) => ({
      id: r * 10 + i,
      age: 30 - i,
    }));
  }
  return repos;
};

test("subrequests_per_tick_at_most_40", async () => {
  const s = setup(
    world({
      runners: [],
      repos: tenByFive(),
      inProgress: Object.fromEntries(
        Object.keys(tenByFive()).map((r) => [r, []]),
      ),
    }),
    {
      state: st({ misses: 1 }),
    },
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(subrequests(s) <= CAP, `subrequests ${subrequests(s)}`);
  assert.equal(CAP, 40);
  assert.equal(s.f.calls.filter((c) => c.key === `PATCH ${VAR}`).length, 1);
  assert.equal(s.f.calls.filter((c) => c.key === NTFY).length, 1);
  assert.equal(stateOf(s.store).lastVar, "ubuntu-latest");
});

test("budget_stops_optional_work_but_writes_state", async () => {
  const repos = tenByFive();
  const s = setup(world({ varValue: "ubuntu-latest", repos }), {
    state: st({ lastVar: "ubuntu-latest" }),
  });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(subrequests(s) <= CAP, `subrequests ${subrequests(s)}`);
  assert.equal(stateOf(s.store).lastVar, "ubuntu-latest");
  const first = pendingOf(s.store);
  assert.ok(first.length > 0 && first.length < 50, `pending ${first.length}`);
  // The next tick keeps the pending list and cancels more.
  const done = new Set(first.map((p) => p.runId));
  for (const p of first) {
    s.f.routes[`GET ${GH}/repos/${p.repo}/actions/runs/${p.runId}`] = {
      json: { status: "in_progress" },
    };
  }
  for (const [r, list] of Object.entries(repos)) {
    s.f.routes[
      `GET ${repoUrl(r)}?status=queued&per_page=100&exclude_pull_requests=true`
    ] = {
      json: {
        workflow_runs: list
          .filter((x) => !done.has(x.id))
          .map((x) => ({ id: x.id, created_at: minutesAgo(x.age) })),
      },
    };
  }
  s.f.calls.length = 0;
  s.store.ops.length = 0;
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(subrequests(s) <= CAP);
  const second = pendingOf(s.store);
  for (const p of first)
    assert.ok(
      second.some((q) => q.runId === p.runId),
      `kept ${p.runId}`,
    );
});

test("required_scan_truncates_to_keep_var_write_under_cap", async () => {
  const repos = {};
  for (let r = 0; r < 25; r += 1) repos[`r${r}`] = [{ id: r, age: 30 }];
  const inProgress = Object.fromEntries(Object.keys(repos).map((r) => [r, []]));
  const s = setup(world({ runners: [], repos, inProgress }), {
    state: st({ misses: 1 }),
  });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(subrequests(s) <= CAP, `subrequests ${subrequests(s)}`);
  assert.equal(s.f.calls.filter((c) => c.key === `PATCH ${VAR}`).length, 1);
  assert.equal(s.f.calls.filter((c) => c.key === NTFY).length, 1);
  assert.equal(stateOf(s.store).lastVar, "ubuntu-latest");
});

test("sweep_cancels_queued_mimolette_runs_while_ubuntu", async () => {
  const routes = world({
    varValue: "ubuntu-latest",
    repos: {
      a: [
        { id: 1, age: 9 },
        { id: 2, age: 4 },
        { id: 3, age: 2, jobs: [job({ labels: ["ubuntu-latest"] })] },
      ],
    },
  });
  const s = setup(routes, { state: st({ lastVar: "ubuntu-latest" }) });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const cancels = s.f.calls
    .filter((c) => c.key.endsWith("/cancel"))
    .map((c) => c.url)
    .sort();
  assert.deepEqual(cancels, [
    `${repoUrl("a")}/1/cancel`,
    `${repoUrl("a")}/2/cancel`,
  ]);
  assert.deepEqual(
    pendingOf(s.store)
      .map((p) => p.runId)
      .sort(),
    [1, 2],
  );
  assert.equal(s.f.calls.filter((c) => c.key === `PATCH ${VAR}`).length, 0);
});

test("held_notify_includes_value", async () => {
  const routes = world({
    varValue: "hold-for-maintenance",
    repos: { a: [{ id: 1, age: 50 }] },
  });
  const s = setup(routes, { state: st() });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const alerts = s.f.calls.filter((c) => c.key === NTFY);
  assert.equal(alerts.length, 1);
  assert.match(alerts[0].init.body, /hold-for-maintenance/);
  assert.equal(
    s.f.calls.filter(
      (c) => c.key.endsWith("/cancel") || c.key === `PATCH ${VAR}`,
    ).length,
    0,
  );
});

test("var_404_tick_sets_online", async () => {
  const routes = world({
    varValue: null,
    extra: {
      [`PATCH ${VAR}`]: { status: 404 },
      [`POST ${ORG}/actions/variables`]: { status: 201 },
    },
  });
  const s = setup(routes, { state: st({ lastVar: null, goods: 1 }) });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const post = s.f.calls.find((c) => c.key === `POST ${ORG}/actions/variables`);
  assert.equal(JSON.parse(post.init.body).value, "mimolette");
  assert.match(s.f.calls.find((c) => c.key === NTFY).init.body, /online/i);
});

test("var_write_failure_sends_no_alert_and_keeps_state", async () => {
  const routes = world({
    runners: [],
    extra: { [`PATCH ${VAR}`]: { status: 500 } },
  });
  const state = st({ misses: 1 });
  const s = setup(routes, { state });
  await s.tick();
  assert.equal(s.f.calls.filter((c) => c.key === NTFY).length, 0);
  assert.equal(s.store.map.get("state"), state);
});

test("cached_token_skips_signing", async () => {
  // APP_KEY_PKCS8 is not a key, so any signing attempt would throw.
  const s = setup(world(), { state: st() });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(
    s.f.calls.some((c) => c.url.includes("access_tokens")),
    false,
  );
  assert.equal(s.f.calls[0].init.headers.Authorization, "Bearer ghs_cached");
  assert.equal(
    s.store.puts.some((p) => p.key === "token"),
    false,
  );
});

test("missing_token_mints_and_caches", async () => {
  const { pem } = await pkcs8Pem();
  const routes = world({
    extra: {
      [`POST ${GH}/app/installations/77/access_tokens`]: {
        status: 201,
        json: { token: "ghs_new" },
      },
    },
  });
  const s = setup(routes, { state: st() }, { APP_KEY_PKCS8: pem });
  s.store.map.delete("token");
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const put = s.store.puts.find((p) => p.key === "token");
  assert.equal(put.value, "ghs_new");
  assert.deepEqual(put.opts, { expirationTtl: 3000 });
});

test("cached_token_401_remints_once", async () => {
  const { pem } = await pkcs8Pem();
  let mints = 0;
  const routes = world({
    extra: {
      [`POST ${GH}/app/installations/77/access_tokens`]: () => {
        mints += 1;
        return { status: 201, json: { token: "ghs_new" } };
      },
    },
  });
  const ok = routes[RUNNERS];
  routes[RUNNERS] = (init) =>
    init.headers.Authorization === "Bearer ghs_new" ? ok : { status: 401 };
  const s = setup(routes, { state: st() }, { APP_KEY_PKCS8: pem });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(mints, 1);
  assert.equal(s.store.map.get("token"), "ghs_new");
  assert.equal(s.f.calls.filter((c) => c.key === RUNNERS).length, 2);
  assert.ok(s.store.puts.some((p) => p.key === "state"));

  // A fresh token that also gets 401 skips the tick after one mint.
  routes[RUNNERS] = { status: 401 };
  mints = 0;
  const s2 = setup(routes, { state: st() }, { APP_KEY_PKCS8: pem });
  await s2.tick();
  assert.equal(mints, 1);
  assert.equal(
    s2.store.puts.some((p) => p.key === "state"),
    false,
  );
});

test("scheduled_entry_uses_global_fetch_and_never_logs_secrets", async () => {
  const f = fakeFetch(
    world({ runners: [], extra: { [`PATCH ${VAR}`]: { status: 500 } } }),
  );
  const store = fakeKV({ token: "ghs_cached", state: st({ misses: 1 }) });
  const env = {
    APP_ID: "1",
    INSTALLATION_ID: "77",
    APP_KEY_PKCS8: "not-a-key",
    NTFY_TOPIC: TOPIC,
    STATE: store,
  };
  const logged = [];
  const saved = {
    fetch: globalThis.fetch,
    log: console.log,
    error: console.error,
    warn: console.warn,
  };
  globalThis.fetch = f.fn;
  console.log =
    console.error =
    console.warn =
      (...a) => logged.push(a.join(" "));
  try {
    await worker.scheduled({ scheduledTime: NOW }, env, { waitUntil() {} });
  } finally {
    Object.assign(console, {
      log: saved.log,
      error: saved.error,
      warn: saved.warn,
    });
    globalThis.fetch = saved.fetch;
  }
  assert.ok(f.calls.length > 0);
  assert.ok(logged.length > 0);
  for (const line of logged) {
    assert.ok(!line.includes(TOPIC) && !line.includes("ghs_cached"), line);
  }
});
