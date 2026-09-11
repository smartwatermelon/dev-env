# Superpowers token-consumption research

Preserved 2026-09-11 from `~/Developer/superpowers`, a local clone of
`obra/superpowers` that was removed as part of retiring two forked copies.
These files were **untracked** in that clone — no commit, no remote, no other
copy. They are the origin of the context-overload work and are kept here
because deleting the clone would have destroyed them.

## What's here

| File | Date | What it is |
| --- | --- | --- |
| `TOKEN-CONSUMPTION-RESEARCH.md` | 2026-01-16 | Measurement of subagent token usage under `subagent-driven-development`; the original investigation |
| `DRAFT-BUG-REPORT.md` | 2026-01-16 | Unsent bug report: hard-stop token failures despite auto-compaction |
| `HOOK-ANALYSIS-TOKEN-DETECTION.md` | 2026-01-16 | Whether any hook can detect incipient token exhaustion. Conclusion: no |
| `HOOK-IMPLEMENTATION-TOKEN-MONITORING.md` | 2026-01-16 | Follow-up design: parse session transcript JSONL in PostToolUse/SubagentStop |
| `hooks-backup-v6.3.0/` | 2026-09-11 | The superpowers v6.3.0 `hooks/` directory, removed from the plugin cache to stop SessionStart injection |

`CLAUDE.md` from that clone was **not** preserved — it was upstream's
contributor guidance, not original research.

## Why the hooks backup exists

superpowers v6.3.0 ships a `SessionStart` hook that injects the full
`using-superpowers` SKILL.md into every session, on `startup|clear|compact`.
On 2026-07-31 that injection was removed in a personal fork
(`smartwatermelon/superpowers@18821ef`) by deleting the `hooks/` directory
outright, and the marketplace copy was pointed at that fork.

By 2026-09-11 the cache had moved to upstream v6.3.0 and the injection was
live again — the fork's fix was no longer in effect. Rather than maintain a
fork, the same removal was applied directly to the plugin cache at
`~/.claude/plugins/cache/superpowers-marketplace/superpowers/6.3.0/hooks`.
This backup is that directory, so the change can be inspected or reverted.

Both forked copies (`smartwatermelon/superpowers` and
`smartwatermelon/superpowers-marketplace`) were archived on 2026-09-11.

## Known fragility

The fix edits the **plugin cache**, which a superpowers update or reinstall
will overwrite, restoring the hook. The marketplace manifest points at
`obra/superpowers.git` and is refreshed on marketplace update, so there is no
durable pin either. If the injection returns, delete `hooks/` from the new
version's cache directory.

Tracked as [dev-env#126](https://github.com/smartwatermelon/dev-env/issues/126),
which asks the real question: build something that defeats the injection
durably, or stop using superpowers.

## Related issues, closed by this work

- [dev-env#63](https://github.com/smartwatermelon/dev-env/issues/63) asked why
  two superpowers repos existed and which was authoritative. Answered: both
  were detached forks of `obra/superpowers`, proven by shared root commit
  `dd013f6`. Nothing ever flowed upstream — `obra` returns 422 for the fork's
  own commits.
- [dev-env#64](https://github.com/smartwatermelon/dev-env/issues/64) held ten
  review findings that could not be filed because Issues was disabled on both
  repos. Archiving made them permanently unactionable, which closes the issue
  by construction rather than by fixing them.

Both issues carried a caveat that proved load-bearing: attributing findings by
the local checkout would have been wrong, because that checkout tracked
*upstream*, whose tree still has the `hooks/` directory. The same trap caught
this work from the other direction — the marketplace manifest points at
`obra/superpowers.git`, which reads as proof that nothing loads from the fork,
while the installed plugin's `gitCommitSha` was a fork-only commit.
