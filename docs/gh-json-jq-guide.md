# `gh --json` / `--jq`: a working guide

Written 2026-08-25 while building `scripts/open-prs.sh`.

## The one trick worth knowing first

**Pass a bogus field name and `gh` prints every valid field for that command.**

```
$ gh search prs --json statusCheckRollup
Unknown JSON field: "statusCheckRollup"
Available fields:
  assignees  author  authorAssociation  body  closedAt  commentsCount
  createdAt  id  isDraft  isLocked  isPullRequest  labels  number
  repository  state  title  updatedAt  url
```

That is faster than any documentation, and it is authoritative for the version
of `gh` you actually have installed. Use `--json x` as a discovery command.

Field sets differ per command — `gh pr list` exposes `statusCheckRollup` and
`mergeable`, `gh search prs` does not. Do not assume a field carries over.

## `--json` vs `--jq` vs `--template`

- `--json a,b,c` — pick fields. Output is always a **JSON array of objects**
  (or a single object for `view` commands). Required before `--jq` will work.
- `--jq 'EXPR'` — run a jq filter over that JSON, in-process. No `jq` binary
  needed, no pipe.
- `--template 'EXPR'` — Go templates. Better for tables and colour; jq is
  better for reshaping. Ignore it until you need `tablerow`.

`--jq` and piping to `jq` are equivalent in behaviour. Prefer `--jq` for
portability and because it avoids quoting the pipe.

## The gotcha that started this

```bash
gh repo list --no-archived --source --json nameWithOwner,pullRequests
```

Two problems:

1. **`pullRequests` gives you only `{"totalCount": N}`.** There is no path from
   `gh repo list` to PR titles or numbers. The field is a count and nothing
   more. (It does count *open* PRs only — verified against a repo with 1 open
   and 26 total.)
2. **Bare `gh repo list` means "my own repos".** Org repos are silently absent.
   You have to name the org: `gh repo list nightowlstudiollc`. There is no
   "all owners I can see" mode, and the omission is invisible — the command
   succeeds and returns a plausible-looking list.

**Use `gh search prs` instead.** It takes repeated `--owner` flags, covers
every owner in one API call, and returns real PR fields:

```bash
gh search prs --state open --archived=false \
  --owner smartwatermelon --owner nightowlstudiollc \
  --json repository,number,title --limit 200
```

`--archived=false` drops PRs in archived repos, which cannot be merged anyway.
Note the equals sign — see the boolean-flag section below; the space form
silently returns nothing.

## Recipes

### One line per repo, PRs joined

```bash
gh search prs --state open --archived=false --owner ORG1 --owner ORG2 \
  --json repository,number,title --limit 200 \
  --jq 'group_by(.repository.nameWithOwner)
        | map("\(.[0].repository.nameWithOwner): "
              + (map("#\(.number) \(.title)") | join(" | ")))
        | .[]'
```

The shape to internalise: `group_by` returns an **array of arrays**. Inside
`map`, `.[0]` is the first PR of a group (for the repo name, shared by all
members) and a nested `map` walks that group's PRs. Final `| .[]` unwraps the
array so each line prints bare instead of as JSON.

### Counts only

```bash
--jq 'group_by(.repository.nameWithOwner)
      | map("\(.[0].repository.nameWithOwner): \(length)") | .[]'
```

`length` inside `map` is the group's size, because each element *is* a group.

### Filter out dependabot

```bash
--jq 'map(select((.author.is_bot
        or (.author.login | test("dependabot|renovate|\\[bot\\]$"))) | not))'
```

Check **both** `is_bot` and the login pattern — app-authored PRs are not
reliably flagged `is_bot`. Note `\\[bot\\]` needs double backslashes inside a
shell double-quoted string.

### String interpolation

`"\(.field)"` inside a jq string. Not `${}`, not `+ .field` (which fails on
non-strings). For numbers, `"\(.number)"` converts automatically.

## Boolean flags need `=`, and getting it wrong fails silently

`gh search prs` takes `--archived` to filter on repository archived state. The
syntax matters more than it looks:

```
$ gh search prs --state open --owner ORG --json number --limit 200 -q length
18
$ gh search prs ... --archived=false ...     # equals form
16
$ gh search prs ... --archived false ...     # space form
0
```

The space form returns **zero results and exits 0**. Go's flag parser reads
`--archived` as a standalone boolean, then treats the bare `false` as a search
term — which matches nothing. No error, no warning, exit code 0. A script
written that way reports "no open PRs" and looks entirely correct.

`gh`'s own help example uses the equals form (`--archived=false`), which is the
tell. The same applies to any `{true|false}` flag in `gh search`.

Worth knowing what it filters: in this fleet the two hidden PRs were both
dependabot PRs in `smartwatermelon/headroom`, an archived fork — PRs that
cannot be merged and are pure noise in a review queue.

## Things that cost me time

- **`--jq` output is not JSON by default.** Once your filter produces strings,
  you get raw lines — which is what you want for a CLI, but means you cannot
  pipe it into another `jq` without re-parsing.
- **`--limit` defaults low** (30 for search). Set it explicitly or you will
  silently truncate and never know.
- **`select()` inside `map()` vs at top level.** `map(select(...))` filters an
  array and keeps it an array. Bare `.[] | select(...)` emits a stream. Mixing
  these up produces "Cannot index array with string" errors.
- **`gh pr list` is per-repo.** For a cross-repo view you need `gh search prs`,
  which is a different command with a different — and smaller — field set.

## Where the script lives

`~/Developer/scripts/open-prs.sh` — modes: `--mine`, `--bots`, `--count`,
`--urls`. Owners are a single array at the top of the file.
