# Handoff: dotfiles `.git/config` contamination (smartwatermelon/dotfiles#239)

**Status as of 2026-08-24 19:25 PDT:** config cleaned, tripwire armed, root
cause **still unidentified**. Issue #239 reopened.

**Read this first:** the trigger is *intermittent*. Three separate
investigations — two before this one — have failed to reproduce it on demand.
Do not assume a clean audit means the leak is gone; it has produced a clean
audit twice already.

---

## 1. What the bug is

Something intermittently writes test-fixture values into the **real**
`~/Developer/dotfiles/.git/config`:

| key | value written | consequence |
|---|---|---|
| `core.hooksPath` | `` (empty) | **No git hooks fire in this checkout.** Protocol 4's automatic `code-reviewer` / `adversarial-reviewer` pass silently stops running. |
| `core.bare` | `true` | `git status`, `add`, `commit` all fail with `fatal: this operation must be run in a work tree`. |
| `user.email` | `test@example.com` | Commits get a fake author. |
| `user.name` | `Test` | Same. |
| `remote.upstream.url` | `git@github.com:beacon-biosignals/forked-tool.git` | Bogus remote; affects `gh` owner resolution. |

### Why `core.hooksPath` is the one that matters

Git resolves an empty `core.hooksPath` to `./` — the repo root — not to
`.git/hooks` and not to the global path. The dotfiles repo has a `pre-commit/`
**directory** at its root, so `[[ -x ./pre-commit ]]` succeeds while git still
finds no executable *file* to run. Net effect: hooks silently do not fire, and
nothing reports an error.

Linked worktrees share `.git/config`, so they inherit the override. Fresh
clones are unaffected, which is a large part of why this stays invisible.

**Any commit made in this checkout while contaminated went unreviewed.**

---

## 2. Timeline

All times PDT. UTC shown where it disambiguates.

| when | what |
|---|---|
| 2026-08-24, earlier | Contamination first found. #239 filed: *"cause unknown"*. |
| 2026-08-24 12:30:54 | **PR #241 merged** (`01214a8f0efb`). #239 auto-closed as COMPLETED. |
| 2026-08-24 ~16:43 | Cross-repo backlog session starts. |
| 2026-08-24 **17:07:24** | **`.git/config` written — the recurrence.** 4h37m after #241 merged. |
| 2026-08-24 17:09:25 | Agent worktree `agent-0a206b4b` created — **2 minutes *after* the write**. |
| 2026-08-24 ~17:10 | `test-git-config-hygiene.sh` fails during a routine suite run; contamination noticed. |
| 2026-08-24 ~19:20 | Config cleaned; `core.bare` found *after* the detector reported clean; `chflags uchg` tripwire armed; #239 reopened. |

**The worktree did not cause it.** It post-dates the config write by two
minutes. Whatever wrote the config at 17:07:24 did so with #241 already merged.

---

## 3. What PR #241 actually did

**#241 is a detector, not a fix.** Its entire diff is +171/-0 across two files:

- `bash/tests/test-git-config-hygiene.sh` (new, +146)
- `bash/README.md` (+25)

Nothing in `setup_repo()` or any other test changed. The PR body says so
directly: *"Cause: not identified, hence a detector rather than a fix."*

This is working as designed. It matters only because **#239 was closed as
COMPLETED**, and a reader seeing "closed/completed" on an issue titled *"cause
unknown"* could reasonably conclude the leak was fixed. It was not.

### The detector has a gap

It does **not** check `core.bare`. On 2026-08-24 the four documented values
were cleaned, the detector reported **ALL CHECKS PASSED**, and `git status`
still failed with `fatal: this operation must be run in a work tree` because
`core.bare = true` remained.

**A green detector run is not currently sufficient evidence that the config is
sound.** Suggested addition:

```bash
# Case: repo is not falsely marked bare
if [[ "$(git -C "${REPO_ROOT}" config --local --get core.bare || echo false)" == "true" ]]; then
  _fail "core.bare is true but this repo has a work tree"
else
  _pass "core.bare is not set to true"
fi
```

### The detector IS wired in — and that tells us something

`bash/tests/run-tests.sh:44` globs `test-*.sh`, so the detector runs as part of
the normal suite. That suite is invoked by **both** `.project-hooks/pre-push`
and `.github/workflows/bash-tests.yml:55`.

(A `grep` for the literal filename in those files returns nothing, because the
glob is what picks it up. Do not be fooled by that — verify by running
`run-tests.sh` and looking for `RUN  test-git-config-hygiene.sh` in the output.)

**This is a significant clue.** The detector runs on every push. So either:

- the contamination happened *after* the last push from this checkout, or
- a push happened while contaminated and the pre-push hook did not run — which
  is exactly what an empty `core.hooksPath` causes.

The second is self-concealing: the contamination disables the hook that would
have caught the contamination. That is likely why it survives between
sessions.

**Verified by reproduction** on a scratch repo, with a hook that exits 1:

```
$ git config core.hooksPath /path/to/hooks-real
$ git commit --allow-empty -m x
HOOK RAN                              <- fires, blocks

$ git config core.hooksPath ""        <- the contaminated state
$ git commit --allow-empty -m y
[main (root-commit) 18cde3a] y        <- no hook, no error, commit succeeds
```

The failure is silent in both directions: hooks stop running, and nothing says
so. Local review stops, the pre-push detector stops with it, and the only
surviving signal is CI.

---

## 4. Hypotheses tested and DISPROVED

Recorded so nobody spends time re-running them.

### By the original #241 investigation

- **A test leaked in via `setup_repo()`.** Its `cd "${dir}" || exit 1` guard was
  tested against an uncreatable directory (contained); the real test was run
  from the repo root (exit 0, no leak); `git log -S` shows the guard present
  since file creation.
- **`git worktree remove` corrupted it.** Config snapshotted before and after a
  real `worktree remove --force`; byte-identical.
- **Full audit** of every `git config` / `git remote` / `git init` call in
  `bash/tests/` found no unguarded mutation.

### By this investigation (2026-08-24)

- **`setup_repo()`'s CWD-relative `git config` calls.** The leak *is*
  constructible: if `git init` does not produce a repo at the target dir, the
  three following `git config` calls walk up and write to the enclosing repo —
  all three values, empty `core.hooksPath` included. Reproduced synthetically.
  **But `git init` proved robust in every case tried**: inside an existing repo
  and with a nonexistent `--template`, it still exits 0 and creates its own
  `.git`. Could not make the real function fail.

- **Unguarded `cd` in `test-gh-wrapper-identity.sh:105`** (`assert_desired_in`).
  It genuinely has a bare `cd "${dir}"` with no `|| exit`, and the `cd "${prev}"`
  afterward would erase the evidence. **But the file is `set -euo pipefail`
  (line 12)**, so a failed `cd` aborts the script. The mechanism only works
  without `-e`; reproduced only by forcing `set -uo`.

- **Empirical per-test scan.** Every `bash/tests/test-*.sh` run individually,
  snapshotting `.git/config` after each, from **both** the main checkout **and**
  a linked worktree. **No test polluted the config in either location.** This
  reproduces the original audit's clean result rather than contradicting it.

**Conclusion: the leak requires a condition none of these attempts produced.**

---

## 5. Current state — what was changed

### Config cleaned

```bash
git -C ~/Developer/dotfiles config --local --unset-all user.email
git -C ~/Developer/dotfiles config --local --unset-all user.name
git -C ~/Developer/dotfiles config --local --unset-all core.hooksPath
git -C ~/Developer/dotfiles remote remove upstream
git -C ~/Developer/dotfiles config --local core.bare false   # found after detector went green
```

Verified: detector exits 0; `git status` exits 0; hooks resolve to
`/Users/andrewrich/.config/git/hooks` with an executable `pre-commit`.

### Tripwire armed

```bash
chflags uchg ~/Developer/dotfiles/.git/config
```

**`chmod 444` does NOT work — do not use it.** Git writes `config.lock` and
renames it over the target; the rename needs write permission on the **`.git`
directory**, not the file. Verified on a scratch repo: with `config` at 444 the
write succeeded and the value stuck. This is worth knowing because `chmod` is
the obvious first thing to reach for and it gives false confidence.

`chflags uchg` does hold:

```
$ git config --local user.email x@y.z
error: could not write config file .git/config: Operation not permitted
```

**Unaffected:** `status`, `log`, `checkout -b`, reads, the existing worktree.

**Will now fail by design:** `git remote add`, `git fetch` for a *new* remote,
`git config --local`, and anything else writing local config. To do legitimate
config work:

```bash
chflags nouchg ~/Developer/dotfiles/.git/config
# ... make the change ...
chflags uchg ~/Developer/dotfiles/.git/config
```

A clean backup of the config is preserved outside the repo.

---

## 6. What to do next

1. **Wait for the tripwire to fire.** It converts a silent corruption into an
   immediate `Operation not permitted` at the moment of the write. Whatever
   process breaks is the culprit — capture its full output and stack.

2. **Add the `core.bare` assertion** to `test-git-config-hygiene.sh` (snippet in
   §3). Without it, a green detector is not a clean bill of health.

3. **Do not rely on the pre-push hook to catch this.** It already runs the
   detector — but an empty `core.hooksPath` disables the hook, so the check
   cannot fire in exactly the state it exists to detect. Any guard against this
   must live somewhere `core.hooksPath` cannot switch off: the CI workflow
   (which does run it, and is the reason to watch CI results), a LaunchAgent, or
   the `chflags` tripwire now in place.

4. **Consider snapshot-and-restore around the suite.** Have the test runner
   snapshot `.git/config` before and diff after, failing loudly on any change.
   That converts silent corruption into a loud, attributable diff even if the
   tripwire is lifted for legitimate work.

### Open question worth answering

Why did the write happen at **17:07:24** specifically? That is inside the
backlog session but *before* the agent worktree existed. Identifying what ran
in that window — the session was running the dotfiles test suite around then —
is the most direct remaining lead.

---

## 7. Reference

- Issue: smartwatermelon/dotfiles#239 (reopened 2026-08-24)
- PR: smartwatermelon/dotfiles#241 (`01214a8f0efb`, merged 2026-08-24 12:30:54 PDT)
- Detector: `bash/tests/test-git-config-hygiene.sh`
- Prime suspects, both disproved: `bash/tests/test-pre-push-stale-ci.sh:36-49`
  (`setup_repo`), `bash/tests/test-gh-wrapper-identity.sh:100-108`
  (`assert_desired_in`)
