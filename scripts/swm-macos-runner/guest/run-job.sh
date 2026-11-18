#!/bin/bash
# Guest entrypoint: read the JIT config from stdin (never argv), then run the runner for one job.
set -euo pipefail
# Jobs inherit this PATH. Homebrew first, as on macos-latest: else bash is 3.2
# and python3 is CLT 3.9.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
jit="$(cat)"
if [[ -z "${jit}" ]]; then
  echo "run-job: JIT config on stdin is empty" >&2
  exit 2
fi
cd "${SWM_RUNNER_DIR:-/Users/admin/actions-runner}"
exec ./run.sh --jitconfig "${jit}"
