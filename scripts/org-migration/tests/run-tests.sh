#!/usr/bin/env bash
# Run every test-*.sh in this directory; exit non-zero if any fails.
set -uo pipefail
# The full suite runs in CI only (Andrew, 2026-10-22); run one test-*.sh locally.
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "run-tests.sh: the full suite runs in CI only. Run one test-*.sh, or push." >&2
  exit 3
fi
unset CDPATH
dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "${dir}"/test-*.sh; do
  echo "== ${t##*/}"
  if ! bash "${t}"; then fail=1; fi
done
exit "${fail}"
