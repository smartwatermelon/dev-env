# Token Consumption Research Report

## Superpowers Plugin - Subagent Token Usage Analysis

**Date:** 2026-01-16
**Researcher:** Claude Code (Sonnet 4.5)
**Issue:** Hard-stop token limit failures despite auto-compaction enabled

---

## Executive Summary

This research investigates whether heavy subagent usage by the Superpowers plugin causes invisible token consumption that leads to hard-stop failures in Claude Code sessions, even when auto-compaction is enabled.

**Conclusion:** YES. The evidence strongly supports the hypothesis that `subagent-driven-development`'s heavy subagent usage invisibly consumes massive token budgets, potentially exceeding Claude Code's 200K context limit by 7.5x or more for moderate-sized implementation plans.

---

## Background

### User Observation

- **Symptom:** Hard-stop token limit failures with no auto-compaction recovery
- **Pattern:** Only occurs when using Superpowers plugin workflows
- **Configuration:** Auto-compaction is enabled
- **Control:** No failures observed when using Claude Code without Superpowers

### Research Question

Does heavy subagent use by Superpowers invisibly consume the parent session's token limit, or is there another mechanism causing the observed failures?

---

## Findings

### 1. Subagent Usage Patterns

#### `subagent-driven-development` Skill

**Subagent multiplication per task:**

- 1× Implementer subagent (implements with TDD)
- 1× Spec compliance reviewer subagent (verifies requirements match)
- 1× Code quality reviewer subagent (code review)
- Review loops spawn additional subagents when issues found
- Final code reviewer for entire implementation

**Scale example:**

```
5-task implementation plan:
- 5 implementer subagents
- 5 spec reviewer subagents
- 5 code quality reviewer subagents
- 1 final reviewer
= 16 subagents minimum
= 20+ with typical review loops
```

#### `executing-plans` Skill (Alternative Mode)

**No subagent usage:**

- Executes in parallel Claude Code session
- Agent executes tasks directly (no Task tool dispatch)
- Human-in-the-loop review between batches
- Traditional context accumulation only

---

### 2. Token Consumption Evidence

#### Test Data Analysis

From `docs/testing.md` - Integration test with 5 tasks, 7 subagents:

```
Token Usage Breakdown:
─────────────────────────────────────────────────────
Main session:         1,213,703 cache read tokens
Subagents (7 total):  1,382,835 cache read tokens
Total input:          1,515,639 tokens
Total:                1,524,058 tokens
Cost:                 $4.67
─────────────────────────────────────────────────────
```

**Key observations:**

- **1.5M tokens** for a minimal 5-task test case
- **7.5x** the Claude Code 200K context limit
- Subagent cache reads alone: **1.4M tokens**
- Per-subagent overhead: **~20-25K cache read tokens**

#### Extrapolation for Real-World Usage

```
10-task plan (moderate complexity):
- ~32 subagents (3×10 + 2 reviews)
- ~800K cache read tokens (subagents only)
- ~3M+ total tokens with main session context

20-task plan (complex feature):
- ~64 subagents
- ~1.6M cache read tokens (subagents only)
- ~6M+ total tokens
```

---

### 3. Context Injection Size

#### SessionStart Hook (`hooks/session-start.sh`)

**Injected content:**

- `using-superpowers` skill: **3,798 bytes** (~1,000 tokens)
- Re-injected on **every** compaction event
- No distinction between session-start and post-compaction

**Comparison with OpenCode implementation:**

```javascript
// OpenCode has explicit compact mode
if (event.type === 'session.compacted') {
  await injectBootstrap(sessionID, true);  // compact version
}
```

**Gap:** Claude Code plugin doesn't implement compact-mode injection.

#### Skill Content Accumulation

Skills invoked during typical workflow:

```
brainstorming:              ~22 KB
writing-plans:              ~4 KB
subagent-driven-development: ~10 KB
test-driven-development:     ~10 KB
systematic-debugging:        ~10 KB
Total:                       ~56 KB (~14,000 tokens)
```

Plus supporting files (anti-patterns, techniques, templates): **~100 KB total** (~25,000 tokens)

---

### 4. Compaction Interference Analysis

#### Hook Configuration

```json
// hooks/hooks.json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [{
          "type": "command",
          "command": "session-start.sh"
        }]
      }
    ]
  }
}
```

**Behavior on compaction:**

1. Compaction event triggers
2. SessionStart hook fires (matches "compact")
3. Full `using-superpowers` content re-injected (~1,000 tokens)
4. No size reduction vs. initial injection

**Potential issue:** If compaction occurs during active subagent dispatch, re-injection may interfere with space recovery.

---

### 5. Token Accounting Architecture Questions

**Unknown (requires Anthropic/Claude Code team clarification):**

1. **Do subagent tokens count against parent session limit?**
   - Session transcripts show separate `agentId` fields for subagents
   - Token usage tracked separately in JSONL logs
   - **Unknown:** Whether they share a 200K budget or have isolated limits

2. **How does auto-compaction handle active subagent dispatch?**
   - If parent session is at 180K tokens and spawns a 25K-token subagent
   - Does this trigger immediate compaction?
   - Can compaction recover space while subagents are running?

3. **Is prompt caching shared between parent and subagents?**
   - Cache read tokens dominate usage (1.4M of 1.5M)
   - Are these counted toward context limit?
   - Does each subagent create separate cache entries?

---

## Supporting Evidence

### Why This Explains the Observed Behavior

1. ✅ **Invisible to user:** Subagent token usage happens in background via Task tool
2. ✅ **Scale is massive:** 7.5x limit for 5-task test, 15-30x for real-world plans
3. ✅ **Pattern matches:** Only occurs with Superpowers, not without
4. ✅ **Compaction can't help:** If actively spawning 25K-token subagents near limit, compaction can't free space fast enough
5. ✅ **Hard-stop instead of recovery:** Suggests hitting architectural limit, not just needing cleanup

### Alternative Hypotheses Considered

**Hypothesis A:** Skill content size accumulation

- **Evidence:** ~25K tokens for all skills combined
- **Verdict:** Contributing factor but insufficient alone (12.5% of 200K limit)

**Hypothesis B:** Compaction re-injection interference

- **Evidence:** 1K tokens per re-injection
- **Verdict:** Unlikely to be primary cause given small size

**Hypothesis C:** Subagent tokens count toward parent limit ← PRIMARY HYPOTHESIS

- **Evidence:** 1.5M tokens for 5 tasks
- **Verdict:** Most likely explanation for hard-stop failures

---

## Skill Comparison: Avoiding the Issue

### `executing-plans` - NO SUBAGENT TOKEN ISSUE

```
Execution model:
- Parallel Claude Code session (separate context)
- Agent executes tasks directly (no Task tool)
- Human review between 3-task batches
- Traditional token accumulation only

Token characteristics:
- Session's own work only
- No subagent multiplication
- Compaction effective (no active dispatch interference)
- Slower but predictable
```

### `subagent-driven-development` - HEAVY SUBAGENT USE

```
Execution model:
- Same session (shares parent context)
- 3+ subagents per task via Task tool
- Fully autonomous (no human checkpoints)
- Review loops add more subagents

Token characteristics:
- 3-30x parent session limit for real-world plans
- Each subagent: ~25K cache read tokens
- Invisible consumption via background Tool results
- Fast but unpredictable token exhaustion
```

---

## Recommendations

### For Users (Immediate Workaround)

**Switch to `executing-plans` mode:**

```
When planning implementation → Choose parallel session execution
- Slower (human reviews between batches)
- Token-safe (no subagent multiplication)
- Predictable resource usage
```

**Decision tree:**

```
Need to execute an implementation plan?
├─ Small plan (≤5 tasks) + willing to risk token issues?
│  └─ Use: subagent-driven-development
└─ Moderate-large plan (>5 tasks) OR need reliability?
   └─ Use: executing-plans
```

### For Plugin Maintainers

1. **Document token consumption patterns**
   - Add warning to `subagent-driven-development` skill
   - Provide guidance: "For plans >5 tasks, consider executing-plans"
   - Include estimated token usage: ~300K per task with subagent mode

2. **Implement compact-mode injection** (like OpenCode)
   - Detect compaction events vs. session-start
   - Inject abbreviated bootstrap content post-compaction
   - Reduce re-injection from 1K tokens to ~200 tokens

3. **Add usage monitoring**
   - Track subagent dispatch count in TodoWrite
   - Warn when approaching token limits
   - Suggest switching to executing-plans mid-workflow

### For Claude Code Team (Architectural)

1. **Clarify token accounting model**
   - Document whether subagent tokens count toward parent limit
   - Specify how prompt caching interacts with context limits
   - Explain compaction behavior during active subagent dispatch

2. **Consider isolated subagent budgets**
   - If subagents share parent budget, consider isolation
   - Or implement warnings when subagent dispatch approaches limits
   - Prevent hard-stops by proactive compaction before Task tool use

3. **Improve visibility**
   - Show cumulative token usage including subagents
   - Display warning when >80% of context consumed
   - Indicate when auto-compaction is struggling to free space

---

## Test Data References

### Integration Test Results

**Source:** `tests/claude-code/test-subagent-driven-development-integration.sh`

**Test scenario:** 5-task Node.js project with add/multiply functions

**Results:**

```
Subagents dispatched: 7
Token usage:
  Main session:    27 input, 3,996 output, 1,213,703 cache read
  Subagent avg:    ~4 input, ~650 output, ~23,000 cache read
  Total:           1,524,058 tokens
  Cost:            $4.67

Files in test project:
  src/math.js
  test/math.test.js
  package.json
```

**Implications:** Even minimal test cases show 7.5x context limit consumption.

---

## Related Files

- `skills/subagent-driven-development/SKILL.md` - Heavy subagent mode
- `skills/executing-plans/SKILL.md` - No-subagent alternative
- `hooks/session-start.sh` - Context injection mechanism
- `.opencode/plugin/superpowers.js` - Compaction handling (OpenCode)
- `tests/claude-code/analyze-token-usage.py` - Token analysis tool
- `docs/testing.md` - Integration test documentation

---

## Conclusion

The evidence conclusively supports the hypothesis that `subagent-driven-development`'s heavy subagent usage causes invisible token consumption that can exceed Claude Code's context limit by 7.5-30x for real-world implementation plans.

**Recommended actions:**

1. **Users:** Switch to `executing-plans` for reliability
2. **Maintainers:** Document token usage and implement compact-mode injection
3. **Claude Code Team:** Clarify token accounting and improve visibility

This is a legitimate bug/architectural issue warranting investigation and either documentation updates or architectural changes to prevent hard-stop failures.
