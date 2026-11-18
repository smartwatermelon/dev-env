#!/usr/bin/env bash
# Run every test-*.sh in this directory; exit non-zero if any fails.
set -uo pipefail
unset CDPATH
dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "${dir}"/test-*.sh; do
  echo "== ${t##*/}"
  if ! bash "${t}"; then fail=1; fi
done
exit "${fail}"
