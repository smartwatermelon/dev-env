# Task 6: fleet lint-debt re-measurement (2026-09-08)

Scanned 42 non-archived, non-oversized repos (`smartwatermelon` 25,
`nightowlstudiollc` 12, `twistedmelonman` 5 pinned repos), same enumeration
and disk-size filter (`diskUsage > 200000` excluded) as
`bulk-install-standards-check.sh` uses. Each repo: shallow-cloned to a temp
dir, `run-standards.sh --repo` run locally, log retained, clone deleted.
Read-only against GitHub throughout.

Linter versions (local, match plan pins exactly): shellcheck 0.11.0,
actionlint 1.7.12, zizmor 1.30.0, yamllint 1.38.0, markdownlint-cli2 0.23.2.
`github-workflows` checkout: `main` @ `6f759f1`.

No clone or scan-script errors. All 42 repos exit 0 or 1 from
`run-standards.sh` (no crashes); every exit-1 row has a non-empty
failing-linter list.

42 = the plan's "37 non-pilot" repos + the 4 pilots (already members of that
same fleet, not additional) + `smartwatermelon/github-workflows` (also a
fleet member); the plan's own Live State table flagged that this number
needed re-measurement and this scan is that re-measurement.

## Pass/fail

| | Count |
| --- | --- |
| Pass (exit 0) | 8 |
| Fail (exit 1) | 34 |

Passing: `smartwatermelon/repo-template` (the clean pilot, as expected),
`smartwatermelon/github-workflows`, `smartwatermelon/claude-config-backup`,
`smartwatermelon/superpowers-marketplace`, `smartwatermelon/homebrew-tap`,
`smartwatermelon/x-thread-reader`, `smartwatermelon/crazy-larry`,
`nightowlstudiollc/vpn-lan-bridge`.

## Per-linter fail counts (of 42)

| Linter | Failing repos |
| --- | --- |
| shellcheck | 23 |
| zizmor | 17 |
| markdownlint | 16 |
| node-floor | 3 |
| yamllint | 2 |

## Top-3 worst repos by failing-linter count

- **5 linters:** `nightowlstudiollc/kebab-tax` (shellcheck, yamllint, zizmor, markdownlint, node-floor)
- **3 linters (four-way tie):** `twistedmelonman/claude-config`, `smartwatermelon/slack-mcp`, `smartwatermelon/lock-sync`, `smartwatermelon/claude-code-workflows-agents` (all: shellcheck, zizmor, markdownlint)

## Detail

- zizmor root-cause table, rule → repos → fix, `unpinned-uses` target breakdown, and the canonical-config-seeding verdict: `scan/zizmor-findings.md`.
- node-floor exact offending lines per repo: `scan/node-floor.md`.
- Raw data: `scan/summary.tsv` (`owner/repo<TAB>exit<TAB>failing-linters`), `scan/<owner>__<repo>.log` per repo.

## Notes for later tasks

- `nightowlstudiollc/networth-agent` is in `github-workflows/.standards-check-ignore` (install exclusion only); it was still scanned here per Task 6's enumeration and its result is in `summary.tsv` like any other repo — do not schedule a remediation PR for it without checking that ignore file first.
- `smartwatermelon/gmail-newsletter-filter` carries its own root `zizmor.yml`, a strict prefix of the canonical file (same `unpinned-uses`/`excessive-permissions` policy, missing three later ignore blocks). It passes zizmor in this scan regardless, so no action needed now, but it is config drift worth a mention in Task 10.
- **Task 10 gitcheck:** `dev-env/.superpowers/sdd/.gitignore` is a blanket `*` (confirmed: `git check-ignore -v` matches every file under `scan/`), and `git ls-files .superpowers/` returns nothing — no prior `sdd/` subdirectory has ever been committed to this repo. Task 10's instruction to "commit the `scan/` directory" will silently stage nothing unless it force-adds (`git add -f`) or adds a `!2026-09-08-w2-fleet-rollout/scan/` negation to that `.gitignore`. Flagging for Task 10, not fixed here (out of Task 6 scope).
