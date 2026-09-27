# Design: Separate agent identity and a mobile merge gate

Status: DRAFT, 2026-09-27. Not scheduled. Starts after the 2026-09-30 hard
stop, and after the org-migration support ticket and the Team → Free downgrade
of `smartwatermelon` are resolved.

## Purpose

Let Andrew approve an agent's merge from a phone, with an approval the agent
cannot forge.

`merge-lock.sh` works at the desktop. It does not work from mobile, and it does
not reach cloud sessions at all: a Claude Code on the web container has no
`~/.claude/hooks`, and it has `mcp__github__merge_pull_request`. Verified
2026-09-27.

## The problem this solves

**Every credential the agent holds today is Andrew's.** On 2026-09-27 the
cloud session's GitHub MCP `get_me` returned `twistedmelonman`, and that
account is the only collaborator on `smartwatermelon/dev-env`, with role
`admin`. The desktop `GH_TOKEN` and the three per-owner fine-grained PATs are
also `twistedmelonman` tokens (see `STATUS.md`, "Measuring fleet state").

So any approval made with Andrew's GitHub or Slack identity, the agent can also
make: PR reviews, deployment approvals, comments, ruleset edits, a reply in a
Slack DM.

## Rejected: a Slack reply as the approval

Tested 2026-09-27 in `lolsob.club`. Messages posted through the Slack connector
show Andrew as the author, with a `Sent using @Claude` footer that the agent
cannot remove. Andrew's own messages have no footer.

Rejected as a gate:

- **It checks for a missing marker.** Any path that posts as Andrew without
  going through the connector has no footer: Claude in Chrome or computer use
  typing into Slack, any other integration holding a user token.
- **The gated party would read the gate.** If the agent reads the DM and
  decides "approved", nothing outside the agent checks it.
- **It authenticates the account, not the person.**
- **It is not tied to a commit.** "approved" does not name a head SHA.

## Rejected: GitHub App check plus a Slack button endpoint

A dedicated GitHub App posts a `merge-authorized` check run after a signed
Slack button click, and a ruleset requires that check from that App. This
works, but it needs a hosted endpoint, two stored secrets, and custom code.
Rejected as too complex for the problem. The Slack part survives as an
optional front end (see "Side note" below).

## Decision: a machine account for the agent, native GitHub review

1. Create one **machine account** for the agent. The GitHub Terms of Service
   allow "no more than one free machine account in addition to your free
   Personal Account", used only for automated tasks. One account covers all
   three owners: it is an ordinary user account, and orgs have members, not
   accounts of their own.
2. Grant it **write**. It is never an org owner, never admin.
   - Org repos (`smartwatermelon`, `nightowlstudiollc`): repo role `write`.
   - Personal repos (`twistedmelonman`): collaborator. Personal-repo
     collaborators always get write and cannot be made admin.
3. On each gated default branch:
   - require 1 approving review
   - dismiss stale approvals on new push
   - require approval of the most recent reviewable push
   - **do not allow bypass**, so org owners and admins are also blocked
4. The agent opens PRs as the machine account. Andrew approves in the
   **GitHub mobile app** as `twistedmelonman`. The machine account cannot
   approve its own PR and cannot change protection.
5. Move every credential the agent uses from `twistedmelonman` to the machine
   account: the claude.ai GitHub connection, desktop `gh auth`, `GH_TOKEN`,
   and the per-owner PATs.

A new push resets the approval, so the gate binds to a commit without a TTL.
It covers `gh`, the GitHub MCP, and the web UI, from desktop or cloud.

## Where the gate works

Protected branches and required reviewers on **private** repos need GitHub Pro
(personal) or Team (org). On Free, they apply to public repos only.

| Owner | Target plan | Target visibility | Gate |
| --- | --- | --- | --- |
| `smartwatermelon` | Free | all public | Yes |
| `nightowlstudiollc` | Team | public and private | Yes. The machine account probably takes a paid seat. |
| `twistedmelonman` | Free | public | Yes. A private repo here has no gate unless it moves or Pro is bought. |

Target state: move the private `smartwatermelon` repos to `nightowlstudiollc`
before the downgrade. On a free private repo a write collaborator can merge
its own PR, so a private repo left on a free owner has no gate.

## Conditions for the gate to hold

1. **No `twistedmelonman` credential is reachable by the agent.** One left
   behind makes the gate decorative.
2. **Repo secrets are a bypass path.** A write account can push a branch that
   adds a workflow, and push-event workflows on same-repo branches get the
   repo's secrets. If any secret is a `twistedmelonman` PAT that can review
   PRs, that workflow can approve its own PR. Mitigations, strongest first:
   - the machine account's token has no `workflow` permission, so it cannot
     push `.github/workflows/` changes
   - PAT secrets move to environment secrets restricted to `main`
   - PATs are replaced by App tokens that cannot review (see the Dependabot
     digest App plan, `docs/plans/2026-09-11-dependabot-digest-github-app.md`)
3. **"Allow GitHub Actions to create and approve pull requests" stays off.**
   Otherwise a workflow the agent writes can approve with `GITHUB_TOKEN`.
4. **Keep Claude in Chrome and computer use away from github.com and Slack**
   where Andrew is signed in. A click there is Andrew's click.

## Open questions

- **Dependabot auto-merge.** The current template has 0 required approvals and
  `enforce_admins: false` (W0). Requiring 1 approval stalls
  `dependabot-auto-merge.yml`. Options: Andrew approves Dependabot PRs from the
  digest, or a narrowly scoped App approves only Dependabot-authored PRs.
  Condition 3 rules out `GITHUB_TOKEN` approval.
- **Direct pushes to `main`.** No bypass also blocks Andrew's own direct
  pushes (for example `870728f`). Intended, but confirm.
- **`merge-lock.sh`.** Keep it as a second desktop check, or retire it once
  the review gate is live.
- **Fleet count.** `STATUS.md` counted 6 non-archived `twistedmelonman` repos
  on 2026-09-16; 5 are the retired paths. Identify the sixth and its
  visibility.
- **Rulesets vs classic protection.** The rulesets docs name only Team and
  Enterprise. Test on one free public repo; if rulesets are not available,
  use classic branch protection, which the fleet already uses.

## Superuser mode (desktop only)

Normal work runs as the machine account. Infrastructure work that needs admin
(protection, secrets, repo creation, org settings) runs in a short **superuser
mode** on the desktop, with Andrew present, using his admin token.

The split is real only if the admin token cannot be reached in normal mode.
On the desktop the agent runs as Andrew's OS user, so any token on disk, in
the keyring or in the environment is readable in every session. Today that is
true of both `GH_TOKEN` (loaded from 1Password at shell start) and the `gho_`
keyring token that the F4 escape hatch uses.

Requirements:

1. **No admin token at rest.** Log `twistedmelonman` out of the `gh` keyring.
   Normal shells get only the machine account's token.
2. **The admin token comes from 1Password with biometric unlock**, for one
   command or one session (`op run -- gh ...`, or `op read` into one
   command's environment). Each new authorization needs Andrew's Touch ID.
   A CLI authorization stays valid for a while after unlock (about 10 minutes
   idle, per terminal session; confirm before relying on it), so end the mode
   with `op signout`, not by waiting.
3. **Desktop only.** The claude.ai GitHub connection stays on the machine
   account; cloud sessions never hold admin.
4. **Settings, not merges.** No-bypass protection blocks admins too, so merges
   still go through Andrew's review in the GitHub app. In superuser mode the
   agent acts as Andrew and could approve PRs, so the mode is not used for
   PR work.

Accepted risk: while the mode is on, the only control is Andrew watching. The
local hooks removed below are not there as a backstop. Keep sessions short
and focused.

Optional: log every command run with the admin token, in the manner of
`blocked-audit.sh`, for review afterwards.

## What this lets us remove

Classified against the inventory in `docs/WORKFLOW-DEEP-DIVE.md` ("File
Inventory"). **Remove only after every repo the agent works in is at the
target state.** Until then, the local merge lock is the only control on the
rest.

Removable, because GitHub enforces it server-side:

- `merge-lock.sh`, `hook-block-merge-lock-authorize.sh`,
  `hook-block-merge-lock.sh`, `hook-block-merge-locks-write.sh`
- `hook-block-api-merge.sh`, and with it the newline-bypass gap
  (claude-config#137). An API or GraphQL merge still needs the review.
- The `main` checks in the `pre-push` git hook: no-bypass protection rejects
  the push. `hook-block-main-commit.sh` becomes optional, since a local commit
  on `main` cannot leave the machine.
- Most of the `gh` wrapper's identity routing (F3 guard, F4 escape hatch):
  one identity, no admin scope, nothing to route.
- CLAUDE.md rules such as "never merge without auth" and "never push to
  `main`".

Stays, because it does not depend on who holds admin:

- `run-review.sh` and the `pre-commit` review (code quality)
- `hook-block-no-verify.sh` and `hook-block-short-no-verify.sh`, while local
  hooks are the quality gate
- `pre-merge-review.sh`: analysis, not authorization. Whether it becomes
  advisory is a separate decision.
- The worktree blocks, the secret-leak hook, the Personify gate, and
  `commit-msg`

Added: the four conditions under "Conditions for the gate to hold". They are
mostly one-time settings, not hooks to maintain.

Lost to the machine account, now done in superuser mode: W3-style
required-check changes, repo and org secrets, reading branch protection
(fleet probes), repo creation, org settings. **Do not switch before W3 is
done**, since W3 is admin work on the critical path.

## Order of work

0. W3 is done.
1. Support ticket 4746770 resolves; the retired paths move or stay.
2. Private `smartwatermelon` repos move to `nightowlstudiollc`.
3. `smartwatermelon` downgrades to Free.
4. Audit repo and org secrets for `twistedmelonman` PATs (condition 2).
5. Create the machine account, turn on 2FA, grant roles.
6. Apply the branch settings. Resolve the Dependabot question first.
7. Switch the agent's credentials; verify with `gh api user` and `get_me`.
8. Revoke the old `twistedmelonman` tokens the agent used. Log
   `twistedmelonman` out of the desktop `gh` keyring; set up the 1Password
   path for superuser mode.
9. Once every repo is at the target state, remove the tooling listed under
   "What this lets us remove".

## Side note: a Slack front end (optional, not required)

A Slack workflow that drives this would be nice to have: the agent posts
"PR ready for review" with the PR link, head SHA and CI state, and Andrew
taps through to approve. It is **not required**. The GitHub mobile app is
enough to approve, and the gate is the required review on GitHub, not
anything in Slack.

If built, Slack stays a notification and convenience layer only. A Slack
reply or button must never be the approval itself unless it runs through a
credential the agent does not hold (for example a signed Slack interaction
handled by a separate App), for the reasons in "Rejected: a Slack reply as
the approval".
