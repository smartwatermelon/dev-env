// ntfy delivery from the Worker: token header, retries on 5xx and network errors, budget.
import { test } from "node:test";
import assert from "node:assert/strict";
import { NTFY, world, setup, st, stateOf, subrequests } from "./world.js";
import { CAP } from "../src/index.js";

const downWorld = (ntfy) =>
  world({
    runners: [],
    repos: { a: [{ id: 11, age: 30 }] },
    inProgress: { a: [] },
    extra: { [NTFY]: ntfy },
  });
const sends = (s) => s.f.calls.filter((c) => c.key === NTFY);
// Answers in order, then the last one again.
const sequence = (...answers) => {
  let i = 0;
  return () => {
    const a = answers[Math.min(i, answers.length - 1)];
    i += 1;
    if (a === "throw") throw new TypeError("network");
    return { status: a };
  };
};

test("ntfy_sends_token_header", async () => {
  const s = setup(
    downWorld({ status: 200 }),
    { state: st({ misses: 1 }) },
    { NTFY_TOKEN: "tk_secret" },
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(sends(s).length, 1);
  assert.equal(sends(s)[0].init.headers.Authorization, "Bearer tk_secret");
});

test("ntfy_without_token_sends_no_auth_header", async () => {
  const s = setup(downWorld({ status: 200 }), { state: st({ misses: 1 }) });
  await s.tick();
  assert.equal(sends(s).length, 1);
  assert.equal(sends(s)[0].init.headers.Authorization, undefined);
});

test("ntfy_retries_5xx_and_network_errors", async () => {
  const s = setup(downWorld(sequence(522, "throw", 200)), {
    state: st({ misses: 1 }),
  });
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.equal(sends(s).length, 3);
  assert.equal(stateOf(s.store).lastVar, "ubuntu-latest");
});

test("ntfy_gives_up_after_three_tries", async () => {
  const s = setup(downWorld({ status: 522 }), { state: st({ misses: 1 }) });
  await s.tick();
  assert.equal(sends(s).length, 3);
});

test("ntfy_does_not_retry_4xx", async () => {
  const s = setup(downWorld({ status: 429 }), { state: st({ misses: 1 }) });
  await s.tick();
  assert.equal(sends(s).length, 1);
});

test("ntfy_skip_alert_retried_and_marked_sent", async () => {
  const s = setup(
    world({
      extra: {
        [`GET https://api.github.com/orgs/nightowlstudiollc/actions/runners?per_page=100`]:
          { status: 502 },
        [NTFY]: sequence(522, 200),
      },
    }),
    { state: st({}), skips: JSON.stringify({ count: 2, notified: false }) },
  );
  await s.tick();
  assert.equal(sends(s).length, 2);
  assert.deepEqual(JSON.parse(s.store.map.get("skips")), {
    count: 3,
    notified: true,
  });
});

test("ntfy_retries_stay_within_cap", async () => {
  const repos = Object.fromEntries(
    Array.from({ length: 10 }, (_, r) => [
      `r${r}`,
      Array.from({ length: 5 }, (_, k) => ({ id: r * 10 + k + 1, age: 30 })),
    ]),
  );
  const s = setup(
    world({
      runners: [],
      repos,
      inProgress: Object.fromEntries(Object.keys(repos).map((r) => [r, []])),
      extra: { [NTFY]: { status: 522 } },
    }),
    { state: st({ misses: 1 }) },
  );
  await s.tick();
  assert.deepEqual(s.f.unexpected, []);
  assert.ok(subrequests(s) <= CAP, `subrequests ${subrequests(s)}`);
  assert.equal(stateOf(s.store).lastVar, "ubuntu-latest");
});
