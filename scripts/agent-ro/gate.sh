#!/bin/bash
# agentro's only sudo command: fixed-argv, read-only launchd, container and pf queries.
# Usage: sudo -n /usr/local/libexec/agent-ro/gate help
set -u
unset CDPATH
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

die() {
  echo "gate: $*" >&2
  exit 2
}

here="${BASH_SOURCE[0]%/*}"
[ "${here}" != "${BASH_SOURCE[0]}" ] || here="."
# shellcheck source=SCRIPTDIR/config.sh
. "${here}/config.sh" || die "cannot read ${here}/config.sh"

me=$("${AGENT_RO_ID}" -u) || die "cannot read uid"
[ "${me}" = "0" ] || die "run through sudo: sudo -n ${AGENT_RO_LIBEXEC}/gate <verb>"
ouid=$("${AGENT_RO_ID}" -u "${AGENT_RO_OWNER}") || die "no user ${AGENT_RO_OWNER}"
case "${ouid}" in '' | *[!0-9]*) die "bad uid for ${AGENT_RO_OWNER}: ${ouid}" ;; *) ;; esac

LABEL_RE='[A-Za-z0-9][A-Za-z0-9._-]*'

usage() {
  cat <<EOF
usage: sudo -n ${AGENT_RO_LIBEXEC}/gate <verb> [arg]
  launchctl-print <target>          target: system | gui/${ouid} | user/${ouid}, optionally /<label>
  launchctl-print-disabled <domain> domain: system | gui/${ouid} | user/${ouid}
  launchctl-list                    launchctl list, in ${AGENT_RO_OWNER}'s session
  container <what>                  what: ls | ls-all | image-ls | network-ls | system-status | system-property-list | version
  pfctl-show <what> [anchor]        what: rules | nat | states | info | anchors | tables
  help
EOF
}

# Run as the owner in his GUI session, clean env: container's XPC service answers only there.
as_owner() {
  # Start in /, not in a folder agentro controls.
  cd / || die "cannot cd /"
  exec "${AGENT_RO_LAUNCHCTL}" asuser "${ouid}" "${AGENT_RO_SUDO}" -n -u "${AGENT_RO_OWNER}" -- \
    "${AGENT_RO_ENV}" -i "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    "HOME=${AGENT_RO_OWNER_HOME}" "USER=${AGENT_RO_OWNER}" "LOGNAME=${AGENT_RO_OWNER}" "$@"
}

domain_ok() {
  case "$1" in
    system | "gui/${ouid}" | "user/${ouid}") return 0 ;;
    *) return 1 ;;
  esac
}

target_ok() {
  local t="$1" d l
  if domain_ok "${t}"; then return 0; fi
  d="${t%/*}"
  l="${t##*/}"
  domain_ok "${d}" || return 1
  [[ "${l}" =~ ^${LABEL_RE}$ ]]
}

[ "$#" -ge 1 ] || {
  usage >&2
  exit 2
}
verb="$1"
shift

case "${verb}" in
  help | -h | --help)
    [ "$#" -eq 0 ] || die "help takes no arguments"
    usage
    exit 0
    ;;
  launchctl-print)
    [ "$#" -eq 1 ] || die "launchctl-print takes one target"
    target_ok "$1" || die "target not allowed: $1"
    exec "${AGENT_RO_LAUNCHCTL}" print "$1"
    ;;
  launchctl-print-disabled)
    [ "$#" -eq 1 ] || die "launchctl-print-disabled takes one domain"
    domain_ok "$1" || die "domain not allowed: $1"
    exec "${AGENT_RO_LAUNCHCTL}" print-disabled "$1"
    ;;
  launchctl-list)
    [ "$#" -eq 0 ] || die "launchctl-list takes no arguments"
    as_owner "${AGENT_RO_LAUNCHCTL}" list
    ;;
  container)
    [ "$#" -eq 1 ] || die "container takes one of: ls ls-all image-ls network-ls system-status system-property-list version"
    case "$1" in
      ls) as_owner "${AGENT_RO_CONTAINER}" ls ;;
      ls-all) as_owner "${AGENT_RO_CONTAINER}" ls -a ;;
      image-ls) as_owner "${AGENT_RO_CONTAINER}" image ls ;;
      network-ls) as_owner "${AGENT_RO_CONTAINER}" network ls ;;
      system-status) as_owner "${AGENT_RO_CONTAINER}" system status ;;
      system-property-list) as_owner "${AGENT_RO_CONTAINER}" system property list ;;
      version) as_owner "${AGENT_RO_CONTAINER}" --version ;;
      *) die "container query not allowed: $1" ;;
    esac
    ;;
  pfctl-show)
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "pfctl-show takes <what> [anchor]"
    case "$1" in
      rules | nat | states | info | anchors | tables) ;;
      *) die "pfctl query not allowed: $1" ;;
    esac
    what="$1"
    [ "${what}" = anchors ] && what=Anchors
    [ "${what}" = tables ] && what=Tables
    if [ "$#" -eq 2 ]; then
      [[ "$2" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || die "anchor not allowed: $2"
      case "$2" in *..*) die "anchor not allowed: $2" ;; *) ;; esac
      exec "${AGENT_RO_PFCTL}" -a "$2" -s "${what}"
    fi
    exec "${AGENT_RO_PFCTL}" -s "${what}"
    ;;
  *)
    usage >&2
    die "verb not allowed: ${verb}"
    ;;
esac
