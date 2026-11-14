# Agent read-only ssh account (agentro): install, use, undo

Agents used to ssh in as `andrewrich`, so they landed as an admin and could change anything.
`agentro` is a second account for them. It can read the owner's home folder and query his
services, but it cannot write, delete, signal his processes or use sudo outside one gate.
It mitigates "agents can do anything"; it is not a sandbox.

| Can | Cannot |
|---|---|
| Read the owner's home, including `0600` files | Write, delete, rename or chmod his files |
| Run `git log`, `git status`, `git diff` in his repos | Commit, pull or change a repo |
| Query launchd, `container` and pf through the gate | Start, stop or change a service |
| Read anything world-readable on the system | Use sudo for anything else |

It cannot read these credential paths: `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`,
`~/.wrangler`, `~/.sentryclirc`, `~/Library/Preferences/{.wrangler,netlify}`, `~/.netrc`, `~/.npmrc`, `~/.config/{gh,gh-app-keys,op,.wrangler,nos-runner}`,
`~/.config/bash/secrets.sh`, `~/.config/claude-code/secrets.op`, `~/.claude/.credentials.json`,
`~/.claude/{daemon,sessions,ide,bridge-spawn}`, `~/.semgrep/settings.yml`, `~/Library/Keychains` and the 1Password
group container. With those it could act as the owner. The list is `AGENT_RO_DENY` in
`scripts/agent-ro/config.sh`.

Design evidence: four spikes on MIMOLETTE, 2026-11-13 (dev-env PR for this runbook).

## 1. Make a key on each machine agents ssh from

On ASIAGO, for example. The key has no passphrase, so agents can use it with no 1Password prompt.
A stolen key gives read access only.

```bash
ssh-keygen -t ed25519 -N '' -C agentro@ASIAGO -f ~/.ssh/id_ed25519_agentro
scp ~/.ssh/id_ed25519_agentro.pub mimolette.local:agentro-asiago.pub
```

## 2. Install on the target

On the target (MIMOLETTE first), from an up-to-date dev-env clone. One `--pubkey` per source machine.
`--from` is optional: addresses or CIDRs that may use the keys.

```bash
sudo /bin/bash ~/.local/share/dev-env/scripts/agent-ro/install.sh --pubkey ~/agentro-asiago.pub
```

The installer:

1. Creates the hidden user `agentro` with its own group, or adopts an existing one. It refuses an admin `agentro`.
2. Installs the gate, the sweep and `config.sh`, root-owned, in `/usr/local/libexec/agent-ro`.
3. Checks the `--pubkey` files. It does not install them yet (step 8).
4. Adds the sshd drop-in `/etc/ssh/sshd_config.d/200-agent-ro.conf`: key only, no TTY, no forwarding.
   It checks `sshd -t` and that `sshd -T` for the owner is unchanged; on any failure it removes the file.
5. Adds `/etc/sudoers.d/agent-ro` (the gate only), checked with `visudo -cf` first.
6. Applies the read and no-write ACLs to the whole home (1–3 minutes), then loads the sweep LaunchDaemon.
   If the sweep fails, the install stops.
7. Runs a self-test as `agentro`.
8. Writes the key list to `/etc/ssh/agent-ro/authorized_keys` (root-owned, every key `restrict`).

If any step fails, including a FAIL line in the self-test, the installer removes the key list, so no agent can log in.

Re-running is safe. Without `--pubkey`, it keeps the installed keys.

## 3. Add the ssh alias on each source machine

In `~/.ssh/config`. The alias must not match the `mimolette.local` block, so the ssh wrapper's
1Password lookups and keychain unlock never run for it.

```text
Host mimolette-ro
    HostName mimolette.local
    User agentro
    IdentityFile ~/.ssh/id_ed25519_agentro
    IdentitiesOnly yes
    IdentityAgent none
```

Check: `ssh mimolette-ro 'id; ls ~andrewrich | head -3'`.

## 4. How agents use it

```bash
ssh mimolette-ro 'tail -20 ~andrewrich/.local/state/claude-config/deploy.log'
ssh mimolette-ro 'git -C ~andrewrich/.local/share/claude-config log --oneline -1'
ssh mimolette-ro 'sudo -n /usr/local/libexec/agent-ro/gate help'
ssh mimolette-ro 'sudo -n /usr/local/libexec/agent-ro/gate container ls'
ssh mimolette-ro 'sudo -n /usr/local/libexec/agent-ro/gate launchctl-print gui/501/com.nightowlstudio.nos-runner'
```

Anything that changes state still needs the owner's own login.

## 5. Known gaps

- A file moved into the home from elsewhere keeps its old ACL. The sweep fixes it within 24 hours.
  Files inside a moved-in folder stay unreadable to agentro (not exposed) until you run
  `sudo -u andrewrich /bin/bash /usr/local/libexec/agent-ro/sweep.sh --full`.
- The sweep touches only what changed since its last pass, because each `chmod +a` changes a file's ctime
  and git, watchers and backups rescan on that. Only the install walks the whole home, once.
- A credential file that a tool replaces loses its deny entry until the next sweep, at most 10 minutes later.
  A credential directory (such as `~/.ssh`) does not have this gap.
- The sweep skips `~/Library/CloudStorage` and `~/Library/Mobile Documents` (iCloud): walking them stalls.
- Folders under macOS privacy control (TCC) may refuse the sweep. Their error count is in the sweep log.
- A deny path that is a symlink denies its target when the target is in the home; otherwise the sweep logs it.
- The deny list covers the common credentials, not every one (for example `.env` files in repos).
  It mitigates; it does not guarantee.
- Keychain items cannot be read.

Sweep log: `~/Library/Logs/agent-ro-sweep.log`. Last errors: `~/.local/state/agent-ro/last-errors`.

## 6. Undo

```bash
sudo /bin/bash ~/.local/share/dev-env/scripts/agent-ro/uninstall.sh --yes
```

This removes every file the installer wrote, then the user, its home and its group.
The ACL entries stay on the owner's files. They name the deleted user's unique ID, so they grant nothing.
Remove the `Host *-ro` alias and the key on each source machine by hand.
