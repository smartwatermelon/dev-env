// Runner pools the watchdog manages. Each pool has its own cron in wrangler.toml; scheduled() picks the pool by cron.

export const APPS = {
  nos: {
    idKey: "APP_ID",
    installKey: "INSTALLATION_ID",
    keyKey: "APP_KEY_PKCS8",
  },
  swm: {
    idKey: "SWM_APP_ID",
    installKey: "SWM_INSTALLATION_ID",
    keyKey: "SWM_APP_KEY_PKCS8",
  },
};

// NOS texts are the live alert texts, byte for byte; pool_nos_messages_unchanged and the index tests pin them.
const NOS_MESSAGES = {
  down: () =>
    "NOS runner down: NOS_RUNNER set to ubuntu-latest; stuck runs cancelled for re-run.",
  recovered: () => "NOS runner recovered: NOS_RUNNER set to mimolette.",
  online: () => "NOS runner online: NOS_RUNNER was unset, now mimolette.",
  held: (v) =>
    `NOS runner held: NOS_RUNNER=${v}; the watchdog leaves it alone.`,
  skip: (cls) => `watchdog skipping: ${cls}`,
  ok: "watchdog ok: ticks are running again.",
  drill: "NOS runner drill: watchdog alert path. No action needed.",
};

const MACOS_MESSAGES = {
  down: () =>
    "macOS runner: down. SWM_MACOS_RUNNER set to macos-latest; stuck runs cancelled for re-run.",
  recovered: () =>
    "macOS runner: recovered. SWM_MACOS_RUNNER set to mimolette-macos.",
  online: () =>
    "macOS runner: online. SWM_MACOS_RUNNER was unset, now mimolette-macos.",
  held: (v) =>
    `macOS runner: held. SWM_MACOS_RUNNER=${v}; the watchdog leaves it alone.`,
  skip: (cls) => `macOS runner: watchdog skipping: ${cls}`,
  ok: "macOS runner: watchdog ok: ticks are running again.",
  drill: "macOS runner: drill of the watchdog alert path. No action needed.",
};

export const POOLS = {
  nos: {
    id: "nos",
    app: "nos",
    org: "nightowlstudiollc",
    variable: "NOS_RUNNER",
    label: "mimolette",
    fallback: "ubuntu-latest",
    visibility: "private",
    prefix: "",
    cron: "*/10 * * * *",
    rerunLost: false,
    messages: NOS_MESSAGES,
  },
  swmMacos: {
    id: "swm-macos",
    app: "swm",
    org: "smartwatermelon",
    variable: "SWM_MACOS_RUNNER",
    label: "mimolette-macos",
    fallback: "macos-latest",
    visibility: "all",
    prefix: "swm-macos:",
    cron: "5,15,25,35,45,55 * * * *",
    rerunLost: true,
    messages: MACOS_MESSAGES,
  },
};

/** Pool for a cron string. A missing cron is NOS (manual invocation); an unknown cron is null. */
export function poolForCron(cron) {
  if (cron === undefined || cron === null) return POOLS.nos;
  return Object.values(POOLS).find((p) => p.cron === cron) ?? null;
}

/** The pool's App credentials as {APP_ID, INSTALLATION_ID, APP_KEY_PKCS8}, or null unless all three are non-empty. */
export function appEnv(env, pool) {
  const a = APPS[pool.app];
  const out = {
    APP_ID: env[a.idKey],
    INSTALLATION_ID: env[a.installKey],
    APP_KEY_PKCS8: env[a.keyKey],
  };
  return Object.values(out).every((v) => typeof v === "string" && v !== "")
    ? out
    : null;
}
