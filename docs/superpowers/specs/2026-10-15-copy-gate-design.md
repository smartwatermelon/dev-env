# Design: gate public-facing copy through the text gate

Status: APPROVED 2026-10-15 (all four decisions below). Not built. Part B of
dev-env#206.

Part A (claude-config#718, merged) made commit and PR text in private repos
under Andrew's own owners exempt. Andrew's note on part B: "public-facing text
like app copy or web site copy does need text approval ... it needs some
judgment, and I'm not sure how to apply that." Expect refinement.

## Problem

The gate reads text an agent hands to `git commit -F` or `gh ... --body-file`.
It never reads file contents. So an agent can rewrite the kebab.tax home page,
an App Store description, or a blog post, and the only gated text is the
one-line commit message about it. After part A, that commit message is exempt
too in kebab-tax, kebab-tax-netlify and night-owl-studio.

What the gate does today, from `claude-config/scripts/`:

- `gate-route.sh` routes by destination (`gate-rules.conf`, first match wins)
  to `pangram`, `visual` or `exempt`.
- `hook-block-personify.sh` (PreToolUse on Bash) finds the message file in the
  command and asks `gate-review.sh check` whether its bytes match an approval.
- `gate-review.sh open` shows staged text in BBEdit. Andrew types a STATUS
  word; the saved bytes are hashed and become the approval. Any later edit
  re-blocks.
- `pangram` mode also requires that personify's `pangram_check.py` ran on the
  exact bytes. The verdict is shown to the reviewer as information
  (`gate-review.sh`: "proof the check ran; the verdict is information"). The
  binding step is the human approval.

That last point answers part of "it needs some judgment". The gate does not
judge. It puts the text in front of Andrew with a Pangram verdict attached, and
he decides. Pangram also has a 40-word floor: shorter text gets exit 4,
SKIPPED, a record and no verdict. Button labels, alert titles, nav items and
fastlane `title.txt` / `keywords.txt` will all be SKIPPED. For them the gate is
visual-only in practice.

## What counts as public-facing copy

Text a person outside the repo reads in a shipped product: rendered web pages,
emails sent to users, in-app strings, store listings, release notes the app
fetches. Not copy: code, config, tests, CI, internal docs, design plans,
READMEs, generated output.

Inventory from `origin/main` of each checkout, 2026-10-15. Production sites
come from `scripts/site-monitor/sites.json`. "Text route" is what
`gate-rules.conf` returns for commit text today.

- **nightowlstudiollc/kebab-tax-netlify** (kebab.tax; private; text route
  exempt): `*.html` at root (`index`, `privacy`, `terms`, `support`,
  `tax-resources`, `txf-guide`, `changelog`); `emails/*.html`;
  `release-notes.json`; `APP_STORE_COPY.txt`; `MARKETING_POSTS.md`.
- **nightowlstudiollc/kebab-tax** (the app; private; exempt):
  `mobile/fastlane/metadata/**/*.txt` (minus the `*_url.txt` files);
  `docs/mobile/APP_STORE_COPY.md`; `docs/promo-email-templates.md`;
  `docs/beta-tester-thank-you-email.md`;
  `mobile/src/config/easterEggMessages.ts`; inline strings in
  `mobile/src/screens/*.tsx` and `mobile/src/components/**`.
- **nightowlstudiollc/night-owl-studio** (nightowlstudio.us; private;
  exempt): `index.html`, `local-websites.html`, `privacy.html`,
  `success.html`, `proposals/*.html`.
- **smartwatermelon/projectinsomnia** (public; pangram):
  `src/content/{blog,elections,ouatrevisit}/**`, `src/pages/*.astro`,
  `src/data/friends.json`.
- **smartwatermelon/crazy-larry** (public; pangram): `index.html`.
- **nightowlstudiollc/tnjcleaning** (client; public; pangram): `index.html`,
  `privacy.html`, `terms.html`, `thank-you.html`.
- **nightowlstudiollc/amelia-boone** (client; public; pangram):
  `src/data/blog/**`, `src/pages/about.md`, `src/pages/*.astro`,
  `src/drafts/**`.

Notes on the inventory:

1. kebab-tax has no i18n or strings file. App copy is inline JSX: 56 files
   under `mobile/src` contain `<Text`, and there are 170 `Alert.alert(` calls.
   Extracting copy from these is a parser problem, not a glob problem.
2. `release-notes.json` lives in kebab-tax-netlify, but the app's What's New
   modal shows it (header of `mobile/src/config/releaseNotes.ts`). It is app
   copy that ships through the web repo.
3. Excluded on purpose: amelia-boone `public/pagefind/**` (114 generated
   files) and `.astro/`; every `docs/plans/`, `README.md`, `CLAUDE.md`,
   `EDITING-COOKBOOK.md`; lockfiles.
4. jordan-paddock-pitch is not checked out under `~/Developer`. Its layout is
   not inventoried here.
5. The two client sites carry the client's voice, not Andrew's. The
   amelia-boone README tells Amelia to edit posts in the GitHub web UI. Those
   commits never pass a local hook, and should not: the gate is for agent
   writing.

Two axes, kept apart. The text route answers "who reads this commit message".
The copy list answers "does this file ship to the public". They are
independent. kebab-tax is private, so its commit text is exempt, and its App
Store description is still public copy. A copy check must not ask
`gate-route.sh` and stop at `exempt`. The precedent for overriding an owner
rule already exists: projectinsomnia and crazy-larry carry `repo=... pangram`
above `owner=smartwatermelon exempt`.

## Options

### Option 1: copy-path globs, checked at `git commit` (PreToolUse)

A new conf, `copy-paths.conf`, deployed from claude-config next to
`gate-rules.conf`:

```text
# <owner/repo> <include|exclude> <glob>
nightowlstudiollc/kebab-tax-netlify include *.html
nightowlstudiollc/kebab-tax-netlify include emails/*.html
nightowlstudiollc/kebab-tax-netlify include release-notes.json
nightowlstudiollc/amelia-boone      exclude public/pagefind/**
```

When `hook-block-personify.sh` sees `git commit` (it already resolves the
repo from a literal `-C` path or the cwd), it also:

1. Reads the repo's origin and finds its entries in `copy-paths.conf`. No
   entries: done, no change from today.
2. Lists staged files (`git diff --cached --name-only`) and matches them
   against the globs, excludes last.
3. For each match, extracts the copy: added lines of the staged diff, or the
   whole staged blob for a new file. HTML and Markdown are stripped to text.
   JSON keeps string values only.
4. Writes the extract to one deterministic file and calls `gate-review.sh
   check --kind copy` on it. No approval: block, and print the
   `pangram_check.py` and `gate-review.sh stage` commands to run.

The approval binds to the extract's hash, so editing the copy after approval
re-blocks, as commit text does now. The same extractor must produce the bytes
on both sides. `gate-review.sh` hashes with trailing whitespace stripped while
the Pangram record keys on raw bytes, so the extractor's output must be byte-
stable, or the check record never matches (the `echo |` trap in
`pangram_check.py`'s docstring).

Good: agent-only by construction, reuses the whole approval path, no new
human channel. Bad: it inherits every known limit in `hook-block-personify.sh`
(regex, not a shell parser; bypassable). It only sees local Claude Code
sessions.

### Option 2: Option 1 plus string extraction for JSX and i18n

Same hook, plus an extractor for `.tsx`: text children of `<Text>`,
`title=` / `placeholder=` / `accessibilityLabel=` props, and string arguments
of `Alert.alert`. It needs a real parser (Babel or the TypeScript compiler),
since a regex over JSX will mis-split nested elements and template strings.
Most extracted strings fall under the 40-word floor, so Pangram adds little;
the value is that Andrew sees every changed user-facing string.

Good: covers the bulk of kebab-tax app copy. Bad: a Node dependency in the
hook path, and false positives on test IDs, log strings and enum labels. Worth
doing only after option 1 has run for a while.

### Option 3: a "copy review" PR label, enforced in CI

A reusable workflow job in `smartwatermelon/github-workflows` diffs the PR
against the same globs. If copy changed and the PR lacks a `copy-approved`
label, the check fails. Andrew adds the label after reading the diff.

Good: covers every path to the repo, including cloud sessions that commit
through the claude.ai GitHub connection and never run a local hook. Bad: no
Pangram verdict, approval binds to a label, not to bytes (a later push keeps
the label unless the job removes it on `synchronize`), and it costs Actions
minutes. It also blocks client edits made in the web UI unless the job skips
non-agent authors.

## Chosen design

Option 1 now, scoped to globs, with option 3 later as the backstop for cloud
sessions. Option 2 is phase 2 (decision 4).

Phase 1 covers every web page, email template, store listing and release-notes
file in the inventory. It does not cover inline JSX in kebab-tax. That gap is
named, not hidden: until option 2 exists, app-string changes are reviewed only
through the normal PR diff.

`copy-paths.conf` is central, in claude-config (decision 1). A tracked file
inside each repo could be edited by the agent in the same commit that adds the
copy. The fleet already ignores `.claude/`, and `hook-block-gate-dir-write.sh`
guards the gate's own files. Same reasoning.

Add a `copy` kind to `length_check.py` with no body cap. The existing caps (140
words for a commit body) exist to keep agent prose short, which is not the
point for a web page.

## Failure modes

1. **Conf unreadable or malformed.** Fail closed, as `_load_rules` does
   (return 4, empty rule set). The existing `SUSPENDED` file is the escape
   hatch.
2. **Repo has no conf entry.** Pass. The list is opt-in per repo, so a new
   site is ungated until someone adds it. `sites.json` is the checklist: a
   test can fail when a repo in `sites.json` has no entry.
3. **False positives on code.** Loose globs (`**/*.html`) catch generated and
   vendored files. Use explicit includes plus excludes, never "all HTML".
   Markup-only changes (a class name, an attribute) produce an empty text
   extract. An empty extract passes.
4. **Large diffs.** A new blog post or a rewritten `index.html` is long. No
   cap, but `gate-review.sh` batches per commit, so one large commit is one
   long review. A reformat that touches every line (Prettier) floods the
   review. Mitigation: extract text, not lines, and compare against the old
   text, so whitespace-only changes extract to nothing.
5. **Client voice.** On amelia-boone and tnjcleaning the text is the client's.
   Pangram measures whether text reads as machine-written, which still matters
   there. VOICE.md is a drafting input to the personify skill, not something
   the gate applies, so the gate itself is voice-neutral.
6. **Bypass paths.** Cloud sessions, the GitHub web UI, and a human commit in a
   terminal all skip a PreToolUse hook. The global `~/.config/git/hooks/pre-
   commit` has no agent detection today (no `CLAUDECODE` check found), so
   moving the check there would gate Andrew's own terminal commits too.
7. **Pangram unavailable.** `pangram_check.py` exits 5 and writes no record.
   On a `pangram` copy route that blocks, the same as for commit text.

## Decisions (2026-10-15)

Andrew accepted the recommended answer on all four.

1. **Where the list of copy paths lives: one central file in claude-config.**
   Rejected: a file in each repo, or both. A per-repo file can be edited by
   the agent in the same commit as the copy.
2. **What is shown for approval: only the added or changed text, and the whole
   file when the file is new.** Rejected: the whole changed file every time,
   which makes a one-word fix a long review.
3. **Client sites (amelia-boone, tnjcleaning) are gated like Andrew's own:
   Pangram plus his approval, for agent commits only.** Rejected: approval
   without Pangram, or no gate. Client edits in the GitHub web UI stay
   ungated, since they never pass a local hook.
4. **In-app strings in the kebab-tax code are gated in phase 2.** Phase 1
   gates store listings, emails, release notes and web pages. Until phase 2,
   app string changes are seen only in the PR diff.
