#!/bin/bash
# Build VM: install runner, hook, run-job.sh, python3. Args: VERSION SHA256.
# job-started.sh and run-job.sh are already in /tmp.
set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
version="${1:?usage: install-runner.sh VERSION SHA256}"
sum="${2:?usage: install-runner.sh VERSION SHA256}"
url="https://github.com/actions/runner/releases/download/v${version}/actions-runner-osx-arm64-${version}.tar.gz"
dir=/Users/admin/actions-runner
hook=/usr/local/libexec/runner-hooks/job-started.sh
job=/usr/local/libexec/swm-runner/run-job.sh

cd "${HOME}"
curl -fsSL -o runner.tgz "${url}"
echo "${sum}  runner.tgz" | shasum -a 256 -c
mkdir -p "${dir}"
tar xzf runner.tgz -C "${dir}"
rm -f runner.tgz
# Root-owned and outside the runner directory, so a job cannot rewrite them.
sudo install -d -o root -g wheel -m 0755 /usr/local/libexec/runner-hooks /usr/local/libexec/swm-runner
sudo install -o root -g wheel -m 0755 /tmp/job-started.sh "${hook}"
sudo install -o root -g wheel -m 0755 /tmp/run-job.sh "${job}"
printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=%s\n' "${hook}" >"${dir}/.env"
grep -q "^ACTIONS_RUNNER_HOOK_JOB_STARTED=${hook}$" "${dir}/.env" || { echo "hook not configured" >&2; exit 1; }
[[ -x "${job}" && -x "${dir}/run.sh" ]] || { echo "runner files missing" >&2; exit 1; }
# Base python3 is CLT 3.9: its pty.spawn never returns on macOS. macos-latest
# has a current one.
brew install --quiet python
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "python3 is older than 3.10" >&2; exit 1; }
echo "install-runner: ${version} installed"
