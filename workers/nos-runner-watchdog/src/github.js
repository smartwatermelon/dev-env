const API = "https://api.github.com";
const ORG = "nightowlstudiollc";
const VAR = "NOS_RUNNER";
const LABEL = "mimolette";

/** Non-2xx from GitHub. `what` names the call; it never holds a token. */
export class GitHubError extends Error {
  constructor(what, status) {
    super(`${what}: HTTP ${status}`);
    this.what = what;
    this.status = status;
  }
}

function headers(auth) {
  return {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "nos-runner-watchdog",
    Authorization: `Bearer ${auth}`,
  };
}

async function call(auth, method, path, what, fetchFn, body) {
  const init = { method, headers: headers(auth) };
  if (body !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  const res = await fetchFn(`${API}${path}`, init);
  if (res.status < 200 || res.status > 299)
    throw new GitHubError(what, res.status);
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

const b64url = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
const b64urlJson = (obj) =>
  b64url(new TextEncoder().encode(JSON.stringify(obj)));

function pemToDer(pem) {
  if (pem.includes("BEGIN RSA PRIVATE KEY")) {
    throw new Error(
      "APP_KEY_PKCS8 is PKCS1: convert with openssl pkcs8 -topk8 -nocrypt",
    );
  }
  const b64 = pem
    .replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

/** Signs an RS256 App JWT from the PKCS8 PEM key and mints an installation token. */
export async function appToken(env, fetchFn, now = Date.now()) {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(env.APP_KEY_PKCS8),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const iat = Math.floor(now / 1000) - 60;
  const head = b64urlJson({ alg: "RS256", typ: "JWT" });
  const claims = b64urlJson({ iat, exp: iat + 600, iss: String(env.APP_ID) });
  const input = `${head}.${claims}`;
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(input),
  );
  const path = `/app/installations/${env.INSTALLATION_ID}/access_tokens`;
  const out = await call(
    `${input}.${b64url(sig)}`,
    "POST",
    path,
    "mint token",
    fetchFn,
  );
  return out.token;
}

/** Online runners that carry the mimolette label, as [{name, busy}]. */
export async function getRunners(token, fetchFn) {
  const out = await call(
    token,
    "GET",
    `/orgs/${ORG}/actions/runners?per_page=100`,
    "runners",
    fetchFn,
  );
  return (out.runners ?? [])
    .filter(
      (r) =>
        r.status === "online" && (r.labels ?? []).some((l) => l.name === LABEL),
    )
    .map((r) => ({ name: r.name, busy: Boolean(r.busy) }));
}

/** NOS_RUNNER value, or null when the variable does not exist. */
export async function getVar(token, fetchFn) {
  try {
    const out = await call(
      token,
      "GET",
      `/orgs/${ORG}/actions/variables/${VAR}`,
      "var get",
      fetchFn,
    );
    return out?.value ?? null;
  } catch (e) {
    if (e instanceof GitHubError && e.status === 404) return null;
    throw e;
  }
}

/** Updates NOS_RUNNER; creates it when the update returns 404. */
export async function setVar(token, value, fetchFn) {
  const body = { name: VAR, value, visibility: "private" };
  try {
    await call(
      token,
      "PATCH",
      `/orgs/${ORG}/actions/variables/${VAR}`,
      "var update",
      fetchFn,
      body,
    );
  } catch (e) {
    if (!(e instanceof GitHubError && e.status === 404)) throw e;
    await call(
      token,
      "POST",
      `/orgs/${ORG}/actions/variables`,
      "var create",
      fetchFn,
      body,
    );
  }
}

export async function listRepos(token, fetchFn) {
  const out = await call(
    token,
    "GET",
    "/installation/repositories?per_page=100",
    "repos",
    fetchFn,
  );
  return (out.repositories ?? []).map((r) => r.full_name);
}

/** Runs in one repo with the given status, as [{id, created_at, run_attempt, status}]. */
export async function listRuns(token, repo, status, fetchFn) {
  // exclude_pull_requests shrinks each page, keeping JSON parsing inside the 10 ms CPU limit.
  const path = `/repos/${repo}/actions/runs?status=${status}&per_page=100&exclude_pull_requests=true`;
  const out = await call(token, "GET", path, `runs ${status}`, fetchFn);
  return (out.workflow_runs ?? []).map((r) => ({
    id: r.id,
    created_at: r.created_at,
    run_attempt: r.run_attempt ?? 1,
    status,
  }));
}

export async function getJobs(token, repo, runId, fetchFn) {
  const out = await call(
    token,
    "GET",
    `/repos/${repo}/actions/runs/${runId}/jobs?per_page=100`,
    "jobs",
    fetchFn,
  );
  return out.jobs ?? [];
}

/** Jobs on a mimolette runner that are still waiting or running. */
export function mimoletteJobs(jobs, statuses = ["queued", "in_progress"]) {
  return jobs.filter(
    (j) => statuses.includes(j.status) && (j.labels ?? []).includes(LABEL),
  );
}

// A multi-job run waiting on mimolette shows as in_progress, so both lists are read.
const SCAN_STATUSES = ["queued", "in_progress"];
// Runs whose jobs one repo scan may fetch; a mimolette job behind more hosted runs stays hidden.
export const MAX_JOB_PROBES = 3;

/** One repo: its waiting runs, then jobs run by run until a queued mimolette job. Null when canFetch(n) refuses. */
export async function scanRepo(token, repo, fetchFn, canFetch = () => true) {
  // Ask for the worst case (lists + job probes) up front, so a started repo is never dropped half-read.
  if (!canFetch(SCAN_STATUSES.length + MAX_JOB_PROBES)) return null;
  const runs = [];
  for (const status of SCAN_STATUSES) {
    runs.push(...(await listRuns(token, repo, status, fetchFn)));
  }
  const jobs = new Map();
  let oldestAt = null;
  // Oldest first across both lists: a run whose first job started is in_progress with mimolette still queued.
  const ordered = [...runs].sort(
    (a, b) => Date.parse(a.created_at) - Date.parse(b.created_at),
  );
  for (const run of ordered.slice(0, MAX_JOB_PROBES)) {
    const list = await getJobs(token, repo, run.id, fetchFn);
    jobs.set(run.id, list);
    const queued = mimoletteJobs(list, ["queued"]);
    if (queued.length === 0) continue;
    oldestAt = Math.min(...queued.map((j) => Date.parse(j.created_at)));
    break;
  }
  return { repo, runs, jobs, oldestAt };
}

/** Scans repos in rotation from cursor until canFetch(n) refuses. oldestAt is epoch ms or null. */
export async function scanQueue(token, fetchFn, { cursor = 0, canFetch } = {}) {
  const all = await listRepos(token, fetchFn);
  const n = all.length;
  const start = n > 0 ? ((cursor % n) + n) % n : 0;
  const repos = [];
  for (let i = 0; i < n; i += 1) {
    const r = await scanRepo(token, all[(start + i) % n], fetchFn, canFetch);
    if (!r) break;
    repos.push(r);
  }
  return { all, repos, nextCursor: n > 0 ? (start + repos.length) % n : 0 };
}

/** Minutes the oldest queued mimolette job has waited, all repos, no budget gate. Tests and diagnostics only. */
export async function oldestQueuedMinutes(token, now, fetchFn) {
  const { repos } = await scanQueue(token, fetchFn);
  const times = repos.map((r) => r.oldestAt).filter((t) => t !== null);
  return times.length > 0 ? (now - Math.min(...times)) / 60000 : null;
}

export async function getRun(token, repo, runId, fetchFn) {
  return call(
    token,
    "GET",
    `/repos/${repo}/actions/runs/${runId}`,
    "run",
    fetchFn,
  );
}

export async function cancelRun(token, repo, runId, fetchFn) {
  await call(
    token,
    "POST",
    `/repos/${repo}/actions/runs/${runId}/cancel`,
    "cancel",
    fetchFn,
  );
}

export async function rerunFailed(token, repo, runId, fetchFn) {
  await call(
    token,
    "POST",
    `/repos/${repo}/actions/runs/${runId}/rerun-failed-jobs`,
    "rerun",
    fetchFn,
  );
}
