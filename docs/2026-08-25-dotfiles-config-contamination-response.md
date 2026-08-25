# Response: root cause of dotfiles Git-config contamination

**Date:** 2026-08-25  
**Scope:** Read-only investigation of the contamination in
`2026-08-24-dotfiles-config-contamination-handoff.md`. No tracked source file
was changed during the investigation. All reproductions used temporary
repositories.

## Executive conclusion

The contamination has a reproducible root cause. It is not an intermittent Git
failure, a `git worktree remove` defect, or a failed `cd` in the ordinary
test case.

The dotfiles tests can inherit Git repository-selection state from an agent
running in a linked worktree. In particular, an inherited `GIT_DIR` naming
the worktree's administrative Git directory takes precedence over both the
process current directory and Git's `-C` option. Tests that believe they are
creating and configuring repositories under `/tmp` instead operate on the
linked worktree's Git directory. Linked worktrees share the common
`.git/config`, so the main checkout is contaminated too.

This explains every observed value, the exact write time, the temporary fixture
commits in the worktree reflog, the temporary loss of the worktree branch, and
why ordinary standalone test runs did not reproduce the failure.

The previously proposed repair of adding `git -C "${dir}"` to fixture writes
is insufficient. `-C` changes Git's directory; it does **not** override an
explicit `GIT_DIR` environment variable.

## Current state checked during the investigation

The real `/Users/andrewrich/Developer/dotfiles/.git/config` was clean when
inspected:

| Check | Observed state |
|---|---|
| `core.bare` | `false` |
| Local `core.hooksPath` | absent |
| Local `user.email` / `user.name` | absent |
| Remotes | `origin` only |
| Immutable flag | `uchg` is set on `.git/config` |

The immutable flag remains a useful immediate safety barrier. It is not the
root-cause fix: it makes a later faulty test fail, but the test suite must not
depend on an immutable production checkout for isolation.

## Corrected timeline

The handoff asserted that worktree `agent-0a206b4b` was created at 17:09:25
PDT, two minutes after the config write. Git's own administrative files and
reflog contradict that assertion.

| Time (PDT) | Verified event | Evidence |
|---|---|---|
| 16:49:01 | Linked worktree is created / branch is made from `origin/main`. | Its administrative `gitdir` and `commondir` files have this mtime; the HEAD reflog records branch creation then. |
| 17:01–17:02 | A full `bash/tests/run-tests.sh` run is launched against that worktree. | Archived session command and result. |
| 17:06:39 | Fixture commit `chore: test fixture`, then first `test: init` / `test: feature commit` pair. | Worktree HEAD reflog. |
| 17:07:09 | Second `test: init` / `test: feature commit` pair. | Worktree HEAD reflog. |
| **17:07:24** | Third and final `test: init` / `test: feature commit` pair; shared config mtime also 17:07:24. | Worktree HEAD reflog and config metadata. |
| 17:08:31 | Worktree HEAD is reset to `claude/fix-review-findings-0a206b4b`. | Worktree HEAD reflog. |
| About 17:10 | The hygiene detector reports contamination. | Archived session record. |

The three pairs exactly match the three `setup_repo` calls in
`bash/tests/test-pre-push-stale-ci.sh`. This is direct evidence, not a
timestamp coincidence.

## Contaminants and their sources

| Local config effect | Source test and operation | Consequence |
|---|---|---|
| `core.hooksPath =` | `test-pre-push-stale-ci.sh` fixture setup | Overrides the global hook directory with an empty value and silently prevents normal hooks running. |
| `user.email = test@example.com` | Same fixture setup | Local test identity overrides the intended global identity. |
| `user.name = Test` | Same fixture setup | Same identity corruption. |
| `core.bare = true` | `git init` with inherited `GIT_DIR`, without `GIT_WORK_TREE` | The shared config falsely marks the checkout bare; work-tree operations may fail. |
| `remote.upstream.url = git@github.com:beacon-biosignals/forked-tool.git` | `test-gh-wrapper-identity.sh` fixture | Adds the test upstream to the real common config and affects owner resolution. |

The dangerous item is empty `core.hooksPath`. Git resolves it as `./`, not
as the global hooks directory or `.git/hooks`. Therefore normal local review
hooks are skipped with no error. The pre-push test that would otherwise detect
the contamination is disabled by that same setting.

## Direct code paths

### Fixture identity and hooks-path writes

`bash/tests/test-pre-push-stale-ci.sh` defines `setup_repo()` at lines 36–49.
For each of three scratch repositories it runs:

```bash
/usr/bin/git -c core.hooksPath= -c init.templateDir= init -q -b main
/usr/bin/git config core.hooksPath ""
/usr/bin/git config user.email "test@example.com"
/usr/bin/git config user.name "Test"
```

The test correctly changes into a temporary directory under `/tmp`. That
normally isolates the writes. It does not clear repository-selection
environment variables, however. When `GIT_DIR` is set, Git uses that directory
regardless of the temporary current directory.

The test subsequently makes two empty commits. Under the inherited context,
those commits land in the agent worktree's reflog rather than in the scratch
fixture.

### Bogus upstream remote

`bash/tests/test-gh-wrapper-identity.sh` creates a fixture and runs:

```bash
git -C "${fork_repo}" init -q
git -C "${fork_repo}" remote add upstream \
  "git@github.com:beacon-biosignals/forked-tool.git"
```

The script isolates `HOME`, `GIT_CONFIG_GLOBAL`, and `GIT_CONFIG_SYSTEM`,
but it leaves `GIT_DIR` intact. Thus the remote addition can target the
inherited linked-worktree Git directory. `git -C` is not a containment
boundary when `GIT_DIR` is explicit.

### Existing partial precedent

`bash/tests/test-post-checkout-gitignore.sh` already contains a partial
defense:

```bash
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY
unset GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
```

That script demonstrates the right general approach: a test creating or
mutating Git fixtures must explicitly control its Git environment. The
affected tests do not.

## Controlled reproductions

Each reproduction used a newly-created temporary repository with a linked
worktree. No real checkout or tracked file was modified.

### Reproduction A: fixture config and commits

1. Create a temporary repository and linked worktree.
2. Read the linked worktree's `.git` file to obtain its administrative
   `gitdir` path.
3. Copy the relevant test source into the temporary area.
4. Run `test-pre-push-stale-ci.sh` with only `GIT_DIR` set to that
   administrative path.

Resulting shared config:

```text
core.bare=true
core.hooksPath=
user.email=test@example.com
user.name=Test
```

The linked-worktree reflog contained exactly three `test: init` /
`test: feature commit` pairs: the same configuration payload and commit
pattern observed in the incident.

A variant with both `GIT_DIR` and `GIT_WORK_TREE` set produced the three
fixture values and commits but left `core.bare=false`. This identifies the
`GIT_DIR`-only form as the source of `core.bare=true`.

### Reproduction B: bogus upstream

Using a separate temporary linked worktree, run
`test-gh-wrapper-identity.sh` with only `GIT_DIR` set to its administrative
directory.

Resulting shared config:

```text
core.bare=true
remote.upstream.url=git@github.com:beacon-biosignals/forked-tool.git
remote.upstream.fetch=+refs/heads/*:refs/remotes/upstream/*
```

This proves that `git -C "${fork_repo}" remote add ...` cannot contain the
operation when `GIT_DIR` is inherited.

## Why the prior CWD theory was incomplete

The prior analysis correctly noted that bare `git config` following a failed
`cd` can write to an enclosing repository. It then tried to make `git init`
fail and could not do so. That was the wrong condition.

The historical suite invocation ran from the `dev-env` checkout and
referenced the dotfiles worktree by absolute path. Had its `cd /tmp/...`
failed, a bare Git invocation would have targeted `dev-env`, not dotfiles.
The actual target was dotfiles because Git had been explicitly redirected by
its inherited repository environment.

## Why it appeared intermittent

The failure is conditional, not random:

```text
Normal test process:     no inherited GIT_DIR  -> scratch repositories work
Affected agent process:  inherited GIT_DIR     -> scratch operations hit worktree
```

This accounts for clean individual-test audits: they did not reproduce the
agent environment carrying `GIT_DIR`. A linked worktree alone is not enough;
the process must inherit repository-selection state.

The preserved session metadata does not contain a complete environment dump.
The exact reproduction, worktree reflog, and shared-config payload establish
the operative condition nonetheless. Identifying which infrastructure component
exported `GIT_DIR` is useful follow-up work, but is not required to make the
tests safe: fixture tests must defend against inherited Git context regardless
of where it comes from.

## Corrections to the handoff

| Handoff claim | Assessment | Correction |
|---|---|---|
| Worktree was created after the write and could not be involved. | False. | It existed at 16:49; fixture commits from it coincide exactly with the write. |
| Trigger is intermittent and could not be reproduced. | Incomplete. | It reproduces under inherited linked-worktree `GIT_DIR`; ordinary tests lacked that condition. |
| CWD-relative calls are the prime mechanism. | Incomplete. | They are unsafe, but the incident requires `GIT_DIR` precedence. Failed `cd` would have targeted `dev-env`. |
| Add `git -C "${dir}"` to fix setup. | Insufficient. | `-C` does not override `GIT_DIR`; sanitize the environment first. |
| Remote and config leaks are separate mysteries. | Misleading. | Both result from missing Git-environment isolation. |
| `git worktree remove` caused the defect. | Unsupported. | The observed write happened during the suite; no evidence implicates removal. |

The handoff remains useful as a symptom record and for its analysis of the
self-concealing hook failure. Its causal conclusion should be superseded by
this document.

## Recommended remediation

### 1. Sanitize Git fixture context at the source

Before any scratch-repository operation, affected tests should remove inherited
repository-local Git state. At a minimum:

```bash
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_QUARANTINE_PATH GIT_GRAFT_FILE GIT_SHALLOW_FILE
unset GIT_IMPLICIT_WORK_TREE GIT_NO_REPLACE_OBJECTS
unset GIT_REPLACE_REF_BASE GIT_PREFIX GIT_INTERNAL_SUPER_PREFIX
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
```

`GIT_CONFIG_KEY_*` and `GIT_CONFIG_VALUE_*` are inert when
`GIT_CONFIG_COUNT` is unset. A test that intentionally needs an override
should set it after this isolation step.

Apply this directly to each standalone fixture test that mutates Git state,
especially `test-pre-push-stale-ci.sh` and
`test-gh-wrapper-identity.sh`. The suite runner should also sanitize this
state before starting each child as defense in depth, but runner-only cleanup
does not protect developers who run one test directly.

Review the list against `git rev-parse --local-env-vars` for the installed
Git version. The rule is to clear variables that select or redirect
repository-local state, not merely the variables observed in this incident.

### 2. Add an inherited-`GIT_DIR` regression test

The regression should create a disposable repository with a linked worktree,
set `GIT_DIR` to that worktree's administrative directory, then invoke each
affected test as a subprocess. Afterward it should verify:

- no `core.hooksPath`, test identity, or `core.bare=true` appears in the
  temporary common config;
- no `upstream` remote was added;
- worktree HEAD and branch remain unchanged; and
- the invoked tests pass.

The test must deliberately inject this condition. A normal-checkout test would
repeat the original false negative.

### 3. Expand the hygiene detector

Add the missing `core.bare` assertion to
`test-git-config-hygiene.sh`. It should reject `true`; an absent setting is
cleaner, but `false` is safe.

Keep the existing checks for local identity, local `core.hooksPath`, and
unexpected remotes. This is detection, not prevention, but it makes a future
escape more diagnosable.

### 4. Retain the tripwire, but do not depend on it

The current `chflags uchg` setting blocks direct config replacement writes.
Keep it until the source fix and regression coverage are accepted.

`chmod 444` is not equivalent: Git writes `config.lock` and atomically
renames it over `config`, so file permissions alone do not protect the path.

The tripwire will block legitimate local configuration changes. Make those only
through a deliberate unfreeze/change/refreeze procedure. Never make a test
runner automatically unfreeze the real config.

### 5. Consider an independent post-suite integrity check

As an additional guard, the runner can capture a checksum or byte-for-byte
copy of the target checkout's common config before the suite and compare it
afterward. It should fail loudly on a change, not silently restore it.
Restoration would hide the culprit and can discard a legitimate concurrent
change.

This check cannot replace fixture isolation. It is a diagnostic boundary while
the suite evolves.

## Verification criteria for a future fix

Do not close the incident based only on a normal suite run. A completed fix
should demonstrate all of the following:

1. The deliberately injected `GIT_DIR` linked-worktree regression passes.
2. The ordinary full suite passes from both the main checkout and a linked
   worktree.
3. The target config is byte-identical before and after both runs.
4. The hygiene test explicitly checks `core.bare` in addition to identity,
   hooks-path, and remote state.
5. The worktree branch and HEAD remain unchanged after the suite.
6. A normal dotfiles commit resolves an executable hook from the global hooks
   directory.

## Final assessment

The incident is attributable to a concrete test-isolation defect: uncontrolled
inheritance of Git's repository-selection environment. It is serious because it
disables the control that normally detects it, but it is straightforward to
prevent once the environment is treated as part of the fixture boundary.

The key operational lesson is simple: a temporary directory is not a temporary
Git repository when `GIT_DIR` is already set.
