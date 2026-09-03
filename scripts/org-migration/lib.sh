#!/usr/bin/env bash
# Shared helpers for the 2026-09 org migration scripts. Sourced, not run.
# Design: docs/superpowers/specs/2026-09-03-org-migration-design.md

# Every lookup goes through repos/smartwatermelon/<repo>. Before the rename
# that is the real path; after the rename GitHub redirects it to
# twistedmelonman/<repo>; after the transfer it is the real path again (or a
# redirect to nightowlstudiollc/cleanroom). One path, every state.
OM_LOOKUP_OWNER="smartwatermelon"

# Print "repo target" per non-comment line. Fail on a line that is not
# exactly two tab-separated fields.
om_read_move_list() {
  local file="$1" line repo target extra n=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    IFS=$'\t' read -r repo target extra <<<"${line}"
    if [[ -z "${repo}" || -z "${target}" || -n "${extra}" || "${repo}" == *" "* ]]; then
      echo "move-list: line ${n} is not 'repo<TAB>target': ${line}" >&2
      return 1
    fi
    printf '%s %s\n' "${repo}" "${target}"
  done <"${file}"
}

# Print "login type" for the repo's current owner. Non-zero on any failure.
om_lookup_owner() {
  local repo="$1"
  gh api "repos/${OM_LOOKUP_OWNER}/${repo}" --jq '.owner.login + " " + .owner.type'
}
