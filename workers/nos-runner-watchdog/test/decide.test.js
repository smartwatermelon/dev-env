import { test } from "node:test";
import assert from "node:assert/strict";
import {
  decide,
  HUNG_TICKS,
  QUEUE_LIMIT_MINUTES,
  RECOVERY_BACKOFF_CAP,
  STABLE_TICKS,
} from "../src/decide.js";

const fresh = {
  lastVar: null,
  misses: 0,
  goods: 0,
  busyNames: [],
  sameBusyTicks: 0,
};
const idle = [
  { name: "a", busy: false },
  { name: "b", busy: false },
];
const good = (varValue = "mimolette") => ({
  varValue,
  runners: idle,
  oldestQueuedMinutes: null,
});
const bad = (varValue = "mimolette") => ({
  varValue,
  runners: [],
  oldestQueuedMinutes: null,
});
const prevOf = (r, over = {}) => ({ ...r.next, ...over });

test("constants", () => {
  assert.equal(HUNG_TICKS, 3);
  assert.equal(QUEUE_LIMIT_MINUTES, 20);
});

test("healthy_stays_mimolette_no_alert", () => {
  const r = decide({ ...fresh, lastVar: "mimolette" }, good());
  assert.equal(r.setVar, null);
  assert.equal(r.notify, null);
  assert.equal(r.rerunStuck, false);
  assert.equal(r.next.lastVar, "mimolette");
  assert.equal(r.next.misses, 0);
});

test("one_miss_no_switch", () => {
  const r = decide({ ...fresh, lastVar: "mimolette" }, bad());
  assert.equal(r.setVar, null);
  assert.equal(r.notify, null);
  assert.equal(r.next.misses, 1);
  assert.equal(r.next.goods, 0);
});

test("two_misses_switch_down_once", () => {
  const r1 = decide({ ...fresh, lastVar: "mimolette" }, bad());
  const r2 = decide(prevOf(r1), bad());
  assert.equal(r2.setVar, "ubuntu-latest");
  assert.equal(r2.notify, "down");
  assert.equal(r2.rerunStuck, true);
  assert.equal(r2.next.lastVar, "ubuntu-latest");
  assert.equal(r2.next.misses, 0);
  const r3 = decide(prevOf(r2), bad("ubuntu-latest"));
  assert.equal(r3.setVar, null);
  assert.equal(r3.notify, null);
  assert.equal(r3.rerunStuck, false);
  assert.equal(r3.next.misses, 1);
});

test("long_queue_all_busy_progressing_is_healthy", () => {
  let prev = { ...fresh, lastVar: "mimolette" };
  for (let i = 0; i < 6; i += 1) {
    const r = decide(prev, {
      varValue: "mimolette",
      runners: [
        { name: `a${i}`, busy: true },
        { name: `b${i}`, busy: true },
      ],
      oldestQueuedMinutes: 180,
    });
    assert.equal(r.setVar, null);
    assert.equal(r.notify, null);
    assert.equal(r.next.misses, 0);
    assert.equal(r.next.sameBusyTicks, 0);
    prev = prevOf(r);
  }
});

test("long_queue_all_busy_unchanged_3_ticks_is_unhealthy", () => {
  const obs = {
    varValue: "mimolette",
    runners: [
      { name: "a", busy: true },
      { name: "b", busy: true },
    ],
    oldestQueuedMinutes: 180,
  };
  let prev = { ...fresh, lastVar: "mimolette" };
  const ticks = [];
  for (let i = 0; i < 5; i += 1) {
    const r = decide(prev, obs);
    ticks.push(r);
    prev = prevOf(r);
  }
  assert.deepEqual(
    ticks.map((t) => t.next.sameBusyTicks),
    [0, 1, 2, 3, 4],
  );
  assert.equal(ticks[2].next.misses, 0);
  assert.equal(ticks[3].next.misses, 1);
  assert.equal(ticks[4].setVar, "ubuntu-latest");
  assert.equal(ticks[4].notify, "down");
});

test("sameBusyTicks_resets_when_names_change", () => {
  const mk = (names) => ({
    varValue: "mimolette",
    runners: names.map((name) => ({ name, busy: true })),
    oldestQueuedMinutes: 5,
  });
  const r1 = decide({ ...fresh, lastVar: "mimolette" }, mk(["a", "b"]));
  const r2 = decide(prevOf(r1), mk(["b", "a"]));
  assert.equal(r2.next.sameBusyTicks, 1);
  const r3 = decide(prevOf(r2), mk(["a", "c"]));
  assert.equal(r3.next.sameBusyTicks, 0);
  assert.deepEqual(r3.next.busyNames, ["a", "c"]);
});

test("queued_over_20_with_idle_runner_is_unhealthy", () => {
  const r = decide(
    { ...fresh, lastVar: "mimolette" },
    { ...good(), oldestQueuedMinutes: 21 },
  );
  assert.equal(r.next.misses, 1);
});

test("queued_exactly_20_with_idle_runner_is_healthy", () => {
  const r = decide(
    { ...fresh, lastVar: "mimolette" },
    { ...good(), oldestQueuedMinutes: 20 },
  );
  assert.equal(r.next.misses, 0);
});

test("null_oldestQueued_with_idle_runner_is_healthy", () => {
  const r = decide({ ...fresh, lastVar: "mimolette" }, good());
  assert.equal(r.next.misses, 0);
  assert.equal(r.next.goods, 1);
});

test("no_runners_is_unhealthy", () => {
  const r = decide({ ...fresh, lastVar: "mimolette" }, bad());
  assert.equal(r.next.misses, 1);
});

test("unset_var_treated_as_ubuntu", () => {
  const r1 = decide(fresh, good(null));
  assert.equal(r1.setVar, null);
  assert.equal(r1.next.goods, 1);
  const r2 = decide(prevOf(r1), good(""));
  assert.equal(r2.setVar, "mimolette");
  assert.equal(r2.notify, "online");
  assert.equal(r2.next.lastVar, "mimolette");
});

test("external_var_change_resets_counts_no_alert", () => {
  const prev = { ...fresh, lastVar: "mimolette", misses: 1 };
  const r = decide(prev, bad("ubuntu-latest"));
  assert.equal(r.setVar, null);
  assert.equal(r.notify, null);
  assert.equal(r.rerunStuck, false);
  assert.equal(r.next.lastVar, "ubuntu-latest");
  assert.equal(r.next.misses, 1);
  assert.equal(r.next.goods, 0);
});

test("two_goods_recover_once", () => {
  const start = { ...fresh, lastVar: "ubuntu-latest" };
  const r1 = decide(start, good("ubuntu-latest"));
  assert.equal(r1.setVar, null);
  const r2 = decide(prevOf(r1), good("ubuntu-latest"));
  assert.equal(r2.setVar, "mimolette");
  assert.equal(r2.notify, "recovered");
  assert.equal(r2.rerunStuck, false);
  const r3 = decide(prevOf(r2), good("mimolette"));
  assert.equal(r3.setVar, null);
  assert.equal(r3.notify, null);
});

test("recovery_requires_an_idle_runner", () => {
  const obs = {
    varValue: "ubuntu-latest",
    runners: [
      { name: "a", busy: true },
      { name: "b", busy: true },
    ],
    oldestQueuedMinutes: null,
  };
  let prev = { ...fresh, lastVar: "ubuntu-latest" };
  for (let i = 0; i < 3; i += 1) {
    const r = decide(prev, obs);
    assert.equal(r.setVar, null);
    assert.equal(r.notify, null);
    prev = prevOf(r);
  }
});

test("hung_runner_after_down_does_not_flap", () => {
  const busy = (q) => ({
    varValue: "mimolette",
    runners: [
      { name: "a", busy: true },
      { name: "b", busy: true },
    ],
    oldestQueuedMinutes: q,
  });
  let prev = { ...fresh, lastVar: "mimolette" };
  let down = null;
  for (let i = 0; i < 6 && !down; i += 1) {
    const r = decide(prev, busy(180));
    if (r.setVar) down = r;
    prev = prevOf(r);
  }
  assert.equal(down.notify, "down");
  for (let i = 0; i < 5; i += 1) {
    const r = decide(prev, { ...busy(null), varValue: "ubuntu-latest" });
    assert.equal(r.setVar, null);
    assert.equal(r.notify, null);
    prev = prevOf(r);
  }
});

test("repeated_outages_back_off_recovery", () => {
  assert.equal(RECOVERY_BACKOFF_CAP, 3);
  const stalled = (v) => ({ ...good(v), oldestQueuedMinutes: 30 });
  let prev = { ...fresh, lastVar: "mimolette" };
  const needed = [];
  for (let cycle = 0; cycle < 3; cycle += 1) {
    let r;
    do {
      r = decide(prev, stalled("mimolette"));
      prev = prevOf(r);
    } while (!r.setVar);
    assert.equal(r.notify, "down");
    let ticks = 0;
    do {
      ticks += 1;
      r = decide(prev, good("ubuntu-latest"));
      prev = prevOf(r);
    } while (!r.setVar);
    needed.push(ticks);
  }
  assert.deepEqual(needed, [2, 4, 8]);
});

test("stable_hour_resets_backoff", () => {
  assert.equal(STABLE_TICKS, 6);
  let prev = { ...fresh, lastVar: "mimolette", flaps: 3 };
  for (let i = 1; i <= 6; i += 1) {
    const r = decide(prev, good());
    assert.equal(r.next.flaps, i < 6 ? 3 : 0);
    prev = prevOf(r);
  }
});

test("manual_hold_is_respected", () => {
  let prev = { ...fresh, lastVar: "mimolette", misses: 1 };
  for (let i = 0; i < 4; i += 1) {
    const r = decide(prev, bad("ubuntu-24.04"));
    assert.equal(r.setVar, null);
    assert.equal(r.rerunStuck, false);
    assert.equal(r.next.misses, 0);
    assert.equal(r.next.goods, 0);
    prev = prevOf(r);
  }
});

test("typo_value_alerts_held_once", () => {
  const r1 = decide({ ...fresh, lastVar: "mimolette" }, good("mimolet"));
  assert.equal(r1.notify, "held");
  const r2 = decide(prevOf(r1), good("mimolet"));
  assert.equal(r2.notify, null);
  assert.equal(r2.setVar, null);
});

test("hold_release_resets_counts", () => {
  const prev = { ...fresh, lastVar: "ubuntu-24.04", misses: 0, goods: 0 };
  const r = decide(prev, good("ubuntu-latest"));
  assert.equal(r.notify, null);
  assert.equal(r.setVar, null);
  assert.equal(r.next.lastVar, "ubuntu-latest");
  assert.equal(r.next.goods, 1);
});

test("old_state_blob_missing_fields", () => {
  const r = decide({ lastVar: "mimolette" }, good());
  assert.equal(r.next.misses, 0);
  assert.equal(r.next.goods, 1);
  assert.equal(r.next.flaps, 0);
  assert.deepEqual(r.next.busyNames, []);
});

test("streak_must_be_contiguous_on_mimolette", () => {
  let prev = { ...fresh, lastVar: "mimolette", flaps: 3 };
  for (let i = 0; i < 5; i += 1) prev = prevOf(decide(prev, good()));
  prev = prevOf(decide(prev, good("ubuntu-24.04")));
  assert.equal(prev.healthyStreak, 0);
  const r = decide(prev, good("mimolette"));
  assert.equal(r.next.healthyStreak, 1);
  assert.equal(r.next.flaps, 3);
});
