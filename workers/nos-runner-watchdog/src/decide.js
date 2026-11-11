export const HUNG_TICKS = 3;
export const QUEUE_LIMIT_MINUTES = 20;
export const RECOVERY_BACKOFF_CAP = 3;
export const STABLE_TICKS = 6;

const FALLBACK = "ubuntu-latest";
const SELF_HOSTED = "mimolette";

/**
 * @typedef {{lastVar: string|null, misses: number, goods: number,
 *   busyNames?: string[], sameBusyTicks?: number, flaps?: number,
 *   healthyStreak?: number}} State
 */

/**
 * Observed: runners lists online runners only.
 * @typedef {{varValue: string|null, runners: {name: string, busy: boolean}[],
 *   oldestQueuedMinutes: number|null}} Observed
 */

/** @typedef {{lastVar: string, misses: number, goods: number,
 *   busyNames: string[], sameBusyTicks: number, flaps: number,
 *   healthyStreak: number}} Next */

/** @typedef {{next: Next, setVar: string|null, notify: 'down'|'recovered'|'online'|'held'|null,
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
  let misses = external ? 0 : (prev.misses ?? 0);
  let goods = external ? 0 : (prev.goods ?? 0);
  let flaps = prev.flaps ?? 0;
  let healthyStreak = prev.healthyStreak ?? 0;
  const prevNames = prev.busyNames ?? [];

  const { runners, oldestQueuedMinutes } = observed;
  const queued = oldestQueuedMinutes !== null;
  const busyNames = runners
    .filter((r) => r.busy)
    .map((r) => r.name)
    .sort();
  const allBusy = runners.length > 0 && busyNames.length === runners.length;
  const sameNames =
    busyNames.length === prevNames.length &&
    busyNames.every((n, i) => n === prevNames[i]);
  const sameBusyTicks =
    queued && allBusy && sameNames ? (prev.sameBusyTicks ?? 0) + 1 : 0;

  if (current !== SELF_HOSTED && current !== FALLBACK) {
    // Manual hold: leave the variable alone, alert once per new value.
    return {
      next: {
        lastVar: current,
        misses: 0,
        goods: 0,
        busyNames,
        sameBusyTicks: 0,
        flaps,
        healthyStreak: 0,
      },
      setVar: null,
      notify: prev.lastVar !== current ? "held" : null,
      rerunStuck: false,
    };
  }

  if (current !== SELF_HOSTED) healthyStreak = 0;

  const unhealthy =
    runners.length === 0 ||
    (queued &&
      oldestQueuedMinutes > QUEUE_LIMIT_MINUTES &&
      runners.some((r) => !r.busy)) ||
    sameBusyTicks >= HUNG_TICKS;

  if (unhealthy) {
    misses += 1;
    goods = 0;
    healthyStreak = 0;
  } else if (current === FALLBACK && allBusy) {
    // Neutral: the supervisor keeps idle slots, so all-busy is not recovery.
  } else {
    goods += 1;
    misses = 0;
    if (current === SELF_HOSTED) healthyStreak += 1;
    if (healthyStreak >= STABLE_TICKS) flaps = 0;
  }

  const needGoods =
    flaps >= 1 ? 2 * 2 ** Math.min(flaps - 1, RECOVERY_BACKOFF_CAP) : 2;
  let setVar = null;
  let notify = null;
  let rerunStuck = false;
  if (unhealthy && misses >= 2 && current === SELF_HOSTED) {
    setVar = FALLBACK;
    notify = "down";
    rerunStuck = true;
    flaps += 1;
  } else if (!unhealthy && goods >= needGoods && current === FALLBACK) {
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
      flaps,
      healthyStreak,
    },
    setVar,
    notify,
    rerunStuck,
  };
}
