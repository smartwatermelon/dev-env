#!/usr/bin/env bash
# Sourced helpers: mint a GitHub App JWT and installation token; call the API. No secret reaches argv or logs.

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

# Base64url of stdin, no padding.
_b64url() {
  local raw
  raw="$("${OPENSSL_BIN:-openssl}" base64 -A)" || return 1
  raw="${raw//+/-}"
  raw="${raw//\//_}"
  printf '%s' "${raw//=/}"
}

# _pem KEY_B64: decode the key. A pipe, not a here-string (bash 3.2 writes those to a temp file).
_pem() { printf '%s' "$1" | "${BASE64_BIN:-base64}" -d; }

# _sign KEY_B64 DATA: raw RS256 signature on stdout. Key and data go to openssl as /dev/fd paths.
_sign() {
  "${OPENSSL_BIN:-openssl}" dgst -sha256 -sign <(_pem "$1" || true) <(printf '%s' "$2")
}

# app_jwt APP_ID: print an RS256 JWT (iat = now - 60, exp = now + 540).
# The key is Keychain base64 text and never touches a file.
app_jwt() {
  local app_id="$1" now hdr pl sig keyb64
  keyb64="$("${SECURITY_BIN:-security}" find-generic-password -s nos-runner-app-key -a nightowlstudiollc -w)" || return 1
  now="$("${DATE_BIN:-date}" +%s)" || return 1
  hdr="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | _b64url)" || return 1
  pl="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "${app_id}" | _b64url)" || return 1
  sig="$({ _sign "${keyb64}" "${hdr}.${pl}" || true; } | _b64url)" || return 1
  if [[ -z "${sig}" ]]; then
    echo "app_jwt: empty signature" >&2
    return 1
  fi
  printf '%s.%s.%s\n' "${hdr}" "${pl}" "${sig}"
}

# _api_call METHOD PATH BEARER [JSON_BODY]: header on stdin; prints body; returns 1 on non-2xx.
_api_call() {
  local method="$1" path="$2" bearer="$3" body="${4:-}" out code
  local args=(-sS --max-time 30 -X "${method}" -H @-
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28'
    -w '\n%{http_code}')
  if [[ -n "${body}" ]]; then args+=(--data "${body}"); fi
  out="$(printf 'Authorization: Bearer %s\n' "${bearer}" | "${CURL_BIN:-curl}" "${args[@]}" "${GITHUB_API_URL}${path}")" || return 1
  code="${out##*$'\n'}"
  if [[ "${out}" == *$'\n'* ]]; then out="${out%$'\n'*}"; else out=""; fi
  printf '%s\n' "${out}"
  [[ "${code}" =~ ^2[0-9][0-9]$ ]]
}

# gh_api METHOD PATH [JSON_BODY]: call the API with $NOS_TOKEN.
gh_api() {
  _api_call "$1" "$2" "${NOS_TOKEN:-}" "${3:-}"
}

# app_token APP_ID INSTALLATION_ID: print an installation access token.
app_token() {
  local jwt resp tok
  jwt="$(app_jwt "$1")" || return 1
  resp="$(_api_call POST "/app/installations/$2/access_tokens" "${jwt}")" || {
    echo "app_token: request failed: ${resp:0:200}" >&2
    return 1
  }
  tok="$(printf '%s' "${resp}" | "${JQ_BIN:-jq}" -er '.token')" || return 1
  printf '%s\n' "${tok}"
}
