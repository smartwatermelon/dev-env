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

/** Runs in one repo with the given status, as [{id, created_at}]. */
export async function listRuns(token, repo, status, fetchFn) {
  const path = `/repos/${repo}/actions/runs?status=${status}&per_page=100`;
  const out = await call(token, "GET", path, `runs ${status}`, fetchFn);
  return (out.workflow_runs ?? []).map((r) => ({
    id: r.id,
    created_at: r.created_at,
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

/** Queued runs per repo, then jobs of each repo's oldest run, oldest first. canFetch() can stop it early. */
export async function scanQueue(token, now, fetchFn, canFetch = () => true) {
  const repos = [];
  for (const repo of await listRepos(token, fetchFn)) {
    if (!canFetch()) break;
    const runs = await listRuns(token, repo, "queued", fetchFn);
    repos.push({ repo, runs, jobs: new Map() });
  }
  const oldestOf = (runs) =>
    runs.reduce((a, r) => (a && a.created_at <= r.created_at ? a : r), null);
  const withRuns = repos.filter((r) => r.runs.length > 0);
  withRuns.sort((a, b) =>
    oldestOf(a.runs).created_at < oldestOf(b.runs).created_at ? -1 : 1,
  );
  let oldest = null;
  for (const r of withRuns) {
    if (!canFetch()) break;
    const run = oldestOf(r.runs);
    const jobs = await getJobs(token, r.repo, run.id, fetchFn);
    r.jobs.set(run.id, jobs);
    for (const j of mimoletteJobs(jobs, ["queued"])) {
      const minutes = (now - Date.parse(j.created_at)) / 60000;
      if (oldest === null || minutes > oldest) oldest = minutes;
    }
  }
  return { oldestQueuedMinutes: oldest, repos };
}

export async function oldestQueuedMinutes(token, now, fetchFn) {
  return (await scanQueue(token, now, fetchFn)).oldestQueuedMinutes;
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
