#!/usr/bin/env bash
# Job VM entrypoint: take the JIT config from $NOS_JIT, clear it from the environment, start the runner.
set -euo pipefail

RUNNER_HOME="${RUNNER_HOME:-/home/runner}"
jit="${NOS_JIT:-}"
if [[ -z "${jit}" ]]; then
  echo "entrypoint: NOS_JIT is empty or unset; the supervisor must pass it with --env-file" >&2
  exit 2
fi
unset NOS_JIT
cd "${RUNNER_HOME}"
exec ./run.sh --jitconfig "${jit}"
