# shellcheck shell=bash
# Result classification for smoke.sh. Sourced; no side effects.

# classify_block CODE: print open, blocked or error. Only curl exit 28 (timeout) is a pf drop.
classify_block() {
  case "$1" in
  0) echo open ;;
  28) echo blocked ;;
  *) echo error ;;
  esac
}
