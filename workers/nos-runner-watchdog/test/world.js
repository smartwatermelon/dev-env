// Shared fixtures for the Worker tests: a GitHub world, a tick harness, KV readers.
import {
  fakeFetch,
  fakeKV,
  runner,
  job,
  minutesAgo,
  GH,
  ORG,
  NOW,
} from "./fakes.js";
import { runTick } from "../src/index.js";

export const TOPIC = "topic-secret";
export const NTFY = `POST https://ntfy.sh/${TOPIC}`;
export const VAR = `${ORG}/actions/variables/NOS_RUNNER`;
export const RUNNERS = `GET ${ORG}/actions/runners?per_page=100`;
export const REPOS = `GET ${GH}/installation/repositories?per_page=100`;
export const repoUrl = (r) => `${GH}/repos/nightowlstudiollc/${r}/actions/runs`;
export const full = (r) => `nightowlstudiollc/${r}`;
export const idle = [runner("a", false), runner("b", false)];

// repos/inProgress: {name: [{id, age, jobs?, attempt?}]}; jobs default to one mimolette job.
export function world({
  varValue = "mimolette",
  runners = idle,
  repos = {},
  inProgress = {},
  extra = {},
} = {}) {
  const names = [
    ...new Set([...Object.keys(repos), ...Object.keys(inProgress)]),
  ];
  const routes = {
    [RUNNERS]: { json: { runners } },
    [`GET ${VAR}`]:
      varValue === null
        ? { status: 404 }
        : { json: { name: "NOS_RUNNER", value: varValue } },
    [REPOS]: {
      json: {
        repositories: names.map((r) => ({ full_name: full(r) })),
      },
    },
    [`PATCH ${VAR}`]: { status: 204 },
    [NTFY]: { status: 200 },
  };
  const addRuns = (r, list, status) => {
    routes[
      `GET ${repoUrl(r)}?status=${status}&per_page=100&exclude_pull_requests=true`
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
        job({
          status: status === "queued" ? "queued" : "in_progress",
          created_at: minutesAgo(x.age),
        }),
      ];
      routes[`GET ${repoUrl(r)}/${x.id}/jobs?per_page=100`] = {
        json: { jobs },
      };
      routes[`POST ${repoUrl(r)}/${x.id}/cancel`] = { status: 202 };
    }
  };
  for (const r of names) {
    addRuns(r, repos[r] ?? [], "queued");
    addRuns(r, inProgress[r] ?? [], "in_progress");
  }
  return { ...routes, ...extra };
}

// seq records fetches and KV puts in one ordered list.
export function setup(routes, kv = {}, envOver = {}) {
  const f = fakeFetch(routes);
  const store = fakeKV({ token: "ghs_cached", ...kv });
  const seq = [];
  const rawFn = f.fn;
  f.fn = (url, init = {}) => {
    seq.push(`${(init.method || "GET").toUpperCase()} ${url}`);
    return rawFn(url, init);
  };
  const rawPut = store.put.bind(store);
  store.put = (k, v, o) => {
    seq.push(`kv put ${k}`);
    return rawPut(k, v, o);
  };
  const env = {
    APP_ID: "1",
    INSTALLATION_ID: "77",
    APP_KEY_PKCS8: "not-a-key",
    NTFY_TOPIC: TOPIC,
    STATE: store,
    ...envOver,
  };
  return {
    f,
    store,
    env,
    seq,
    tick: (now = NOW) => runTick(env, { fetch: f.fn, now }),
  };
}

export const st = (o) =>
  JSON.stringify({ lastVar: "mimolette", misses: 0, goods: 0, ...o });
export const writes = (f) => f.calls.filter((c) => c.method !== "GET");
export const stateOf = (store) => JSON.parse(store.map.get("state"));
export const pendingOf = (store) =>
  JSON.parse(store.map.get("pendingReruns") ?? "[]");
export const idsOf = (store) =>
  pendingOf(store)
    .map((p) => p.runId)
    .sort((x, y) => x - y);
export const subrequests = (s) => s.f.calls.length + s.store.ops.length;
