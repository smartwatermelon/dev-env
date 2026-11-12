// The drill: KV key "drill" sends one test alert and changes nothing else.
import { test } from "node:test";
import assert from "node:assert/strict";
import { NTFY, world, setup, st, stateOf, writes } from "./world.js";

const sends = (s) => s.f.calls.filter((c) => c.key === NTFY);
const ghWrites = (s) => writes(s.f).filter((c) => c.key !== NTFY);

test("drill_sends_one_alert_and_records_result", async () => {
  const s = setup(world(), { state: st({}), drill: "1" });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(sends(s).length, 1);
  assert.match(sends(s)[0].init.body, /NOS runner drill: watchdog alert path/);
  assert.equal(ghWrites(s).length, 0);
  assert.equal(s.store.map.has("drill"), false);
  const r = JSON.parse(s.store.map.get("drill-result"));
  assert.equal(r.ok, true);
  assert.equal(r.tries, 1);
  assert.match(r.at, /^\d{4}-\d{2}-\d{2}T/);
});

test("drill_changes_no_state", async () => {
  const plain = setup(world(), { state: st({}) });
  await plain.tick();
  const drilled = setup(world(), { state: st({}), drill: "1" });
  await drilled.tick();
  assert.deepEqual(stateOf(drilled.store), stateOf(plain.store));
  assert.equal(sends(plain).length, 0);
  assert.equal(plain.store.map.has("drill-result"), false);
});

test("drill_records_failed_delivery", async () => {
  const s = setup(world({ extra: { [NTFY]: { status: 522 } } }), {
    state: st({}),
    drill: "1",
  });
  await s.tick();
  const r = JSON.parse(s.store.map.get("drill-result"));
  assert.equal(r.ok, false);
  assert.equal(r.tries, 3);
  assert.equal(s.store.map.has("drill"), false);
});

test("drill_sent_after_a_real_alert", async () => {
  const s = setup(world({ runners: [] }), {
    state: st({ misses: 1 }),
    drill: "1",
  });
  await s.tick();
  const bodies = sends(s).map((c) => c.init.body);
  assert.equal(bodies.length, 2);
  assert.match(bodies[0], /NOS runner down/);
  assert.match(bodies[1], /drill/);
});
