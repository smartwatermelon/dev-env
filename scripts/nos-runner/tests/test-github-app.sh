#!/usr/bin/env bash
# github-app.sh with stub security, openssl, curl and date: JWT shape, claims, token request, secret handling.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN NOS_TOKEN GITHUB_API_URL

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../github-app.sh"
WORK="${TMPDIR:-/tmp}/nos-runner-app-test-$$"
BIN="${WORK}/bin"
mkdir -p "${BIN}"
trap 'rm -rf "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }
check() {
  local name="$1"
  shift
  if "$@"; then _pass "${name}"; else _fail "${name}"; fi
}

KEYTEXT='STUBPRIVATEKEYTEXT'
BEARER='stub-bearer-7f3a'
T=1800000000

# security stub: prints the key base64-encoded, as the Keychain does.
cat >"${BIN}/security" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${WORK}/security.argv"
printf '%s' '${KEYTEXT}' | base64
STUB
# openssl stub: base64 is real; dgst reads the key path (and takes data as a file arg).
cat >"${BIN}/openssl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${WORK}/openssl.argv"
if [[ "\$1" == base64 ]]; then base64 | tr -d '\n'; exit 0; fi
if [[ "\$*" == *"-sign "* ]]; then
  keyfile=""
  prev=""
  for a in "\$@"; do
    if [[ "\${prev}" == -sign ]]; then keyfile="\${a}"; fi
    prev="\${a}"
  done
  cat "\${keyfile}" >"${WORK}/openssl.keyread"
  printf 'SIGNATURE'
fi
STUB
# curl stub: logs argv and stdin; replies with STUB_BODY and STUB_STATUS.
cat >"${BIN}/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${WORK}/curl.argv"
cat >>"${WORK}/curl.stdin"
default='{"token":"ghs_installtok"}'
printf '%s\n%s' "\${STUB_BODY:-\${default}}" "\${STUB_STATUS:-201}"
STUB
cat >"${BIN}/date" <<STUB
#!/usr/bin/env bash
echo ${T}
STUB
chmod +x "${BIN}"/*

export SECURITY_BIN="${BIN}/security" OPENSSL_BIN="${BIN}/openssl" CURL_BIN="${BIN}/curl" DATE_BIN="${BIN}/date"
source /dev/stdin <"${SCRIPT}"

b64url_decode() {
  local s="$1"
  s="$(printf '%s' "${s}" | tr '_-' '/+')"
  while [[ $((${#s} % 4)) -ne 0 ]]; do s="${s}="; done
  printf '%s' "${s}" | base64 -d
}

jwt="$(app_jwt 12345)"
IFS=. read -r h p s <<<"${jwt}"
hdr="$(b64url_decode "${h}")"
claims="$(b64url_decode "${p}")"

jwt_shape=1
[[ "${jwt}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ && "${hdr}" == *'"alg":"RS256"'* && -n "${s}" ]] && jwt_shape=0
claims_ok=1
[[ "${claims}" == *"\"iat\":$((T - 60))"* && "${claims}" == *"\"exp\":$((T + 540))"* && "${claims}" == *'"iss":"12345"'* ]] && claims_ok=0
keyread="$(cat "${WORK}/openssl.keyread")"
check "jwt_has_three_parts_and_rs256_header" test "${jwt_shape}" -eq 0
check "jwt_claims_iss_iat_exp" test "${claims_ok}" -eq 0
check "key_read_through_pipe" test "${keyread}" = "${KEYTEXT}"
key_in_argv=0
grep -q "${KEYTEXT}" "${WORK}"/*.argv || key_in_argv=1
check "key_never_in_argv" test "${key_in_argv}" -eq 1

tok="$(app_token 12345 678)"
check "token_value_parsed" test "${tok}" = ghs_installtok
check "token_request_is_post" grep -q -- '-X POST' "${WORK}/curl.argv"
check "token_request_url" grep -q 'https://api.github.com/app/installations/678/access_tokens' "${WORK}/curl.argv"
check "token_request_uses_jwt_bearer" grep -q "^Authorization: Bearer ${jwt}\$" "${WORK}/curl.stdin"

export NOS_TOKEN="${BEARER}"
rc=0
STUB_BODY='{"message":"Not Found"}' STUB_STATUS=404 gh_api GET /repos/x/y >/dev/null || rc=$?
check "gh_api_returns_1_on_404" test "${rc}" -eq 1
body="$(STUB_BODY='{"a":1}' STUB_STATUS=200 gh_api GET /x)"
check "gh_api_ok_prints_body" test "${body}" = '{"a":1}'
leak=0
grep -q -e "${BEARER}" -e "${jwt}" "${WORK}/curl.argv" && leak=1
check "auth_header_not_in_argv" test "${leak}" -eq 0
check "auth_header_on_stdin" grep -q "^Authorization: Bearer ${BEARER}\$" "${WORK}/curl.stdin"

exit "${fail}"
