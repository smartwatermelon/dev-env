#!/bin/bash
# Sourced by supervisor.sh: defaults; each value can be overridden from the environment.

_nos_conf_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${NOS_ORG:=nightowlstudiollc}"
: "${NOS_SLOTS:=2}"
: "${NOS_CPUS:=4}"
: "${NOS_MEMORY:=4g}"
: "${NOS_MIN_FREE_GB:=20}"
: "${NOS_LABEL:=mimolette}"
: "${NOS_APP_ID:=5703224}"
: "${NOS_INSTALLATION_ID:=180668548}"
: "${NOS_INTERVAL:=30}"
: "${NOS_CONTAINER_TIMEOUT:=60}"

# Worst-case seconds from SIGTERM to exit. Task 5 sets the plist ExitTimeOut above this.
: "${NOS_SHUTDOWN_MAX_S:=1030}"

# 1030 s = rest of the pass in progress 470 (2 idle stops x 150 + NOS_RUNNER 110 + 2 DELETEs 60) + shutdown 560.

# Shutdown: token 30 + NOS_RUNNER GET/PATCH/POST 90 + ntfy 20 + ls 60 + 2 slots x (GET 30 + stop 60 + ls 60 + DELETE 30).

# curl calls cap at 30 s (ntfy 20 s) and container calls at 60 s. A normal shutdown takes a few seconds.
: "${NOS_STATE_DIR:=${HOME}/.local/state/nos-runner}"
: "${NOS_PF_OK_FILE:=/var/run/nos-runner-pf.ok}"
: "${NOS_DISK_PATH:=${HOME}}"
: "${NTFY_BASE:=https://ntfy.sh}"

# The image tag follows the runner version pinned in the Containerfile, so a bump there cannot drift from here.
if [[ -z "${NOS_IMAGE:-}" ]]; then
  _nos_rv="$(sed -n 's/^ARG RUNNER_VERSION=//p' "${_nos_conf_dir}/image/Containerfile" 2>/dev/null)"
  if [[ -n "${_nos_rv}" ]]; then NOS_IMAGE="nos-runner:${_nos_rv}"; fi
fi
: "${NOS_IMAGE:=}"
