import { test } from "node:test";
import assert from "node:assert/strict";
import { fakeFetch, fakeKV, pkcs8Pem, GH, NOW } from "./fakes.js";
import {
  TOPIC,
  NTFY,
  REPOS,
  varUrl,
  orgUrl,
  repoUrlFor,
  fullFor,
  jobFor,
  worldFor,
  bothApps,
  setupFor,
  st,
  keyOf,
  stateFor,
  pendingFor,
  subrequests,
} from "./pool-world.js";
import worker, { CAP } from "../src/index.js";
import { POOLS } from "../src/pools.js";

const MAC = POOLS.swmMacos;
const NOS = POOLS.nos;
const opKey = (op) => op.slice(op.indexOf(" ") + 1);

// Runs the scheduled entry with global fetch and console swapped; returns the log lines.
async function runScheduled(event, env, fetchFn) {
  const logged = [];
  const saved = {
    fetch: globalThis.fetch,
    log: console.log,
    error: console.error,
    warn: console.warn,
  };
  globalThis.fetch = fetchFn;
  console.log =
    console.error =
    console.warn =
      (...a) => logged.push(a.join(" "));
  try {
    await worker.scheduled(event, env, { waitUntil() {} });
  } finally {
    Object.assign(console, {
      log: saved.log,
      error: saved.error,
      warn: saved.warn,
    });
    globalThis.fetch = saved.fetch;
  }
  return logged;
}

test("pool_nos_cron_uses_unprefixed_keys", async () => {
  const f = fakeFetch(worldFor(NOS));
  const store = fakeKV({ token: "ghs_nos", state: st(NOS) });
  const env = { ...bothApps(), STATE: store };
  await runScheduled({ cron: "*/10 * * * *", scheduledTime: NOW }, env, f.fn);
  assert.deepEqual(f.unexpected, []);
  assert.ok(store.ops.length > 0);
  const allowed = new Set([
    "state",
    "token",
    "pendingReruns",
    "skips",
    "drill",
  ]);
  for (const op of store.ops) assert.ok(allowed.has(opKey(op)), op);
  assert.ok(f.calls.every((c) => !c.url.includes("smartwatermelon")));
});

test("pool_macos_keys_all_prefixed", async () => {
  const s = setupFor(MAC, worldFor(MAC), {
    [keyOf(MAC, "token")]: "ghs_swm",
    [keyOf(MAC, "state")]: st(MAC),
  });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(s.store.ops.length > 0);
  for (const op of s.store.ops) {
    assert.ok(opKey(op).startsWith("swm-macos:"), op);
  }
});

test("pool_macos_never_calls_nos_org", async () => {
  const s = setupFor(
    MAC,
    worldFor(MAC, { runners: [], repos: { a: [{ id: 1, age: 30 }] } }),
    {
      [keyOf(MAC, "token")]: "ghs_swm",
      [keyOf(MAC, "state")]: st(MAC, { misses: 1 }),
    },
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(s.f.calls.length > 0);
  for (const c of s.f.calls)
    assert.ok(!c.url.includes("nightowlstudiollc"), c.url);
});

const claimsOf = (call) =>
  JSON.parse(
    Buffer.from(
      call.init.headers.Authorization.split(" ")[1].split(".")[1],
      "base64url",
    ).toString(),
  );

test("pool_tokens_not_shared", async () => {
  const nosPem = (await pkcs8Pem()).pem;
  const swmPem = (await pkcs8Pem()).pem;
  const store = fakeKV({});
  const envOver = { APP_KEY_PKCS8: nosPem, SWM_APP_KEY_PKCS8: swmPem };
  const mint = (inst) => `POST ${GH}/app/installations/${inst}/access_tokens`;
  const nos = setupFor(
    NOS,
    worldFor(NOS, {
      extra: { [mint(77)]: { status: 201, json: { token: "ghs_nos" } } },
    }),
    {},
    envOver,
    store,
  );
  const mac = setupFor(
    MAC,
    worldFor(MAC, {
      extra: { [mint(88)]: { status: 201, json: { token: "ghs_swm" } } },
    }),
    {},
    envOver,
    store,
  );
  await nos.tick();
  await mac.tick();
  assert.deepEqual(nos.f.unexpected, []);
  assert.deepEqual(mac.f.unexpected, []);
  assert.equal(store.map.get("token"), "ghs_nos");
  assert.equal(store.map.get("swm-macos:token"), "ghs_swm");
  // Each pool signs its JWT as its own App.
  assert.equal(claimsOf(nos.f.calls.find((c) => c.key === mint(77))).iss, "1");
  assert.equal(claimsOf(mac.f.calls.find((c) => c.key === mint(88))).iss, "2");
  const gh = (s) =>
    s.f.calls.filter(
      (c) => c.url.startsWith(GH) && !c.url.includes("access_tokens"),
    );
  assert.ok(gh(mac).length > 0 && gh(nos).length > 0);
  for (const c of gh(mac)) {
    assert.equal(c.init.headers.Authorization, "Bearer ghs_swm", c.key);
  }
  for (const c of gh(nos)) {
    assert.equal(c.init.headers.Authorization, "Bearer ghs_nos", c.key);
  }

  // A second macOS tick uses its own cached token, not the NOS one.
  const again = setupFor(MAC, worldFor(MAC), {}, envOver, store);
  await again.tick();
  for (const c of gh(again)) {
    assert.equal(c.init.headers.Authorization, "Bearer ghs_swm", c.key);
  }
});

test("pool_macos_unconfigured_does_nothing", async () => {
  const s = setupFor(MAC, worldFor(MAC, { runners: [] }), {
    [keyOf(MAC, "token")]: "ghs_swm",
    [keyOf(MAC, "state")]: st(MAC, { misses: 1 }),
  });
  delete s.env.SWM_APP_KEY_PKCS8;
  const logged = [];
  const saved = console.log;
  console.log = (...a) => logged.push(a.join(" "));
  try {
    await s.tick();
  } finally {
    console.log = saved;
  }
  assert.equal(s.f.calls.length, 0);
  assert.equal(s.store.ops.length, 0);
  assert.equal(s.store.map.has(keyOf(MAC, "skips")), false);
  assert.equal(logged.length, 1);
});

test("pool_macos_down_switches_and_alerts", async () => {
  const s = setupFor(
    MAC,
    worldFor(MAC, {
      runners: [],
      repos: {
        a: [
          { id: 1, age: 30 },
          { id: 2, age: 5 },
        ],
      },
    }),
    {
      [keyOf(MAC, "token")]: "ghs_swm",
      [keyOf(MAC, "state")]: st(MAC, { misses: 1 }),
    },
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const patch = s.f.calls.filter(
    (c) =>
      c.key ===
      `PATCH ${GH}/orgs/smartwatermelon/actions/variables/SWM_MACOS_RUNNER`,
  );
  assert.equal(patch.length, 1);
  assert.equal(JSON.parse(patch[0].init.body).value, "macos-latest");
  const alerts = s.f.calls.filter((c) => c.key === NTFY);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].init.body, MAC.messages.down());
  const cancels = s.f.calls
    .filter((c) => c.key.endsWith("/cancel"))
    .map((c) => c.url)
    .sort();
  assert.deepEqual(cancels, [
    `${repoUrlFor(MAC, "a")}/1/cancel`,
    `${repoUrlFor(MAC, "a")}/2/cancel`,
  ]);
  assert.deepEqual(
    pendingFor(MAC, s.store)
      .map((p) => p.runId)
      .sort(),
    [1, 2],
  );
  assert.equal(pendingFor(MAC, s.store)[0].repo, fullFor(MAC, "a"));
  assert.equal(stateFor(MAC, s.store).lastVar, "macos-latest");
  assert.equal(s.store.map.has("pendingReruns"), false);
  assert.equal(s.store.map.has("state"), false);
});

test("pool_macos_set_var_visibility_all", async () => {
  const s = setupFor(
    MAC,
    worldFor(MAC, {
      varValue: "macos-latest",
      extra: {
        [`PATCH ${varUrl(MAC)}`]: { status: 404 },
        [`POST ${orgUrl(MAC)}/actions/variables`]: { status: 201 },
      },
    }),
    {
      [keyOf(MAC, "token")]: "ghs_swm",
      [keyOf(MAC, "state")]: st(MAC, { lastVar: "macos-latest", goods: 1 }),
    },
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const post = s.f.calls.find(
    (c) => c.key === `POST ${orgUrl(MAC)}/actions/variables`,
  );
  assert.deepEqual(JSON.parse(post.init.body), {
    name: "SWM_MACOS_RUNNER",
    value: "mimolette-macos",
    visibility: "all",
  });
  const alert = s.f.calls.find((c) => c.key === NTFY);
  assert.equal(alert.init.body, MAC.messages.recovered());
});

test("pool_macos_ignores_mimolette_jobs", async () => {
  const nosJob = (status) =>
    jobFor(NOS, {
      status,
      created_at: new Date(NOW - 50 * 60000).toISOString(),
    });
  // Healthy pool, idle runners: a NOS-label job 50 minutes old must not count as queued.
  const healthy = setupFor(
    MAC,
    worldFor(MAC, {
      repos: { a: [{ id: 1, age: 50, jobs: [nosJob("queued")] }] },
    }),
    {
      [keyOf(MAC, "token")]: "ghs_swm",
      [keyOf(MAC, "state")]: st(MAC),
    },
  );
  await healthy.tick();
  assert.deepEqual(healthy.f.unexpected, []);
  assert.equal(stateFor(MAC, healthy.store).misses, 0);
  assert.deepEqual(stateFor(MAC, healthy.store).repoOldest, {});

  // On the fallback the sweep runs, and still leaves the NOS-label run alone.
  const sweep = setupFor(
    MAC,
    worldFor(MAC, {
      varValue: "macos-latest",
      repos: { a: [{ id: 1, age: 50, jobs: [nosJob("queued")] }] },
    }),
    {
      [keyOf(MAC, "token")]: "ghs_swm",
      [keyOf(MAC, "state")]: st(MAC, { lastVar: "macos-latest" }),
    },
  );
  await sweep.tick();
  assert.deepEqual(sweep.f.unexpected, []);
  assert.equal(
    sweep.f.calls.filter((c) => c.key.endsWith("/cancel")).length,
    0,
  );
  assert.deepEqual(pendingFor(MAC, sweep.store), []);
});

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

test("pool_macos_subrequests_at_most_40", async () => {
  const s = setupFor(
    MAC,
    worldFor(MAC, {
      runners: [],
      repos: tenByFive(),
      inProgress: Object.fromEntries(
        Object.keys(tenByFive()).map((r) => [r, []]),
      ),
    }),
    {
      [keyOf(MAC, "token")]: "ghs_swm",
      [keyOf(MAC, "state")]: st(MAC, { misses: 1 }),
    },
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(subrequests(s) <= CAP, `subrequests ${subrequests(s)}`);
  assert.equal(
    s.f.calls.filter((c) => c.key === `PATCH ${varUrl(MAC)}`).length,
    1,
  );
  assert.equal(s.f.calls.filter((c) => c.key === NTFY).length, 1);
  assert.equal(stateFor(MAC, s.store).lastVar, "macos-latest");
});

test("pool_macos_drill_prefixed", async () => {
  const s = setupFor(MAC, worldFor(MAC), {
    [keyOf(MAC, "token")]: "ghs_swm",
    [keyOf(MAC, "state")]: st(MAC),
    [keyOf(MAC, "drill")]: "1",
    drill: "1",
  });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  const alerts = s.f.calls.filter((c) => c.key === NTFY);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].init.body, MAC.messages.drill);
  const result = JSON.parse(s.store.map.get("swm-macos:drill-result"));
  assert.equal(result.ok, true);
  assert.equal(s.store.map.has("swm-macos:drill"), false);
  assert.equal(s.store.map.get("drill"), "1");
  assert.equal(s.store.map.has("drill-result"), false);
});

test("pool_unknown_cron_does_nothing", async () => {
  const f = fakeFetch(worldFor(NOS));
  const store = fakeKV({ token: "ghs_nos", state: st(NOS) });
  const env = { ...bothApps(), STATE: store };
  const logged = await runScheduled(
    { cron: "0 * * * *", scheduledTime: NOW },
    env,
    f.fn,
  );
  assert.equal(f.calls.length, 0);
  assert.equal(store.ops.length, 0);
  assert.equal(logged.length, 1);
  assert.match(logged[0], /unknown cron/);
});

test("pool_scheduled_logs_no_secrets", async () => {
  const f = fakeFetch(
    worldFor(MAC, {
      runners: [],
      extra: { [`PATCH ${varUrl(MAC)}`]: { status: 500 } },
    }),
  );
  const store = fakeKV({
    [keyOf(MAC, "token")]: "ghs_swm_cached",
    [keyOf(MAC, "state")]: st(MAC, { misses: 1 }),
  });
  const env = { ...bothApps(), STATE: store };
  const logged = await runScheduled(
    { cron: MAC.cron, scheduledTime: NOW },
    env,
    f.fn,
  );
  assert.ok(f.calls.length > 0);
  assert.ok(f.calls.some((c) => c.key === `PATCH ${varUrl(MAC)}`));
  assert.ok(logged.length > 0);
  for (const line of logged) {
    for (const secret of [TOPIC, "ghs_swm_cached", env.SWM_APP_KEY_PKCS8]) {
      assert.ok(!line.includes(secret), line);
    }
  }
});

test("pool_world_repos_route_present", () => {
  // Guards the fixture: the macOS world lists swm repos only.
  const w = worldFor(MAC, { repos: { a: [] } });
  assert.deepEqual(w[REPOS].json.repositories, [
    { full_name: "smartwatermelon/a" },
  ]);
});
