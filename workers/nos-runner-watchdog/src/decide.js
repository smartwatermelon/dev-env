export const HUNG_TICKS = 3;
export const QUEUE_LIMIT_MINUTES = 20;

const FALLBACK = "ubuntu-latest";
const SELF_HOSTED = "mimolette";

/**
 * @typedef {{lastVar: string|null, misses: number, goods: number,
 *   busyNames?: string[], sameBusyTicks?: number}} State
 */

/**
 * @typedef {{varValue: string|null, runners: {name: string, busy: boolean}[],
 *   oldestQueuedMinutes: number|null}} Observed
 */

/** @typedef {{lastVar: string, misses: number, goods: number,
 *   busyNames: string[], sameBusyTicks: number}} Next */

/** @typedef {{next: Next, setVar: string|null, notify: string|null,
 *   rerunStuck: boolean}} Decision */

/**
 * Pure decision for one watchdog tick.
 * @param {State} prev state saved by the previous tick
 * @param {Observed} observed what this tick saw
 * @returns {Decision}
 */
export function decide(prev, observed) {
  const unset = !observed.varValue;
  const current = unset ? FALLBACK : observed.varValue;
  const external = prev.lastVar !== null && current !== prev.lastVar;
  let misses = external ? 0 : prev.misses;
  let goods = external ? 0 : prev.goods;

  const { runners, oldestQueuedMinutes } = observed;
  const queued = oldestQueuedMinutes !== null;
  const busyNames = runners
    .filter((r) => r.busy)
    .map((r) => r.name)
    .sort();
  const allBusy = runners.length > 0 && busyNames.length === runners.length;
  const sameNames =
    busyNames.length === (prev.busyNames ?? []).length &&
    busyNames.every((n, i) => n === prev.busyNames[i]);
  const sameBusyTicks =
    queued && allBusy && sameNames ? (prev.sameBusyTicks ?? 0) + 1 : 0;

  const unhealthy =
    runners.length === 0 ||
    (queued &&
      oldestQueuedMinutes > QUEUE_LIMIT_MINUTES &&
      runners.some((r) => !r.busy)) ||
    sameBusyTicks >= HUNG_TICKS;

  if (unhealthy) {
    misses += 1;
    goods = 0;
  } else {
    goods += 1;
    misses = 0;
  }

  let setVar = null;
  let notify = null;
  let rerunStuck = false;
  if (unhealthy && misses >= 2 && current === SELF_HOSTED) {
    setVar = FALLBACK;
    notify = "down";
    rerunStuck = true;
  } else if (!unhealthy && goods >= 2 && current === FALLBACK) {
    setVar = SELF_HOSTED;
    notify = unset ? "online" : "recovered";
  }
  if (setVar) {
    misses = 0;
    goods = 0;
  }

  return {
    next: {
      lastVar: setVar ?? current,
      misses,
      goods,
      busyNames,
      sameBusyTicks,
    },
    setVar,
    notify,
    rerunStuck,
  };
}
