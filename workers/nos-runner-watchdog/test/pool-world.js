// Fixtures for any pool: world() and setup() from world.js, with the org, variable and label taken from the pool.
import { fakeFetch, fakeKV, minutesAgo, GH, NOW } from "./fakes.js";
import { runTick } from "../src/index.js";

export const TOPIC = "topic-secret";
export const NTFY = `POST https://ntfy.sh/${TOPIC}`;
export const orgUrl = (pool) => `${GH}/orgs/${pool.org}`;
export const varUrl = (pool) =>
  `${orgUrl(pool)}/actions/variables/${pool.variable}`;
export const runnersKey = (pool) =>
  `GET ${orgUrl(pool)}/actions/runners?per_page=100`;
export const REPOS = `GET ${GH}/installation/repositories?per_page=100`;
export const fullFor = (pool, r) => `${pool.org}/${r}`;
export const repoUrlFor = (pool, r) =>
  `${GH}/repos/${fullFor(pool, r)}/actions/runs`;

export const runnerFor = (pool, name, busy, over = {}) => ({
  name,
  busy,
  status: "online",
  labels: [
    { id: 1, name: "self-hosted", type: "read-only" },
    { id: 2, name: pool.label, type: "custom" },
  ],
  ...over,
});

export const jobFor = (pool, over = {}) => ({
  id: 1,
  status: "queued",
  labels: [pool.label],
  created_at: minutesAgo(1),
  ...over,
});

// The lost-runner phase lists failed runs from 6 hours before the tick. Built here, not imported, so a wrong URL fails.
export const failedUrlFor = (pool, r, now = NOW) => {
  const since = new Date(now - 6 * 3600000)
    .toISOString()
    .replace(/\.\d{3}Z$/, "Z");
  return `GET ${repoUrlFor(pool, r)}?status=failure&created=>=${since}&per_page=20&exclude_pull_requests=true`;
};

// Same shape as world(): repos/inProgress {name: [{id, age, jobs?, attempt?}]}; jobs default to one pool-label job.
// failed {name: [{run, jobs}]} are the failed runs a rerunLost pool lists; such a pool gets an empty list for every other repo.
export function worldFor(
  pool,
  {
    varValue = pool.label,
    runners = [runnerFor(pool, "a", false), runnerFor(pool, "b", false)],
    repos = {},
    inProgress = {},
    failed = {},
    now = NOW,
    extra = {},
  } = {},
) {
  const names = [
    ...new Set([
      ...Object.keys(repos),
      ...Object.keys(inProgress),
      ...Object.keys(failed),
    ]),
  ];
  const routes = {
    [runnersKey(pool)]: { json: { runners } },
    [`GET ${varUrl(pool)}`]:
      varValue === null
        ? { status: 404 }
        : { json: { name: pool.variable, value: varValue } },
    [REPOS]: {
      json: {
        repositories: names.map((r) => ({ full_name: fullFor(pool, r) })),
      },
    },
    [`PATCH ${varUrl(pool)}`]: { status: 204 },
    [NTFY]: { status: 200 },
  };
  const addRuns = (r, list, status) => {
    routes[
      `GET ${repoUrlFor(pool, r)}?status=${status}&per_page=100&exclude_pull_requests=true`
    ] = {
      json: {
        workflow_runs: list.map((x) => ({
          id: x.id,
          created_at: minutesAgo(x.age),
          run_attempt: x.attempt ?? 1,
        })),
      },
    };
    for (const x of list) {
      const jobs = x.jobs ?? [
        jobFor(pool, {
          status: status === "queued" ? "queued" : "in_progress",
          created_at: minutesAgo(x.age),
        }),
      ];
      routes[`GET ${repoUrlFor(pool, r)}/${x.id}/jobs?per_page=100`] = {
        json: { jobs },
      };
      routes[`POST ${repoUrlFor(pool, r)}/${x.id}/cancel`] = { status: 202 };
    }
  };
  for (const r of names) {
    addRuns(r, repos[r] ?? [], "queued");
    addRuns(r, inProgress[r] ?? [], "in_progress");
    if (!pool.rerunLost) continue;
    const list = failed[r] ?? [];
    routes[failedUrlFor(pool, r, now)] = {
      json: { workflow_runs: list.map((x) => x.run) },
    };
    for (const x of list) {
      routes[`GET ${repoUrlFor(pool, r)}/${x.run.id}/jobs?per_page=100`] = {
        json: { jobs: x.jobs },
      };
      routes[`POST ${repoUrlFor(pool, r)}/${x.run.id}/rerun-failed-jobs`] = {
        status: 201,
      };
    }
  }
  return { ...routes, ...extra };
}

// Both App sets: NOS installation 77, swm installation 88.
export const bothApps = () => ({
  APP_ID: "1",
  INSTALLATION_ID: "77",
  APP_KEY_PKCS8: "not-a-key",
  SWM_APP_ID: "2",
  SWM_INSTALLATION_ID: "88",
  SWM_APP_KEY_PKCS8: "not-a-swm-key",
  NTFY_TOPIC: TOPIC,
});

export function setupFor(pool, routes, kv = {}, envOver = {}, store = null) {
  const f = fakeFetch(routes);
  const s = store ?? fakeKV(kv);
  const env = { ...bothApps(), STATE: s, ...envOver };
  return {
    f,
    store: s,
    env,
    tick: (now = NOW) => runTick(env, { fetch: f.fn, now, pool }),
  };
}

export const st = (pool, o) =>
  JSON.stringify({ lastVar: pool.label, misses: 0, goods: 0, ...o });
export const keyOf = (pool, k) => `${pool.prefix}${k}`;
export const stateFor = (pool, store) =>
  JSON.parse(store.map.get(keyOf(pool, "state")));
export const pendingFor = (pool, store) =>
  JSON.parse(store.map.get(keyOf(pool, "pendingReruns")) ?? "[]");
export const subrequests = (s) => s.f.calls.length + s.store.ops.length;
