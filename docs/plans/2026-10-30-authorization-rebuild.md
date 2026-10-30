# Claude Code authorization reconstruction

Date: 2026-10-30. Status: **design and offline foundation implemented;
runtime, native authentication, deployment and acceptance testing incomplete**.

## Decision

Put ordinary development agents in a disposable VM with no host mounts,
host credentials, control sockets or route to the home LAN. Keep human
administration on the host, behind a separately authenticated launcher.
Use a small trusted controller outside the guest for external capabilities,
denial state, approval and audit. Keep probabilistic review advisory to the
hard boundary. Do not install a resident AI supervisor.

This replaces the security model of the existing patchwork; it does not
require merging unrelated shell configuration, CI and policy repositories.
The six accessible repositories were inspected at the revisions recorded in
`2026-10-30-authorization-inventory.json`. `my-repos` is a command implemented
by `scripts/my-repos.sh` and `scripts/lib/repo-walker.sh`, not a repository.
An initially guessed repository name was incorrect and is not an access gap.

The attached goal is the governing specification. Previous specifications,
including the October 27 permission plan, do not override it. In particular,
an agent reporting a refusal and waiting for guidance is correct behavior.

## Evidence that changes the architecture

1. `claude-wrapper/bin/claude-wrapper` adds remote-control and machine settings
   arguments but does not require sandboxing. `lib/machine-settings.sh` supplies
   the machine overlay only on qualifying interactive launches, skips it when
   the caller already provided `--settings`, and treats invalid overlays as
   a warning. The lite wrapper has the same overlay behavior. These are
   convenience launchers, not unbypassable containment.
2. Shared `claude-config/settings.json` has no `sandbox` floor and no bypass
   prohibition. The previous live audit observed a user-owned machine overlay
   and no managed file. This run has repository access, **not current access
   to the Mac's installed configuration**, so those live observations are
   historical evidence and must be rechecked before deployment.
3. `dotfiles/bash/aliases.sh` gives `clauded` bypass on timeout, any key except
   `a`, and non-TTY input. `suclauded` goes to the direct binary with bypass.
   A TTY, flag, process-name check or environment marker does not authenticate
   a human. Preserve the names and human functions; replace the launch path
   only at an approved checkpoint.
4. `claude-wrapper/lib/credentials.sh` exports the 1Password service-account
   token to the runtime and its children. GitHub owner selection is useful
   scoping but does not hide credentials from the agent. The main wrapper
   sources project `.claude/pre-launch.sh` after secrets injection. Even
   owner-only repository code then runs outside the Bash sandbox with secrets.
5. Hook and shell wrappers inspect command text. The API-merge blocker itself
   documents shell/interpreter forms that escape its patterns. `CLAUDECODE`,
   `STRICT_PREPUSH`, a function named `gh` and `core.hooksPath` are not durable
   authority boundaries. Git author identity is attribution, not identity
   enforcement. No destructive bypass was executed during this investigation.
6. The deploy clone separates working branches from live hooks, which is useful
   operationally. A user LaunchAgent fetching `main` is not an independently
   approved security release mechanism. A successful merge must not silently
   publish new enforcement code or approvals.
7. Some detectors fail open: the old dispatcher propagates child exit 1, which
   Claude Code does not treat as a PreToolUse block. The secret-leak detector
   explicitly allows the command unchecked on detector failure. File presence
   checks alone do not make those controls fail closed. The working branch
   closes those two failure paths now: the dispatcher maps every child failure
   to blocking exit 2 and the secret detector blocks on its own failure too.
   Targeted synthetic tests verify that later hooks never run after refusal.
   These are migration baseline fixes, not a claim that regex hooks provide
   the replacement containment boundary. Nothing has been deployed.
8. The old denial contract applies only to classifier refusals. Several hooks
   persist full commands and have large fixture-contaminated logs according
   to the prior audit. Raw stderr and arbitrary tool failures cannot reliably
   identify a denying authority. Counts in that report are historical; this
   work does not claim a newly measured denial or interruption rate.

Anthropic's current documentation explicitly limits the Bash sandbox to shell
commands. File/web tools, hooks, local MCP servers, plugin monitors, LSP and
helper commands run outside it. It recommends containing the entire process
when those paths must share a boundary. Managed Boolean settings help, but
some arrays merge and some widening settings have no managed-only lock. A
managed settings file is therefore useful defense in depth, not a replacement
for isolation of the runtime and its credentials.

Sources checked 2026-10-30:

- <https://code.claude.com/docs/en/sandboxing#what-runs-outside-the-sandbox>
- <https://code.claude.com/docs/en/sandboxing#keep-developers-from-widening-the-policy>
- <https://code.claude.com/docs/en/settings-reference>
- <https://code.claude.com/docs/en/hooks#permissiondenied>
- <https://developer.apple.com/documentation/localauthentication/lacontext>
- <https://developer.apple.com/documentation/localauthentication/lacontext/invalidate()>

## Trust boundaries and defaults

| Context | May hold | Must not reach |
| --- | --- | --- |
| Ordinary guest | Disposable workspace, guest-only model login, scoped read access | Host home, Keychain, 1Password service token, host SSH agent, admin socket, LAN |
| Trusted controller | Sealed release, bounded external credentials, approval ledger, journal | Execution of repository scripts or arbitrary shell requests |
| Human host launcher | Fresh local authentication and chosen launch descriptor | Agent-chosen executable, env, arbitrary forwarded argv, cached privilege grants |
| Human privileged session | Deliberately granted host administrative access | Automatic grant reuse by an ordinary guest |

The host must treat guest files and messages as hostile. No host-side shell
startup files, git hooks, dependency installers, LSPs, status lines or plugin
code may be loaded from a guest checkout. Workspaces move as data into an
independent clone in the guest. Do not share a host checkout or a git common
directory; a read-only mount can still expose credentials and private files.
Export patches/artifacts through a bounded transfer and human review; do not
automatically unpack archives onto arbitrary host paths or render executable
terminal escapes from guest output.

The guest runs without sudo or access to virtualization/control sockets.
Root owns the guest policy, hook implementation and egress configuration.
The hypervisor, host controller and their configuration are outside the guest.
No bridged LAN, host loopback forwarding, shared clipboard, Apple Events,
host filesystem MCP, passwordless host SSH, agent forwarding or Docker socket.
Model-service egress is allowlisted by an independent network boundary, not
only by Bash proxy settings. Package access must be reviewed separately.

This limits host damage even if Claude, a plugin or a dependency executes
arbitrary code in the guest. It does not guarantee that writable work inside
the guest survives; use disposable clones, snapshots and ordinary backups.
Hypervisor/OS vulnerabilities and an administrator deliberately disabling the
boundary are outside the claim. Never promise protection “regardless of
invocation technique” without stating which boundary and threat model passed.

Linux guests cover portable work. macOS guests are needed for native Apple
build/tests. The existing `scripts/docs/plans/2026-10-23-mimolette-vm-test-runner.md`
is design evidence only. It explicitly leaves headless launch and network
isolation unresolved. Do not call it an available secure runner. VM product,
resource limits, base-image provenance and exact egress remain release gates.

## Human privileged path

`clauded` and `suclauded` remain intentional human tools. Their current live
behavior has not changed. The replacement target is one signed, operator-owned
macOS launcher with two fixed profiles (wrapped administration and direct
administration). Neither name is an agent capability.

The host launcher creates a new `LAContext` for each launch, requests an explicit
human action, uses no Touch ID reuse window, invalidates the context after the
attempt and fails closed on cancellation, timeout or authentication failure.
If Touch ID is unavailable, require the configured local OS authentication
fallback; never replace it with a shell confirmation or auto-accept timeout.

Authentication is bound to a displayed, normalized launch descriptor: profile,
workspace, executable release digest, initiating GUI session, expiry and a
single-use nonce. The launcher itself starts the approved runtime; it must not
return an unrestricted token or enable a temporary global policy exception.
A privileged helper, if required, authenticates the client via OS audit-token
and code-signing checks, not a PID string or an agent-provided “authenticated”
Boolean. Agent-facing transport cannot address this launch operation.

No general `sudo` timestamp, shared environment flag, password file, changed
managed policy or helper that accepts arbitrary argv. Record launch, cancellation,
authentication outcome, runtime identity and termination without prompt text.
Short-lived authorization governs **launch**, not every later command in an
unrestricted session. Once the human explicitly grants an unrestricted session,
its arbitrary child processes cannot be made harmless by naming conventions.
The security claim concerns ordinary contained agents acquiring that privilege.

Native proof is outstanding. A simple Swift program returning LAContext's
Boolean would not prove process isolation or safe IPC and is deliberately not
presented as a working privileged boundary.

Do not put the guest's bypass prohibition into a machine-wide host file: it
would also disable the human path. Separate execution environments resolve that
settings-precedence conflict without opening an override window.

## Deterministic capabilities

Local edits/builds/tests happen in the disposable guest with the same filesystem
authority regardless of shell syntax. Do not write a shell-equivalence engine.
Normalize **structured requests**, not arbitrary Bash programs.

| Capability | Inputs | Required controller checks |
| --- | --- | --- |
| Worktree create | Approved repository ID, slug, pinned base SHA | Actual git common-dir identity, branch namespace, no path override, no symlink escape, destination absent |
| Worktree retire | Worktree identity and expected HEAD | Independently observed merged PR/head SHA, no new commits, clean including ignored files, no lock/active process; never force deletion on failed checks |
| Review run | Repo ID, pinned base/head SHA, review profile | Exact trusted runner/toolset; output is evidence with provenance, not a self-issued approval |
| Publish branch | Repo ID, branch, commit-object IDs | Exact repo/namespace; no arbitrary remote or credential return; enforce CI/secret boundaries, prohibit publishing policy releases automatically |
| Merge | Repo ID, PR ID, base/head SHA, one-use approval ID | Fresh trusted GitHub state, required checks/reviews, exact approval binding, expiry, transactionally consumed nonce, no force/admin fallback |
| LAN/native job | Registered task ID and bounded data | Forced remote command or isolated job runner; no arbitrary SSH host, command, forwarding or host shell |

Worktree operations stay in the guest. The external broker must never execute
`git` against agent-writable host repo configuration. GitHub writes use a small
API client with exact endpoints, no arbitrary REST/GraphQL proxy. No GitHub
write token or 1Password service token enters the ordinary guest. GitHub App
installation scoping alone does not restrict a token to a branch: broker checks
and repository rules are both necessary. Remote MCP servers can have their own
powerful authority; default-deny side effects until their scopes and transport
are included in this model.

An unrecognized request returns `denied/unknown_capability` with an actionable
explanation. It neither rewrites shell text nor broadens rules. A valid request
from a blocked workflow still remains blocked. Passing the resume gate restores
the existing authority only; expanding a capability is a separate human-approved
policy release.

These capabilities are specified, **not enabled or implemented by the current
foundation**. They must not receive allow rules until their real adapters and
negative tests exist.

## Denial state and truthful completion

Any observed authorization denial freezes the affected workflow tree in the
trusted controller. This conservative rule avoids guessing whether a new tool
invocation is semantically the same forbidden effect. The child reports to the
parent and the parent to Andrew promptly. No parent retries for a child.
Independent authorized work in a different workflow may continue.

The human resolves a specifically identified denial by granting bounded
authority, changing the plan, or cancelling that work. The controller binds
that decision to the tree and denial IDs; a chat transcript containing the
word “approved” does not mint a grant. Old grants cannot reopen a new denial.

The reference `security/workflow.py` demonstrates state transitions and evidence
requirements. It is not a controller daemon, does not observe running tools,
and does not authenticate approvals. A real adapter must keep state and code
outside guest reach. Freezing future calls does not stop work already running:
the runtime controller must suspend/terminate outstanding jobs and latch any
external capability requests, with race tests and fail-closed recovery.

Stopping all tools after a denial still leaves the agent able to send a report.
Do not use a Stop hook that repeatedly forces the model to continue working:
it can create a retry loop. A user-facing blocked status persists independently
of model prose. Completion requires independently recorded test/artifact
evidence scoped to the requested task and current revision. This can prevent
a controller from marking unverified work complete; it cannot guarantee every
sentence produced by a model is true.

## Telemetry

One schema, one collector implementation in `claude-config/security/events.py`.
Trusted adapters emit events from permission rules, PreToolUse decisions,
sandbox, runtime/OS, wrappers, git gates, human rejections and successful tools.
No adapter may infer all those from `PermissionDenied`: that hook covers auto
mode only. An exit code or text saying “denied” is insufficient provenance.

Persist only fixed enums and keyed fingerprints. Do not persist raw commands,
tool output, reasons, credential values, paths or raw IDs. Keep the key and
journal in controller-owned private storage; a guest key would allow dictionary
attacks. Permissions, locks and rotation protect ordinary local logging, not a
hostile owner. The current collector is passive and accepts no authority change.
Adapters for the other layers and tamper-resistant off-guest transport are not
yet connected. Unknown coverage is a visible operational failure, not zero
denials. Legacy raw logs remain unchanged until the collectors replace them.

Keep separate measures for observations, correlated tool calls, retries,
workflow interruptions, correct denials, false positives, successful outcomes
and completion evidence. Do not divide denial events by an unrelated count of
successful calls. Tests use separate journals and trusted `environment=test`.
Unknown retry/interruption/false-positive status remains unknown until reviewed.
Never tune policy automatically from logs or hostile repository content.

## Ownership and retirement

| Repository | Final responsibility | Changes after replacement passes |
| --- | --- | --- |
| `claude-config` | Single versioned security policy, controller code, capability schemas and agent instructions | Replace command-text blockers and approval files with controller decisions; guest-only managed deployment |
| `claude-wrapper` | Human/guest launch UX and model-session setup | Remove host secret injection and repository pre-launch sourcing from ordinary agent path; no policy duplication |
| `dotfiles` | Shell ergonomics and local quality tools | Retain lint/format hooks; retire gh/gpush interception as security controls; route privileged aliases to host launcher after approval |
| `dev-env` | Requirements, operating procedures, evidence and architecture record | Supersede conflicting plans; no second policy implementation |
| `scripts` | General operational scripts | Keep backups; no independent authorization engine or autonomous cleanup grant |
| `github-workflows` | CI and repository-side protections | Keep independent required checks; audit every write credential and privileged trigger before broker rollout |

The companion inventory covers every active shared hook and its proposed
disposition. Retention means a documented requirement, not endorsement of the
current implementation. Do not delete a hook solely because its ordinary path
looks unreachable; prove the replacement holds across shell, interpreter,
MCP, direct binary, IDE and headless paths first. Quality lint is distinct from
security authorization and may remain useful even after it stops being a
security boundary.

## Implementation and migration gates

| Stage | Deliverable | Current status / exit condition |
| --- | --- | --- |
| A | Source inventory, threat model, ownership plan | Implemented for six repos, including the `my-repos` command in `scripts` |
| B | Offline foundation; general denial instructions; fail-closed legacy baseline | Implemented in feature branches, not deployed |
| C | Isolated runtime, authenticated controller, host human launcher | Not implemented; native macOS lab required for proof |
| D | Trusted adapters and first bounded worktree/review capability | Not implemented; shadow mode must preserve old decisions |
| E | Disposable VM acceptance and human path verification | Not run; every matrix row below required |
| F | Explicit approval of exact release hashes and host changes | Not requested; no deployable boundary yet |
| G | One-host canary, then removal of superseded live mechanisms | Not authorized or executed |

Do not merge a security-affecting change while the legacy `main` deploy job
would apply it without the required explicit deployment approval. A draft PR
does not install anything; merging `claude-config` may, within ten minutes.
Before first deployment replace enforcement auto-update with an operator-owned
sealed release, manifest hashes and explicit activation. Human recovery uses
an out-of-band terminal to restore the last sealed release; agents cannot
edit release selection, mount snapshots or disable policy.

If a new collector fails, retain enforcement and report incomplete coverage.
If a new capability fails, keep it disabled. If runtime isolation or human
authentication fails, do not launch ordinary agents in a weaker context.
Rollback never falls back automatically to host bypass. Retire temporary
compatibility controls only after canary evidence is reviewed, and record a
removal date and responsible release for each one.

## Acceptance matrix

Use harmless canaries, mock credentials and disposable workspaces. Do not test
host destruction or retrieve live secrets. A marker file outside the permitted
workspace is sufficient to test denial; there is no need to execute `rm -rf /`.

| Area | Required positive and negative evidence | This run |
| --- | --- | --- |
| Policy | Every floor key present; widening, type changes, symlinked install rejected | Offline tests pass; native precedence untested |
| Journal | No secret fields, concurrent appends, private files, bounded rotation, no retry grant | Offline tests pass |
| Metrics | Test exclusion, correlated deduplication, missing IDs explicit, unknowns preserved | Offline tests pass |
| Denial | Child freezes tree; report before resolution; every pending denial resolved | Reference tests pass; runtime untested |
| Completion | Blocked work cannot complete; controller evidence required; prior evidence invalidated | Reference tests pass; runtime untested |
| Runtime | CLI/headless/IDE/Desktop/subagent/direct binary all run inside guest boundary | Not run |
| Escape | Host marker, Keychain, SSH forwarding, LAN, sockets, plugin/MCP/file-tool paths denied | Not run |
| Human | Touch ID/fallback succeed; cancellation, expired/replayed/parallel request fail; ordinary guest cannot request launch | Not run |
| Capabilities | Valid structured calls; path/symlink/argv/config substitution rejected; stale merge grant and changed HEAD rejected | Not implemented |
| Race/recovery | In-flight jobs stopped; atomic grant use; restart preserves latch; safe human rollback | Not implemented |
| Migration | Old protection remains until replacement proves equivalent coverage; removed components no longer loaded | Not run |

The overall goal is **not complete**. Native runtime work is a substantive
remaining dependency, not an excuse to claim the offline test oracle enforces
anything on the Mac. This branch supplies a reviewable foundation and a concrete
replacement architecture without silently changing live authority.
