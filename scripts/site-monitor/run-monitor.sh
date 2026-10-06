#!/usr/bin/env bash
# Production-site monitor (dev-env#193). Env vars and alert transitions: docs/runbooks/site-monitor-ntfy.md.
set -uo pipefail
unset CDPATH

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITES_FILE="${SITES_FILE:-${HERE}/sites.json}"
MONITOR_REPO="${MONITOR_REPO:-smartwatermelon/dev-env}"
RUN_URL="${RUN_URL-}"
BASELINE_CHECK="${BASELINE_CHECK-}"
NOW="${MONITOR_NOW:-$(date +%s)}"

MARKER='<!-- site-monitor:v1 -->'
LABEL='site-down'
ASSIGNEE='twistedmelonman'
CHECK_NAME='netlify-site-checks / site-check'
CHECK_NAME_QUERY='netlify-site-checks%20%2F%20site-check'
REMIND_AFTER=$((6 * 60 * 60))
NTFY_BASE='https://ntfy.sh'

faults=0
fault() {
  echo "::error::site-monitor: $*" >&2
  faults=$((faults + 1))
}

# printf %(...)T is a bash builtin, so this works the same on GNU and BSD date. It formats in local time, hence TZ.
export TZ=UTC
# fault plus the first 300 bytes of the last captured stderr.
fault_err() {
  local e=""
  e="$(head -c 300 "${work}/err")"
  fault "$1: ${e}"
}

iso() { printf '%(%Y-%m-%dT%H:%M:%SZ)T' "$1"; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

if [[ -z "${BASELINE_CHECK}" || ! -f "${BASELINE_CHECK}" ]]; then
  echo "site-monitor: BASELINE_CHECK does not name a file; cannot check any site" >&2
  exit 2
fi
if ! jq -e 'type == "array" and length > 0 and all(.[]; (.url | type) == "string" and (.repo | type) == "string")' \
  "${SITES_FILE}" >/dev/null 2>&1; then
  echo "site-monitor: ${SITES_FILE} is not a non-empty array of {url, repo}" >&2
  exit 2
fi

# Each failure is a key (for set comparison), a short name (for titles), and a Markdown section (for the body).
keys=()
names=()
sections=()
unread=()

# 1. Production URLs
urls="$(jq -r '.[].url' "${SITES_FILE}")" || exit 2
while IFS= read -r url; do
  out="$(bash "${BASELINE_CHECK}" "${url}" 2>&1)"
  rc=$?
  printf '%s\n' "${out}"
  if [[ "${rc}" -ne 0 ]]; then
    keys+=("site:${url}")
    names+=("${url#https://}")
    sections+=("$(printf "### %s: baseline check failed (exit %s)\n\n\`\`\`text\n%s\n\`\`\`" "${url}" "${rc}" "${out}")")
  fi
done <<<"${urls}"

# 2. Latest site-check run on each default branch
repos="$(jq -r '[.[].repo] | unique | .[]' "${SITES_FILE}")" || exit 2
while IFS= read -r nwo; do
  owner="${nwo%%/*}"
  var="MONITOR_TOKEN_${owner^^}"
  var="${var//-/_}"
  token="${!var-}"
  if [[ -z "${token}" ]]; then
    fault "${var} is empty; cannot read check-runs for ${nwo}"
    unread+=("${nwo}")
    continue
  fi
  if ! repo_json="$(GH_TOKEN="${token}" gh api "repos/${nwo}" 2>"${work}/err")"; then
    fault_err "could not read ${nwo}"
    unread+=("${nwo}")
    continue
  fi
  branch="$(jq -r '.default_branch // empty' <<<"${repo_json}")"
  if [[ -z "${branch}" ]]; then
    fault "${nwo} reported no default branch"
    unread+=("${nwo}")
    continue
  fi
  if ! runs="$(GH_TOKEN="${token}" gh api \
    "repos/${nwo}/commits/${branch}/check-runs?check_name=${CHECK_NAME_QUERY}&per_page=100" 2>"${work}/err")"; then
    fault_err "could not read check-runs for ${nwo}@${branch}"
    unread+=("${nwo}")
    continue
  fi
  # No Checks permission returns HTTP 200 with check_runs nulled. That is a fault, not "absent".
  if ! latest="$(jq -er --arg n "${CHECK_NAME}" '
      if (.check_runs | type) != "array" then error("check_runs is not an array") else . end
      | [.check_runs[] | select(.name == $n)] | sort_by(.started_at // "") | last
      | if . == null then "absent" else [.status, (.conclusion // ""), (.html_url // "")] | join("\t") end
    ' <<<"${runs}" 2>"${work}/err")"; then
    fault_err "unreadable check-runs payload for ${nwo}@${branch}"
    unread+=("${nwo}")
    continue
  fi
  if [[ "${latest}" == "absent" ]]; then
    echo "check: ${nwo}@${branch}: no ${CHECK_NAME} run (not alerting)"
    continue
  fi
  IFS=$'\t' read -r status conclusion html_url <<<"${latest}"
  echo "check: ${nwo}@${branch}: ${status} ${conclusion}"
  case "${status}:${conclusion}" in
    completed:failure | completed:timed_out | completed:cancelled | completed:startup_failure)
      keys+=("check:${nwo}")
      names+=("${nwo#*/} site-check")
      sections+=("$(printf "### %s: \`%s\` concluded \`%s\`\n\nDefault branch \`%s\`. Run: %s" \
        "${nwo}" "${CHECK_NAME}" "${conclusion}" "${branch}" "${html_url}")")
      ;;
    *) ;;
  esac
done <<<"${repos}"

# 3. Find the open alert issue
# A label listing, not a search: no index lag, and the marker is verified in each body.
if ! open_json="$(gh issue list --repo "${MONITOR_REPO}" --state open --label "${LABEL}" --limit 50 \
  --json number,body,url 2>"${work}/err")"; then
  list_err="$(head -c 300 "${work}/err")"
  echo "site-monitor: could not list ${LABEL} issues in ${MONITOR_REPO}: ${list_err}" >&2
  echo "site-monitor: refusing to continue; creating an issue now could duplicate the existing alert" >&2
  exit 1
fi
issue_number="" issue_url="" issue_body=""
if ! found="$(jq -ec --arg m "${MARKER}" '[.[] | select(.body | contains($m))] | first // {}' <<<"${open_json}")"; then
  echo "site-monitor: unreadable issue listing from ${MONITOR_REPO}" >&2
  exit 1
fi
issue_number="$(jq -r '.number // empty' <<<"${found}")"
issue_url="$(jq -r '.url // empty' <<<"${found}")"
issue_body="$(jq -r '.body // empty' <<<"${found}")"

prev_set="$(sed -n 's/^<!-- site-monitor:failing=\(.*\) -->$/\1/p' <<<"${issue_body}" | head -n 1)"
prev_ping="$(sed -n 's/^<!-- site-monitor:last-ping=\([0-9]*\) -->$/\1/p' <<<"${issue_body}" | head -n 1)"
prev_ping="${prev_ping:-0}"

# An unreadable check keeps its failing state from the last run, so a fault never reads as a recovery or a change.
for nwo in "${unread[@]}"; do
  if [[ " ${prev_set} " == *" check:${nwo} "* ]]; then
    keys+=("check:${nwo}")
    names+=("${nwo#*/} site-check")
    sections+=("### ${nwo}: site-check unreadable this run; still failing as of the last readable run")
  fi
done

failing_set=""
if [[ ${#keys[@]} -gt 0 ]]; then
  failing_set="$(printf '%s\n' "${keys[@]}" | sort | paste -sd ' ' -)"
fi

# 4. ntfy
# The topic is the secret. It goes only in the URL; curl output is discarded so no error can echo it.
notify() { # <priority> <tags> <title> <message>
  [[ -n "${NTFY_TOPIC-}" ]] || return 1
  printf '%s' "$4" | curl -fsS --max-time 20 --retry 2 \
    -H "Title: $3" -H "Priority: $1" -H "Tags: $2" -H "Click: ${issue_url:-${RUN_URL}}" \
    --data-binary @- "${NTFY_BASE}/${NTFY_TOPIC}" >/dev/null 2>&1
}
ntfy_ok=1
[[ -n "${NTFY_TOPIC-}" ]] || ntfy_ok=0
send() {
  if [[ "${ntfy_ok}" -eq 0 ]]; then
    fault "NTFY_TOPIC is empty; the alert '$3' was NOT sent. See docs/runbooks/site-monitor-ntfy.md"
    return 1
  fi
  if ! notify "$@"; then
    fault "ntfy delivery failed for '$3'"
    return 1
  fi
  echo "ntfy: sent priority $1: $3"
}

# 5. Transitions
summary="$(IFS=','; echo "${names[*]}")"
summary="${summary//,/, }"
checked="$(iso "${NOW}")"
run_line=""
[[ -n "${RUN_URL}" ]] && run_line=" ([run](${RUN_URL}))"

render_body() { # <last-ping epoch>
  local ping="$1" ping_text="never"
  [[ "${ping}" -gt 0 ]] && ping_text="$(iso "${ping}")"
  printf '%s\n<!-- site-monitor:failing=%s -->\n<!-- site-monitor:last-ping=%s -->\n\n' "${MARKER}" "${failing_set}" "${ping}"
  printf '## Production sites failing\n\n'
  printf "Written by \`.github/workflows/site-monitor.yml\`. The monitor closes this issue when every check passes.\n\n"
  printf -- '- Last checked: %s%s\n- Last ntfy alert: %s\n\n' "${checked}" "${run_line}" "${ping_text}"
  printf '%s\n\n' "${sections[@]}"
}

write_issue() { # <last-ping epoch>
  local title="site-monitor: ${#keys[@]} failing: ${summary}"
  render_body "$1" >"${work}/body.md"
  if [[ -n "${issue_number}" ]]; then
    if ! gh issue edit "${issue_number}" --repo "${MONITOR_REPO}" --title "${title}" \
      --body-file "${work}/body.md" >/dev/null 2>"${work}/err"; then
      fault_err "could not update ${MONITOR_REPO}#${issue_number}"
      return 1
    fi
    echo "issue: updated ${issue_url}"
    return 0
  fi
  # issue create --label fails outright when the label does not exist. --force makes this idempotent.
  if ! gh label create "${LABEL}" --repo "${MONITOR_REPO}" --color B60205 \
    --description "A production site is failing (site-monitor)" --force >/dev/null 2>"${work}/err"; then
    fault_err "could not ensure the ${LABEL} label"
  fi
  if ! issue_url="$(gh issue create --repo "${MONITOR_REPO}" --title "${title}" --label "${LABEL}" \
    --assignee "${ASSIGNEE}" --body-file "${work}/body.md" 2>"${work}/err")" || [[ -z "${issue_url}" ]]; then
    fault_err "could not open the alert issue in ${MONITOR_REPO}"
    issue_url=""
    return 1
  fi
  issue_number="${issue_url##*/}"
  echo "issue: opened ${issue_url}"
}

message="Failing: ${summary}"
if [[ ${#keys[@]} -gt 0 ]]; then
  title=""
  if [[ -z "${issue_number}" ]]; then
    title="Site down: ${summary}"
  elif [[ "${failing_set}" != "${prev_set}" ]]; then
    title="Site failures changed: ${summary}"
  elif ((NOW - prev_ping >= REMIND_AFTER)); then
    title="Still down: ${summary}"
  fi
  if [[ -z "${title}" ]]; then
    write_issue "${prev_ping}"
    echo "ntfy: same failing set, last alert under 6h ago; not re-sending"
  else
    # The issue is written first so the push can link it. The clock advances only after a push is delivered.
    write_issue "${prev_ping}"
    if send 5 rotating_light "${title}" "${message}" && [[ -n "${issue_number}" ]]; then
      write_issue "${NOW}"
    fi
  fi
elif [[ -n "${issue_number}" && "${faults}" -gt 0 ]]; then
  echo "site-monitor: ${faults} fault(s) this run; leaving the alert issue open rather than calling it a recovery"
elif [[ -n "${issue_number}" ]]; then
  if gh issue close "${issue_number}" --repo "${MONITOR_REPO}" \
    --comment "Recovered: every site and site-check passes as of ${checked}${run_line}." >/dev/null 2>"${work}/err"; then
    echo "issue: closed ${issue_url}"
  else
    fault_err "could not close ${MONITOR_REPO}#${issue_number}"
  fi
  send 3 white_check_mark "Sites recovered" "All production sites pass again."
else
  echo "all sites OK; no open alert issue"
fi

# A monitor that cannot alert must not report success, even on a green run.
if [[ "${ntfy_ok}" -eq 0 && "${faults}" -eq 0 ]]; then
  fault "NTFY_TOPIC is empty; this monitor cannot alert anyone. See docs/runbooks/site-monitor-ntfy.md"
fi

if [[ ${#keys[@]} -gt 0 ]]; then
  echo "::error::site-monitor: ${#keys[@]} failing: ${summary}" >&2
  exit 1
fi
[[ "${faults}" -eq 0 ]] || exit 1
exit 0
