#!/bin/bash
# Install or refresh agentro, as root. Safe to re-run. Runbook: docs/runbooks/agent-ro.md
#   install.sh --pubkey FILE ... [--from CIDR]
set -uo pipefail
unset CDPATH

ID_BIN="${ID_BIN:-/usr/bin/id}"
SYSADMINCTL_BIN="${SYSADMINCTL_BIN:-/usr/sbin/sysadminctl}"
DSCL_BIN="${DSCL_BIN:-/usr/bin/dscl}"
DSEDITGROUP_BIN="${DSEDITGROUP_BIN:-/usr/sbin/dseditgroup}"
CREATEHOMEDIR_BIN="${CREATEHOMEDIR_BIN:-/usr/sbin/createhomedir}"
INSTALL_BIN="${INSTALL_BIN:-/usr/bin/install}"
CHOWN_BIN="${CHOWN_BIN:-/usr/sbin/chown}"
VISUDO_BIN="${VISUDO_BIN:-/usr/sbin/visudo}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
SUDO_BIN="${SUDO_BIN:-/usr/bin/sudo}"
RM_BIN="${RM_BIN:-/bin/rm}"
OPENSSL_BIN="${OPENSSL_BIN:-/usr/bin/openssl}"
STAT_BIN="${STAT_BIN:-/usr/bin/stat}"
SLEEP_BIN="${SLEEP_BIN:-/bin/sleep}"
INSTALL_ROOT="${INSTALL_ROOT:-}"
INSTALL_ROOT="${INSTALL_ROOT%/}"

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/config.sh
. "${HERE}/config.sh" || exit 1

U="${AGENT_RO_USER}"
OWNER="${AGENT_RO_OWNER}"
UHOME="/Users/${U}"
LIBEXEC="${INSTALL_ROOT}${AGENT_RO_LIBEXEC}"
SUDOERS="${INSTALL_ROOT}${AGENT_RO_SUDOERS}"
SUDOERS_MAIN="${INSTALL_ROOT}/etc/sudoers"
SSHD_CONF="${INSTALL_ROOT}${AGENT_RO_SSHD_CONF}"
KEYS_DIR="${INSTALL_ROOT}${AGENT_RO_KEYS_DIR}"
PLIST="${INSTALL_ROOT}${AGENT_RO_PLIST}"
UHOME_P="${INSTALL_ROOT}${UHOME}"

die() {
  echo "install: $*" >&2
  exit 1
}
say() { echo "install: $*"; }

# ─── arguments ──────────────────────────────────────────────────────────
pubkeys=()
from=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pubkey)
      [[ $# -ge 2 ]] || die "--pubkey needs a file"
      pubkeys+=("$2")
      shift 2
      ;;
    --from)
      [[ $# -ge 2 ]] || die "--from needs a pattern list"
      from="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,3p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
# sshd from= patterns: addresses, CIDRs, wildcards and negation only. No quotes,
# so the value cannot break out of the option.
if [[ -n "${from}" && ! "${from}" =~ ^[0-9A-Fa-f.:/*?!,]+$ ]]; then
  die "--from allows only addresses, CIDR, * ? ! and commas: ${from}"
fi
[[ -z "${from}" || ${#pubkeys[@]} -gt 0 ]] || die "--from needs --pubkey (it applies to the keys given)"

# ─── preconditions ──────────────────────────────────────────────────────
uid="$("${ID_BIN}" -u)" || exit 1
[[ "${uid}" == "0" ]] || die "run as root (sudo)"
"${ID_BIN}" -u "${OWNER}" >/dev/null 2>&1 || die "no user ${OWNER}"
grep -Eq '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers.d' "${SUDOERS_MAIN}" ||
  die "${SUDOERS_MAIN} does not include sudoers.d"
[[ -x "${AGENT_RO_CONTAINER}" ]] || say "warning: ${AGENT_RO_CONTAINER} not found; gate container verbs will fail on this host"

# The gate runs as root, so no one but root may change it or any folder above it.
check_root_owned() {
  local p="$1" st
  while [[ -n "${p}" && "${p}" != "/" ]]; do
    if [[ -e "${INSTALL_ROOT}${p}" ]]; then
      st="$("${STAT_BIN}" -f '%u %Lp' "${INSTALL_ROOT}${p}")" || die "cannot stat ${p}"
      [[ "${st%% *}" == "0" ]] || die "${p} is not owned by root; the gate would not be safe there"
      # Group or other write bit set: someone else could swap the gate.
      case "${st##* }" in
        *[2367][0-7] | *[0-7][2367]) die "${p} is writable by group or others (mode ${st##* })" ;;
        *) ;;
      esac
    fi
    p="${p%/*}"
  done
}
check_root_owned "${AGENT_RO_LIBEXEC}"

# ─── 1. account ─────────────────────────────────────────────────────────
if ! "${ID_BIN}" "${U}" >/dev/null 2>&1; then
  # sysadminctl needs a password; nobody keeps this one, and sshd refuses passwords for agentro.
  pw="$("${OPENSSL_BIN}" rand -base64 32)" || die "cannot make a password"
  "${SYSADMINCTL_BIN}" -addUser "${U}" -fullName "${AGENT_RO_REALNAME}" -shell /bin/bash \
    -home "${UHOME}" -password "${pw}" || die "sysadminctl -addUser failed"
  unset pw
  say "created user ${U}"
fi
uuid="$("${ID_BIN}" -u "${U}")" || die "cannot read uid of ${U}"
[[ "${uuid}" =~ ^[0-9]+$ ]] || die "bad uid for ${U}: ${uuid}"

adm="$("${DSEDITGROUP_BIN}" -o checkmember -m "${U}" admin 2>&1)" || true
case "${adm}" in
  no*) ;;
  yes*) die "${U} is an admin; remove it from admin by hand, then re-run" ;;
  *) die "cannot check admin membership of ${U}: ${adm}" ;;
esac

# Own primary group: in staff, the account could read every staff-readable
# file of every user (spike 1). GID = UID when free.
if ! "${DSCL_BIN}" . -read "/Groups/${U}" >/dev/null 2>&1; then
  groups="$("${DSCL_BIN}" . -list /Groups PrimaryGroupID)" || die "cannot list groups"
  taken="$(printf '%s\n' "${groups}" | awk -v g="${uuid}" '$2 == g {print $1}')"
  [[ -z "${taken}" ]] || die "GID ${uuid} is taken by ${taken}; create group ${U} by hand"
  "${DSEDITGROUP_BIN}" -o create -i "${uuid}" -r "${AGENT_RO_REALNAME}" "${U}" || die "cannot create group ${U}"
fi
grec="$("${DSCL_BIN}" . -read "/Groups/${U}" PrimaryGroupID)" || die "cannot read group ${U}"
gid="${grec##* }"
[[ "${gid}" =~ ^[0-9]+$ && "${gid}" != "20" ]] || die "bad GID for group ${U}: ${grec}"
"${DSCL_BIN}" . -create "/Users/${U}" PrimaryGroupID "${gid}" || die "cannot set primary group"
"${DSCL_BIN}" . -create "/Users/${U}" UserShell /bin/bash || die "cannot set shell"
"${DSCL_BIN}" . -create "/Users/${U}" IsHidden 1 || die "cannot hide ${U}"
if "${DSCL_BIN}" . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
  "${DSEDITGROUP_BIN}" -o edit -a "${U}" -t user com.apple.access_ssh || die "cannot allow ${U} in Remote Login"
fi
# Never chown -R: an owner file hard-linked into agentro's home would become agentro's.
if [[ ! -d "${UHOME_P}" ]]; then
  "${CREATEHOMEDIR_BIN}" -c -u "${U}" >/dev/null || die "cannot create ${UHOME}"
  "${CHOWN_BIN}" "${U}:${U}" "${UHOME_P}" || die "cannot chown ${UHOME}"
fi

# git refuses repos another user owns unless they are listed as safe.
work="$(mktemp -d "${TMPDIR:-/tmp}/agent-ro-install.XXXXXX")" || die "cannot make a temp folder"
# Keys go live last. Any exit before success removes them, so a half-done install takes no logins.
installed=0
on_exit() {
  if [[ "${installed}" != 1 && -e "${KEYS_DIR}/authorized_keys" ]]; then
    "${RM_BIN}" -f "${KEYS_DIR}/authorized_keys"
    echo "install: removed ${AGENT_RO_KEYS_DIR}/authorized_keys; fix the error, then re-run with --pubkey" >&2
  fi
  "${RM_BIN}" -f "${work:?}"/* 2>/dev/null
  rmdir "${work}" 2>/dev/null
}
trap on_exit EXIT
printf '[safe]\n\tdirectory = *\n' >"${work}/gitconfig"
"${INSTALL_BIN}" -o root -g wheel -m 0644 "${work}/gitconfig" "${UHOME_P}/.gitconfig" || die "cannot write ${UHOME}/.gitconfig"

# ─── 2. root-owned programs ─────────────────────────────────────────────
"${INSTALL_BIN}" -d -o root -g wheel -m 0755 "${LIBEXEC}" || die "cannot create ${LIBEXEC}"
"${INSTALL_BIN}" -o root -g wheel -m 0755 "${HERE}/gate.sh" "${LIBEXEC}/gate" || die "cannot install gate"
"${INSTALL_BIN}" -o root -g wheel -m 0755 "${HERE}/sweep.sh" "${LIBEXEC}/sweep.sh" || die "cannot install sweep"
"${INSTALL_BIN}" -o root -g wheel -m 0644 "${HERE}/config.sh" "${LIBEXEC}/config.sh" || die "cannot install config"

# ─── 3. keys: checked now, installed after the self-test (step 8) ──────
"${INSTALL_BIN}" -d -o root -g wheel -m 0755 "${KEYS_DIR}" || die "cannot create ${KEYS_DIR}"
if [[ ${#pubkeys[@]} -gt 0 ]]; then
  opts="restrict"
  [[ -z "${from}" ]] || opts="restrict,from=\"${from}\""
  : >"${work}/authorized_keys"
  for f in "${pubkeys[@]}"; do
    [[ -f "${f}" ]] || die "no such key file: ${f}"
    n="$(grep -cv '^[[:space:]]*$' "${f}")"
    [[ "${n}" == "1" ]] || die "${f} must hold exactly one public key (found ${n} lines)"
    key="$(grep -v '^[[:space:]]*$' "${f}")"
    [[ "${key}" =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)\ [A-Za-z0-9+/=]+(\ [^\"]*)?$ ]] ||
      die "${f} is not a plain public key line (options are added by this script)"
    printf '%s %s\n' "${opts}" "${key}" >>"${work}/authorized_keys"
  done
elif [[ ! -f "${KEYS_DIR}/authorized_keys" ]]; then
  say "warning: no keys installed yet; re-run with --pubkey"
fi

# ─── 4. sshd: key only, no forwarding, no TTY, keys from the root-owned list ──
cat >"${work}/sshd.conf" <<EOF
# Installed by dev-env scripts/agent-ro/install.sh. Do not edit by hand.
Match User ${U}
	AuthorizedKeysFile ${AGENT_RO_KEYS_DIR}/authorized_keys
	AuthenticationMethods publickey
	PasswordAuthentication no
	KbdInteractiveAuthentication no
	DisableForwarding yes
	PermitTTY no
	PermitUserRC no
# End the Match so later lines of the main sshd_config stay global.
Match all
EOF
ctx_owner="user=${OWNER},host=localhost,addr=127.0.0.1"
ctx_agent="user=${U},host=localhost,addr=127.0.0.1"
before="$("${SSHD_BIN}" -T -C "${ctx_owner}" 2>&1)" || die "sshd -T fails before any change: ${before}"
"${INSTALL_BIN}" -o root -g wheel -m 0644 "${work}/sshd.conf" "${SSHD_CONF}" || die "cannot install ${SSHD_CONF}"
# macOS starts sshd per connection, so a bad file breaks the next login: check
# it at once, and remove it on any doubt.
undo_sshd() {
  "${RM_BIN}" -f "${SSHD_CONF}"
  die "$1 (removed ${AGENT_RO_SSHD_CONF})"
}
check="$("${SSHD_BIN}" -t 2>&1)" || undo_sshd "sshd -t rejects the config: ${check}"
after="$("${SSHD_BIN}" -T -C "${ctx_owner}" 2>&1)" || undo_sshd "sshd -T fails: ${after}"
[[ "${before}" == "${after}" ]] || undo_sshd "the drop-in changed settings for ${OWNER}"
agent="$("${SSHD_BIN}" -T -C "${ctx_agent}" 2>&1)" || undo_sshd "sshd -T for ${U} fails: ${agent}"
for want in "permittty no" "passwordauthentication no" "disableforwarding yes" "authenticationmethods publickey" "authorizedkeysfile ${AGENT_RO_KEYS_DIR}/authorized_keys"; do
  grep -qx "${want}" <<<"${agent}" || undo_sshd "sshd does not apply '${want}' to ${U}"
done

# ─── 5. sudo: the gate only ─────────────────────────────────────────────
cat >"${work}/sudoers" <<EOF
# Installed by dev-env scripts/agent-ro/install.sh. Do not edit by hand.
Defaults:${U} env_reset
${U} ALL=(root) NOPASSWD: ${AGENT_RO_LIBEXEC}/gate
EOF
"${VISUDO_BIN}" -cf "${work}/sudoers" >/dev/null || die "visudo rejects the sudoers fragment"
"${INSTALL_BIN}" -o root -g wheel -m 0440 "${work}/sudoers" "${SUDOERS}" || die "cannot install ${SUDOERS}"

# ─── 6. ACLs now, then the sweep job ────────────────────────────────────
say "applying read ACLs to ${AGENT_RO_OWNER_HOME} (about 1-3 minutes)"
# Exit 4: every deny applied; only allow-pass entries failed (TCC folders). Anything else may lack denies.
sweep_rc=0
"${SUDO_BIN}" -u "${OWNER}" /bin/bash "${LIBEXEC}/sweep.sh" --full || sweep_rc=$?
case "${sweep_rc}" in
  0) ;;
  4) say "warning: the allow pass failed on some entries; denies applied. See ${AGENT_RO_LOG} and ${AGENT_RO_STATE_DIR}/last-errors" ;;
  *) die "the sweep failed (exit ${sweep_rc}); see ${AGENT_RO_LOG} and ${AGENT_RO_STATE_DIR}/last-errors" ;;
esac
"${INSTALL_BIN}" -o root -g wheel -m 0644 "${HERE}/${AGENT_RO_LABEL}.plist" "${PLIST}" || die "cannot install ${PLIST}"
"${LAUNCHCTL_BIN}" bootout "system/${AGENT_RO_LABEL}" >/dev/null 2>&1 || true
# bootout returns while a running sweep drains; an early bootstrap fails with 5.
for ((i = 0; i < 120; i += 1)); do
  "${LAUNCHCTL_BIN}" print "system/${AGENT_RO_LABEL}" >/dev/null 2>&1 || break
  "${SLEEP_BIN}" 1
done
"${LAUNCHCTL_BIN}" bootstrap system "${PLIST}" || die "cannot load ${AGENT_RO_LABEL}; re-run install.sh"

# ─── 7. self-test, as agentro ───────────────────────────────────────────
fail=0
expect() {
  local want="$1" name="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=denied; fi
  if [[ "${got}" == "${want}" ]]; then
    say "PASS ${name}: ${got}"
  else
    say "FAIL ${name}: ${got}, want ${want}"
    fail=1
  fi
}
as_u() { "${SUDO_BIN}" -u "${U}" "$@"; }
expect ok "list ${AGENT_RO_OWNER_HOME}" as_u /bin/ls "${AGENT_RO_OWNER_HOME}"
for rel in "${AGENT_RO_DENY[@]}"; do
  p="${AGENT_RO_OWNER_HOME}/${rel}"
  if [[ -d "${INSTALL_ROOT}${p}" ]]; then
    expect denied "list ${p}" as_u /bin/ls "${p}"
  elif [[ -f "${INSTALL_ROOT}${p}" ]]; then
    expect denied "read ${p}" as_u /bin/cat "${p}"
  else
    say "SKIP ${p}: not on this host"
  fi
done
expect denied "create a file in ${AGENT_RO_OWNER_HOME}" as_u /usr/bin/touch "${AGENT_RO_OWNER_HOME}/.agent-ro-selftest"
expect ok "gate help" as_u "${AGENT_RO_SUDO}" -n "${AGENT_RO_LIBEXEC}/gate" help
expect denied "sudo outside the gate" as_u "${AGENT_RO_SUDO}" -n /usr/bin/true
# The EXIT trap takes the keys away, so no agent logs in to an account that failed its test.
[[ "${fail}" == 0 ]] || die "self-test failed"

# ─── 8. keys live ───────────────────────────────────────────────────────
if [[ -f "${work}/authorized_keys" ]]; then
  "${INSTALL_BIN}" -o root -g wheel -m 0644 "${work}/authorized_keys" "${KEYS_DIR}/authorized_keys" ||
    die "cannot install authorized_keys"
  say "installed ${#pubkeys[@]} key(s)"
fi
installed=1
say "done. Next: add the client ssh alias (docs/runbooks/agent-ro.md)"
