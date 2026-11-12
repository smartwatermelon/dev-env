// Offline fakes: fetch keyed by "METHOD URL", KV over a Map, a fixed clock.
export const GH = "https://api.github.com";
export const ORG = `${GH}/orgs/nightowlstudiollc`;
export const NOW = Date.parse("2026-11-10T12:00:00Z");

// Any real network call fails the test.
globalThis.fetch = () => {
  throw new Error("real fetch called");
};

export function fakeFetch(routes = {}) {
  const calls = [];
  const unexpected = [];
  const fn = async (url, init = {}) => {
    const method = (init.method || "GET").toUpperCase();
    const key = `${method} ${url}`;
    calls.push({ key, method, url, init });
    let route = routes[key];
    if (typeof route === "function") route = route(init, calls);
    if (route === undefined) {
      unexpected.push(key);
      throw new Error(`unexpected fetch ${key}`);
    }
    const { status = 200, json } = route;
    const body = json === undefined ? null : JSON.stringify(json);
    return new Response(status === 204 ? null : body, { status });
  };
  return { fn, calls, unexpected, routes };
}

export function fakeKV(initial = {}) {
  const map = new Map(Object.entries(initial));
  const ops = [];
  const puts = [];
  return {
    map,
    ops,
    puts,
    async get(key) {
      ops.push(`get ${key}`);
      return map.has(key) ? map.get(key) : null;
    },
    async put(key, value, opts) {
      ops.push(`put ${key}`);
      puts.push({ key, value, opts });
      map.set(key, value);
    },
    async delete(key) {
      ops.push(`delete ${key}`);
      map.delete(key);
    },
  };
}

export const minutesAgo = (m) => new Date(NOW - m * 60000).toISOString();

export const runner = (name, busy, over = {}) => ({
  name,
  busy,
  status: "online",
  labels: [
    { id: 1, name: "self-hosted", type: "read-only" },
    { id: 2, name: "mimolette", type: "custom" },
  ],
  ...over,
});

export const job = (over = {}) => ({
  id: 1,
  status: "queued",
  labels: ["mimolette"],
  created_at: minutesAgo(1),
  ...over,
});

export async function pkcs8Pem() {
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const der = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  const b64 = Buffer.from(der)
    .toString("base64")
    .replace(/(.{64})/g, "$1\n");
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: pair.publicKey };
}
