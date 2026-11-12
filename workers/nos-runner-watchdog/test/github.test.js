import { test } from "node:test";
import assert from "node:assert/strict";
import {
  fakeFetch,
  pkcs8Pem,
  runner,
  job,
  minutesAgo,
  GH,
  ORG,
  NOW,
} from "./fakes.js";
import {
  appToken,
  getRunners,
  getVar,
  setVar,
  cancelRun,
  rerunFailed,
  oldestQueuedMinutes,
  scanQueue,
  GitHubError,
} from "../src/github.js";

const b64url = (s) => JSON.parse(Buffer.from(s, "base64url").toString("utf8"));

test("app_token_signs_rs256_jwt_and_mints", async () => {
  const { pem, publicKey } = await pkcs8Pem();
  const f = fakeFetch({
    [`POST ${GH}/app/installations/77/access_tokens`]: {
      status: 201,
      json: { token: "ghs_new" },
    },
  });
  const env = { APP_ID: "123", INSTALLATION_ID: "77", APP_KEY_PKCS8: pem };
  const token = await appToken(env, f.fn, NOW);
  assert.equal(token, "ghs_new");
  assert.deepEqual(f.unexpected, []);
  const headers = f.calls[0].init.headers;
  assert.equal(headers.Accept, "application/vnd.github+json");
  assert.equal(headers["X-GitHub-Api-Version"], "2022-11-28");
  assert.equal(headers["User-Agent"], "nos-runner-watchdog");
  const jwt = headers.Authorization.replace(/^Bearer /, "");
  const [h, p, s] = jwt.split(".");
  assert.deepEqual(b64url(h), { alg: "RS256", typ: "JWT" });
  const now = Math.floor(NOW / 1000);
  assert.deepEqual(b64url(p), { iat: now - 60, exp: now + 540, iss: "123" });
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    publicKey,
    Buffer.from(s, "base64url"),
    new TextEncoder().encode(`${h}.${p}`),
  );
  assert.equal(ok, true);
});

test("offline_runner_not_counted", async () => {
  const f = fakeFetch({
    [`GET ${ORG}/actions/runners?per_page=100`]: {
      json: {
        runners: [
          runner("on-idle", false),
          runner("off-idle", false, { status: "offline" }),
          runner("other", false, { labels: [{ name: "self-hosted" }] }),
          runner("on-busy", true),
        ],
      },
    },
  });
  const r = await getRunners("t", f.fn);
  assert.deepEqual(r, [
    { name: "on-idle", busy: false },
    { name: "on-busy", busy: true },
  ]);
  assert.equal(f.calls[0].init.headers.Authorization, "Bearer t");
});

test("var_404_is_unset", async () => {
  const f = fakeFetch({
    [`GET ${ORG}/actions/variables/NOS_RUNNER`]: {
      status: 404,
      json: { message: "Not Found" },
    },
  });
  assert.equal(await getVar("t", f.fn), null);
});

test("var_get_5xx_throws", async () => {
  const f = fakeFetch({
    [`GET ${ORG}/actions/variables/NOS_RUNNER`]: { status: 502 },
  });
  await assert.rejects(
    getVar("t", f.fn),
    (e) => e instanceof GitHubError && e.status === 502,
  );
});

test("set_var_patches_then_posts_on_404", async () => {
  const body = {
    name: "NOS_RUNNER",
    value: "ubuntu-latest",
    visibility: "private",
  };
  const f = fakeFetch({
    [`PATCH ${ORG}/actions/variables/NOS_RUNNER`]: { status: 404 },
    [`POST ${ORG}/actions/variables`]: { status: 201 },
  });
  await setVar("t", "ubuntu-latest", f.fn);
  assert.deepEqual(
    f.calls.map((c) => c.key),
    [
      `PATCH ${ORG}/actions/variables/NOS_RUNNER`,
      `POST ${ORG}/actions/variables`,
    ],
  );
  assert.deepEqual(JSON.parse(f.calls[0].init.body), body);
  assert.deepEqual(JSON.parse(f.calls[1].init.body), body);
});

test("cancel_and_rerun_urls", async () => {
  const run = `${GH}/repos/nightowlstudiollc/a/actions/runs/5`;
  const f = fakeFetch({
    [`POST ${run}/cancel`]: { status: 202 },
    [`POST ${run}/rerun-failed-jobs`]: { status: 201 },
  });
  await cancelRun("t", "nightowlstudiollc/a", 5, f.fn);
  await rerunFailed("t", "nightowlstudiollc/a", 5, f.fn);
  assert.deepEqual(f.unexpected, []);
});

test("oldest_queued_reads_oldest_run_jobs_only", async () => {
  const runs = `${GH}/repos/nightowlstudiollc/a/actions/runs`;
  const f = fakeFetch({
    [`GET ${GH}/installation/repositories?per_page=100`]: {
      json: {
        repositories: [
          { full_name: "nightowlstudiollc/a" },
          { full_name: "nightowlstudiollc/b" },
        ],
      },
    },
    [`GET ${runs}?status=queued&per_page=100&exclude_pull_requests=true`]: {
      json: {
        workflow_runs: [
          { id: 2, created_at: minutesAgo(5) },
          { id: 1, created_at: minutesAgo(30) },
        ],
      },
    },
    [`GET ${runs}/1/jobs?per_page=100`]: {
      json: {
        jobs: [
          job({ created_at: minutesAgo(25) }),
          job({ labels: ["ubuntu-latest"], created_at: minutesAgo(29) }),
          job({ status: "completed", created_at: minutesAgo(29) }),
        ],
      },
    },
    [`GET ${runs}?status=in_progress&per_page=100&exclude_pull_requests=true`]:
      {
        json: { workflow_runs: [] },
      },
    [`GET ${GH}/repos/nightowlstudiollc/b/actions/runs?status=queued&per_page=100&exclude_pull_requests=true`]:
      {
        json: { workflow_runs: [] },
      },
    [`GET ${GH}/repos/nightowlstudiollc/b/actions/runs?status=in_progress&per_page=100&exclude_pull_requests=true`]:
      {
        json: { workflow_runs: [] },
      },
  });
  assert.equal(await oldestQueuedMinutes("t", NOW, f.fn), 25);
  assert.deepEqual(f.unexpected, []);
});

test("scan_queue_rotates_from_cursor", async () => {
  const names = ["a", "b", "c"];
  const routes = {
    [`GET ${GH}/installation/repositories?per_page=100`]: {
      json: {
        repositories: names.map((n) => ({
          full_name: `nightowlstudiollc/${n}`,
        })),
      },
    },
  };
  for (const n of names) {
    for (const s of ["queued", "in_progress"]) {
      routes[
        `GET ${GH}/repos/nightowlstudiollc/${n}/actions/runs?status=${s}&per_page=100&exclude_pull_requests=true`
      ] = { json: { workflow_runs: [] } };
    }
  }
  const f = fakeFetch(routes);
  let left = 10; // each repo asks for its worst case: 2 lists + 3 job probes
  const canFetch = (n) => {
    if (n > left) return false;
    left -= n;
    return true;
  };
  const out = await scanQueue("t", f.fn, { cursor: 1, canFetch });
  assert.deepEqual(
    out.repos.map((r) => r.repo),
    ["nightowlstudiollc/b", "nightowlstudiollc/c"],
  );
  assert.equal(out.nextCursor, 0);
  assert.deepEqual(f.unexpected, []);
});

test("pkcs1_key_fails_with_clear_message", async () => {
  const env = {
    APP_ID: "1",
    INSTALLATION_ID: "77",
    APP_KEY_PKCS8:
      "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n",
  };
  const f = fakeFetch({});
  await assert.rejects(appToken(env, f.fn, NOW), /PKCS1/);
  assert.equal(f.calls.length, 0);
});
