#!/bin/bash
# agentro settings. Plain constants, never from the environment: the gate runs as root.
# Bash 3.2 compatible.

export AGENT_RO_USER="agentro"
export AGENT_RO_REALNAME="Agent read-only"
export AGENT_RO_OWNER="andrewrich"
export AGENT_RO_OWNER_HOME="/Users/andrewrich"

# Root-owned install locations.
export AGENT_RO_LIBEXEC="/usr/local/libexec/agent-ro"
export AGENT_RO_SUDOERS="/etc/sudoers.d/agent-ro"
export AGENT_RO_SSHD_CONF="/etc/ssh/sshd_config.d/200-agent-ro.conf"
# sshd reads agentro's keys from here, not from agentro's own home, so the
# account cannot add keys or drop the restrict option.
export AGENT_RO_KEYS_DIR="/etc/ssh/agent-ro"
export AGENT_RO_LABEL="com.smartwatermelon.agent-ro-sweep"
export AGENT_RO_PLIST="/Library/LaunchDaemons/com.smartwatermelon.agent-ro-sweep.plist"

# The sweep runs as the owner (owners may change ACLs on their own files), so
# its state and log live in the owner's home.
export AGENT_RO_STATE_DIR="${AGENT_RO_OWNER_HOME}/.local/state/agent-ro"
export AGENT_RO_LOG="${AGENT_RO_OWNER_HOME}/Library/Logs/agent-ro-sweep.log"
# Full allow sweep at most this often; the deny pass runs on every start.
export AGENT_RO_FULL_SWEEP_S=86400
export AGENT_RO_SWEEP_INTERVAL_S=600

# File forms match what chmod writes for a directory entry, so a repeat chmod +a adds no duplicate.
export AGENT_RO_ALLOW_DIR="user:agentro allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
export AGENT_RO_ALLOW_FILE="user:agentro allow read,execute,readattr,readextattr,readsecurity"
# Explicit no-write, so the read grant never makes a world-writable entry
# in the home writable for agentro (deny entries are checked first).
export AGENT_RO_NOWRITE_DIR="user:agentro deny add_file,add_subdirectory,delete_child,delete,writeattr,writeextattr,writesecurity,chown,file_inherit,directory_inherit"
export AGENT_RO_NOWRITE_FILE="user:agentro deny write,append,delete,writeattr,writeextattr,writesecurity,chown"
export AGENT_RO_DENY_DIR="user:agentro deny list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
export AGENT_RO_DENY_FILE="user:agentro deny read,execute,readattr,readextattr,readsecurity"

# Never walked: File Provider folders stall or download when listed (spike 4).
AGENT_RO_SWEEP_SKIP=(
  "Library/CloudStorage"
  "Library/Mobile Documents"
)

# Credentials: reading these would let agentro act as the owner. Gaps: docs/runbooks/agent-ro.md.
AGENT_RO_DENY=(
  ".ssh"
  ".gnupg"
  ".aws"
  ".docker"
  ".wrangler"
  ".sentryclirc"
  "Library/Preferences/.wrangler"
  "Library/Preferences/netlify"
  ".netrc"
  ".npmrc"
  ".config/gh"
  ".config/gh-app-keys"
  ".config/op"
  ".config/.wrangler"
  ".config/nos-runner"
  ".config/bash/secrets.sh"
  ".config/claude-code/secrets.op"
  ".claude/.credentials.json"
  ".claude/daemon"
  ".claude/sessions"
  ".claude/ide"
  ".claude/bridge-spawn"
  ".semgrep/settings.yml"
  "Library/Keychains"
  "Library/Group Containers/2BUA8C4S2C.com.1password"
)

# Binaries the gate runs. Absolute paths; the gate never searches PATH.
export AGENT_RO_LAUNCHCTL="/bin/launchctl"
export AGENT_RO_SUDO="/usr/bin/sudo"
export AGENT_RO_CONTAINER="/opt/homebrew/bin/container"
export AGENT_RO_PFCTL="/sbin/pfctl"
export AGENT_RO_ID="/usr/bin/id"
export AGENT_RO_ENV="/usr/bin/env"

# The arrays cannot be exported; this use keeps shellcheck from calling them unused.
: "${AGENT_RO_SWEEP_SKIP[@]}" "${AGENT_RO_DENY[@]}"
