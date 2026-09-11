# Bug Report: Hard-Stop Token Limit Failures with subagent-driven-development

## Summary

Using the `subagent-driven-development` skill causes hard-stop token limit failures in Claude Code sessions, even when auto-compaction is enabled. This appears to be caused by invisible token consumption from heavy subagent usage exceeding the 200K context limit.

---

## Environment

- **Claude Code Version:** [Your version]
- **Plugin:** Superpowers v4.0.3
- **OS:** macOS / Linux / Windows
- **Auto-compaction:** Enabled in settings
- **Skill Used:** `subagent-driven-development`

---

## Steps to Reproduce

1. Install Superpowers plugin via marketplace
2. Enable auto-compaction in Claude Code settings
3. Create an implementation plan with 10+ tasks (using `writing-plans` skill)
4. Execute the plan using `subagent-driven-development` skill
5. Observe session behavior as tasks are implemented

---

## Expected Behavior

- Auto-compaction should activate when approaching token limits
- Session should continue operating without hard-stop failures
- User should receive warnings before hitting limits
- Token usage should be visible to the user

---

## Actual Behavior

- Session hits hard-stop token limit failure
- No auto-compaction recovery occurs
- No prior warnings about token consumption
- Session becomes unusable and cannot continue
- Subagent token usage is invisible to user

---

## Evidence

### 1. Test Data Shows Massive Token Consumption

From Superpowers integration tests (`docs/testing.md`):

**5-task minimal test case:**

```
Total tokens: 1,524,058
- Main session:  1,213,703 cache read tokens
- 7 subagents:   1,382,835 cache read tokens
```

**Analysis:**

- 1.5M tokens for just 5 tasks
- 7.5x the 200K Claude Code context limit
- Real-world 10-task plan: ~3M tokens (15x limit)
- Real-world 20-task plan: ~6M tokens (30x limit)

### 2. Subagent Multiplication Pattern

`subagent-driven-development` spawns **3+ subagents per task:**

```
Per task:
1. Implementer subagent (~25K tokens)
2. Spec compliance reviewer subagent (~25K tokens)
3. Code quality reviewer subagent (~25K tokens)
+ Review loops when issues found (additional subagents)
+ Final reviewer (25K tokens)

10-task plan = ~32 subagents = ~800K tokens from subagents alone
```

### 3. Pattern Only Occurs with Superpowers

**With Superpowers:**

- Hard-stop failures occur regularly
- Specifically when using `subagent-driven-development`
- Auto-compaction does not prevent failures

**Without Superpowers:**

- No token limit failures observed
- Auto-compaction works as expected
- Normal Claude Code usage is stable

---

## Root Cause Analysis

### Hypothesis: Subagent Tokens Count Against Parent Session Limit

**Supporting evidence:**

1. **Scale matches observed failures:**
   - 7.5-30x context limit consumption for typical plans
   - Hard-stops suggest hitting architectural limit, not just needing compaction

2. **Invisible consumption:**
   - Subagent usage via Task tool happens in background
   - No visibility into cumulative token usage
   - User has no way to monitor or prevent exhaustion

3. **Compaction cannot recover:**
   - If actively spawning 25K-token subagents near limit
   - Compaction can't free space fast enough
   - New subagents added faster than old context removed

### Architectural Questions Requiring Clarification

**Need answers from Claude Code team:**

1. Do subagent tokens (via Task tool) count against the parent session's 200K limit?
2. How does auto-compaction behave when subagents are actively being dispatched?
3. Are prompt cache read tokens (1.4M in test) counted toward context limit?
4. Should there be isolated token budgets for subagents vs. parent session?

---

## Comparison: Alternative Skill Avoids Issue

### `executing-plans` - No Subagent Usage ✅

```
Execution model:
- Parallel Claude Code session
- Agent executes tasks directly (no Task tool)
- Human review between batches
- Traditional token accumulation only

Result: No token limit failures observed
```

### `subagent-driven-development` - Heavy Subagent Usage ❌

```
Execution model:
- Same session as user
- 3+ subagents per task via Task tool
- Fully autonomous execution
- Massive token multiplication

Result: Hard-stop failures on moderate-sized plans
```

**Decision criteria from skills:**

```
Have implementation plan?
└─yes→ Tasks mostly independent?
       └─yes→ Stay in this session?
              ├─yes→ subagent-driven-development (token-heavy)
              └─no→  executing-plans (token-safe)
```

---

## Additional Context

### Compaction Hook Gap

**Current implementation:** `hooks/hooks.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [{"command": "session-start.sh"}]
      }
    ]
  }
}
```

**Issue:** No distinction between session-start and post-compaction events

- Both inject full `using-superpowers` content (~1K tokens)
- OpenCode plugin has separate compact-mode injection
- Claude Code plugin could implement similar optimization

**OpenCode implementation for reference:**

```javascript
if (event.type === 'session.compacted') {
  await injectBootstrap(sessionID, true);  // compact version
}
```

---

## Impact

### User Experience

- **Workflow disruption:** Session becomes unusable mid-implementation
- **Data loss risk:** Work lost when session hard-stops
- **No recovery path:** Must restart in new session, losing context
- **Unpredictable:** Users can't anticipate when failures will occur
- **Reduced trust:** Users avoid Superpowers due to reliability issues

### Plugin Adoption

- Users may abandon Superpowers after failures
- Documentation doesn't warn about token consumption patterns
- Alternative mode (`executing-plans`) is safer but not promoted
- Negative reputation for an otherwise valuable tool

---

## Proposed Solutions

### Short-term (Documentation)

1. **Add warning to `subagent-driven-development` skill:**

   ```markdown
   ⚠️ TOKEN USAGE WARNING:
   This skill spawns 3+ subagents per task. For plans >5 tasks,
   consider using 'executing-plans' to avoid token limit issues.

   Estimated usage: ~300K tokens per task
   ```

2. **Update skill decision criteria:**
   - Recommend `executing-plans` for plans >5 tasks
   - Document token consumption patterns
   - Explain trade-offs between modes

3. **Create troubleshooting guide:**
   - "If you hit hard-stop failures, switch to executing-plans"
   - How to estimate token usage for your plan
   - When to use each execution mode

### Medium-term (Plugin Improvements)

1. **Implement compact-mode injection:**
   - Detect compaction events vs. session-start
   - Inject abbreviated bootstrap (~200 tokens) post-compaction
   - Follow OpenCode pattern

2. **Add usage monitoring:**
   - Track subagent dispatch count
   - Warn when approaching estimated limits
   - Suggest switching modes mid-workflow

3. **Provide visibility:**
   - TodoWrite shows: "16 subagents dispatched, ~400K tokens used"
   - Warning at 10+ subagents: "Consider reviewing progress"
   - Error-prevention instead of error-recovery

### Long-term (Claude Code Architectural)

1. **Isolated subagent token budgets:**
   - Don't count subagent tokens against parent session limit
   - Or provide much larger combined budget for subagent workflows
   - Or implement proactive warnings before Task tool dispatch

2. **Improved visibility:**
   - Show cumulative token usage including subagents
   - Display warning at >80% context consumption
   - Indicate when compaction is struggling

3. **Better compaction during active dispatch:**
   - Detect when subagents are being spawned
   - Proactively compact before Task tool invocations
   - Prevent hitting hard limits through prediction

---

## Workaround (Immediate)

**For users experiencing this issue:**

1. **Switch to `executing-plans` mode:**
   - Use when you have a written implementation plan
   - Works in parallel session (separate context)
   - No subagent multiplication
   - Requires human review between batches

2. **Or limit plan size when using `subagent-driven-development`:**
   - Keep plans to ≤5 tasks when using subagent mode
   - Break large features into multiple small plans
   - Execute each small plan separately

3. **Monitor for early warning signs:**
   - Session feeling "slower"
   - Tools taking longer to respond
   - May indicate approaching token limits

---

## Related Issues

- None found (please link if duplicates exist)

---

## Additional Data Available

If helpful, I can provide:

1. **Session transcripts** showing token usage patterns
2. **Reproduction test case** with minimal project
3. **Token analysis scripts** from the repository
4. **Detailed research report** (see `TOKEN-CONSUMPTION-RESEARCH.md`)

---

## References

- **Test data:** `tests/claude-code/test-subagent-driven-development-integration.sh`
- **Token analysis:** `tests/claude-code/analyze-token-usage.py`
- **Skills comparison:**
  - `skills/subagent-driven-development/SKILL.md`
  - `skills/executing-plans/SKILL.md`
- **Hook implementation:** `hooks/session-start.sh`, `hooks/hooks.json`
- **OpenCode compaction:** `.opencode/plugin/superpowers.js` (lines 206-212)

---

## Questions for Maintainers

1. Is this a known limitation of the Claude Code architecture?
2. Should the documentation explicitly warn about token consumption?
3. Are there plans to implement isolated subagent token budgets?
4. Would a PR implementing compact-mode injection be welcome?
5. Should `executing-plans` be the default recommendation over `subagent-driven-development`?
