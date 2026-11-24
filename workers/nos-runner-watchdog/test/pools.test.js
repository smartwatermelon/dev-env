import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { POOLS, poolForCron, appEnv } from "../src/pools.js";

test("pool_missing_cron_is_nos", () => {
  assert.equal(poolForCron(undefined), POOLS.nos);
});

test("pool_nos_cron_is_nos", () => {
  assert.equal(poolForCron("*/10 * * * *"), POOLS.nos);
});

test("pool_macos_cron_is_macos", () => {
  assert.equal(poolForCron("5,15,25,35,45,55 * * * *"), POOLS.swmMacos);
});

test("pool_unknown_cron_is_null", () => {
  assert.equal(poolForCron("0 * * * *"), null);
});

test("pool_crons_unique", () => {
  const crons = Object.values(POOLS).map((p) => p.cron);
  assert.equal(new Set(crons).size, crons.length);
});

test("pool_nos_messages_unchanged", () => {
  const m = POOLS.nos.messages;
  assert.equal(
    m.down(),
    "NOS runner down: NOS_RUNNER set to ubuntu-latest; stuck runs cancelled for re-run.",
  );
  assert.equal(
    m.recovered(),
    "NOS runner recovered: NOS_RUNNER set to mimolette.",
  );
  assert.equal(
    m.online(),
    "NOS runner online: NOS_RUNNER was unset, now mimolette.",
  );
  assert.equal(
    m.held("x"),
    "NOS runner held: NOS_RUNNER=x; the watchdog leaves it alone.",
  );
  assert.equal(m.skip("network"), "watchdog skipping: network");
  assert.equal(m.ok, "watchdog ok: ticks are running again.");
  assert.equal(
    m.drill,
    "NOS runner drill: watchdog alert path. No action needed.",
  );
});

test("pool_macos_messages_prefixed", () => {
  const m = POOLS.swmMacos.messages;
  const texts = [
    m.down(),
    m.recovered(),
    m.online(),
    m.held("macos-26"),
    m.skip("network"),
    m.ok,
    m.drill,
  ];
  for (const t of texts) assert.ok(t.startsWith("macOS runner:"), t);
  assert.equal(
    m.held("macos-26"),
    "macOS runner: held. SWM_MACOS_RUNNER=macos-26; the watchdog leaves it alone.",
  );
  assert.equal(
    m.down(),
    "macOS runner: down. SWM_MACOS_RUNNER set to macos-latest; stuck runs cancelled for re-run.",
  );
});

test("app_env_nos_reads_old_secret_names", () => {
  const env = { APP_ID: "1", INSTALLATION_ID: "2", APP_KEY_PKCS8: "k" };
  assert.deepEqual(appEnv(env, POOLS.nos), env);
});

test("app_env_swm_null_when_any_missing", () => {
  const full = {
    SWM_APP_ID: "1",
    SWM_INSTALLATION_ID: "2",
    SWM_APP_KEY_PKCS8: "k",
  };
  assert.deepEqual(appEnv(full, POOLS.swmMacos), {
    APP_ID: "1",
    INSTALLATION_ID: "2",
    APP_KEY_PKCS8: "k",
  });
  for (const key of Object.keys(full)) {
    const env = { ...full, [key]: "" };
    assert.equal(appEnv(env, POOLS.swmMacos), null, key);
    delete env[key];
    assert.equal(appEnv(env, POOLS.swmMacos), null, key);
  }
});

test("pool_wrangler_crons_match", () => {
  const toml = readFileSync(
    new URL("../wrangler.toml", import.meta.url),
    "utf8",
  );
  const m = toml.match(/^crons\s*=\s*\[([^\]]*)\]/m);
  assert.ok(m, "crons array present");
  const crons = [...m[1].matchAll(/"([^"]*)"/g)].map((x) => x[1]);
  const want = Object.values(POOLS).map((p) => p.cron);
  assert.deepEqual([...crons].sort(), [...want].sort());
});
