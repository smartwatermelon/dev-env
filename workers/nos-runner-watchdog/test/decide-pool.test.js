import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "../src/decide.js";

const L = { selfHosted: "mimolette-macos", fallback: "macos-latest" };
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
const good = (varValue = "mimolette-macos") => ({
  varValue,
  runners: idle,
  oldestQueuedMinutes: null,
});
const bad = (varValue = "mimolette-macos") => ({
  varValue,
  runners: [],
  oldestQueuedMinutes: null,
});
const prevOf = (r) => ({ ...r.next });

test("pool_macos_healthy_stays", () => {
  const r = decide({ ...fresh, lastVar: "mimolette-macos" }, good(), L);
  assert.equal(r.setVar, null);
  assert.equal(r.notify, null);
  assert.equal(r.next.lastVar, "mimolette-macos");
});

test("pool_macos_two_misses_switch_to_macos_latest", () => {
  const r1 = decide({ ...fresh, lastVar: "mimolette-macos" }, bad(), L);
  const r2 = decide(prevOf(r1), bad(), L);
  assert.equal(r2.setVar, "macos-latest");
  assert.equal(r2.notify, "down");
  assert.equal(r2.rerunStuck, true);
});

test("pool_macos_unset_goes_online", () => {
  const r1 = decide(fresh, good(null), L);
  assert.equal(r1.setVar, null);
  const r2 = decide(prevOf(r1), good(null), L);
  assert.equal(r2.setVar, "mimolette-macos");
  assert.equal(r2.notify, "online");
});

test("pool_macos_macos26_is_hold", () => {
  const r = decide(
    { ...fresh, lastVar: "mimolette-macos" },
    good("macos-26"),
    L,
  );
  assert.equal(r.setVar, null);
  assert.equal(r.notify, "held");
  assert.equal(r.next.lastVar, "macos-26");
  const r2 = decide(prevOf(r), good("macos-26"), L);
  assert.equal(r2.notify, null);
});

test("pool_macos_mimolette_value_is_hold", () => {
  const r = decide({ ...fresh, lastVar: "macos-latest" }, good("mimolette"), L);
  assert.equal(r.setVar, null);
  assert.equal(r.notify, "held");
});

test("pool_macos_single_gap_no_switch", () => {
  const r1 = decide({ ...fresh, lastVar: "mimolette-macos" }, bad(), L);
  assert.equal(r1.setVar, null);
  const r2 = decide(prevOf(r1), good(), L);
  assert.equal(r2.setVar, null);
  assert.equal(r2.next.misses, 0);
});

test("pool_macos_new_busy_name_is_progress", () => {
  let prev = { ...fresh, lastVar: "mimolette-macos" };
  for (let i = 0; i < 4; i += 1) {
    const r = decide(
      prev,
      {
        varValue: "mimolette-macos",
        runners: [{ name: `vm-${i}`, busy: true }],
        oldestQueuedMinutes: 25,
      },
      L,
    );
    assert.equal(r.setVar, null, `tick ${i}`);
    prev = prevOf(r);
  }
});

test("pool_macos_manual_flip_back_stays", () => {
  let prev = { ...fresh, lastVar: "mimolette-macos" };
  for (let i = 0; i < 2; i += 1) {
    prev = prevOf(decide(prev, bad(), L));
  }
  assert.equal(prev.lastVar, "macos-latest");
  // Operator flips the variable back to the label by hand; runners are healthy.
  for (let i = 0; i < 3; i += 1) {
    const r = decide(prev, good("mimolette-macos"), L);
    assert.equal(r.setVar, null, `tick ${i}`);
    assert.equal(r.next.lastVar, "mimolette-macos");
    prev = prevOf(r);
  }
});
