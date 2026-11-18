#!/bin/bash
# Guest entrypoint: read the JIT config from stdin (never argv), then run the runner for one job.
set -euo pipefail
jit="$(cat)"
if [[ -z "${jit}" ]]; then
  echo "run-job: JIT config on stdin is empty" >&2
  exit 2
fi
cd /Users/admin/actions-runner
exec ./run.sh --jitconfig "${jit}"
