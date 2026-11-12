# shellcheck shell=bash
# Result classification for smoke.sh. Sourced; no side effects.

# classify_block CODE TCONNECT: print open, blocked, error.
# Blocked = curl exit 28 and time_connect 0. Later timeout = live host.
classify_block() {
  case "$1" in
  0) echo open ;;
  28)
    case "${2:-}" in
    0 | 0.000 | 0.000000) echo blocked ;;
    "") echo error ;;
    *) echo open ;;
    esac
    ;;
  *) echo error ;;
  esac
}
