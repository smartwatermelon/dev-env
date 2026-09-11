# Hook Analysis: Token Exhaustion Detection

**Question:** Is there a Claude Code hook that can detect incipient token exhaustion before it happens (e.g., at 40% remaining / 160K tokens used)?

**Answer:** ❌ NO - No existing hook provides proactive token usage monitoring.

---

## Available Hooks Analysis

### Hooks Examined (10 Total)

From <https://code.claude.com/docs/en/hooks>:

1. **PreToolUse** - Before tool execution
2. **PermissionRequest** - Permission dialogs
3. **PostToolUse** - After tool completion
4. **UserPromptSubmit** - Before processing user input
5. **Stop** - When main agent finishes responding
6. **SubagentStop** - When subagent finishes responding
7. **PreCompact** ⚠️ - Before compaction runs (closest match)
8. **SessionStart** - Session initialization
9. **SessionEnd** - Session termination
10. **Notification** - System notifications

---

## Closest Match: PreCompact Hook ⚠️

### Configuration

```json
{
  "hooks": {
    "PreCompact": [
      {
        "matcher": "auto|manual",
        "hooks": [{
          "type": "command",
          "command": "your-script.sh"
        }]
      }
    ]
  }
}
```

### Matcher Options

- **`manual`** - Triggered by `/compact` command
- **`auto`** - Triggered when context is FULL and auto-compact runs

### Context Provided

```json
{
  "trigger": "manual" | "auto",
  "custom_instructions": "..." // only for manual
}
```

### Critical Limitation

**PreCompact only fires AFTER context is already full** (for auto-compact), not at a threshold like 40% remaining.

**Timeline:**

```
Token Usage:
0K ────────── 80K ────────── 160K ────────── 200K
              (40%)         (80%)          (FULL)
                                              ↑
                                    PreCompact fires here
                                    (too late for prevention)
```

**What you need:**

```
Token Usage:
0K ────────── 80K ────────── 160K ────────── 200K
                            (80%)
                              ↑
                   Hook fires here (proactive)
                   WARNING: 40% remaining
```

---

## Why No Hook Works for Your Use Case

### 1. No Token Metrics Exposed

**None of the hooks provide:**

- Current token usage count
- Remaining token budget
- Tokens consumed in this turn
- Cache read token counts
- Subagent token consumption

**Hook input structure (common fields):**

```json
{
  "session_id": "string",
  "transcript_path": "/path/to/session.jsonl",
  "cwd": "/path/to/project",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse"
  // ❌ NO token usage fields
}
```

### 2. Hooks Are Event-Based, Not Metric-Based

**Current hook triggers:**

- Tool use events (before/after)
- User actions (prompt submit)
- Agent lifecycle (start/stop)
- Compaction events (reactive)

**Not available:**

- Threshold-based triggers ("when tokens > X")
- Metric monitoring ("every N tokens consumed")
- Predictive warnings ("if current trend continues...")

### 3. Transcript Analysis Required

**You could parse transcript file yourself:**

```bash
# PreToolUse hook
#!/bin/bash
TRANSCRIPT_PATH="$1"  # Passed via hook context

# Parse JSONL to count tokens
python3 analyze-token-usage.py "$TRANSCRIPT_PATH"

# If over threshold, warn somehow
if [ $TOKENS -gt 160000 ]; then
  echo '{"systemMessage": "⚠️ Token usage high"}' >&2
fi
```

**Problems with this approach:**

1. Transcript doesn't include current token counts
2. Would need to estimate based on text length
3. No access to cache read tokens
4. No access to subagent tokens in parent context
5. Inaccurate and unreliable

---

## Hook Comparison Table

| Hook | Timing | Token Data? | Proactive? | Use for Detection? |
|------|--------|-------------|------------|-------------------|
| PreToolUse | Before tool | ❌ None | No | ❌ No |
| PostToolUse | After tool | ❌ None | No | ❌ No |
| Stop | Agent done | ❌ None | No | ❌ No |
| SubagentStop | Subagent done | ❌ None | No | ❌ No |
| PreCompact (manual) | User command | ❌ None | No | ❌ No |
| PreCompact (auto) | Context FULL | ❌ None | **Reactive** | ⚠️ Too late |
| SessionStart | Session init | ❌ None | No | ❌ No |
| UserPromptSubmit | Before prompt | ❌ None | No | ❌ No |

**Conclusion:** No hook provides the data or timing needed for proactive token exhaustion detection.

---

## Workarounds (All Have Limitations)

### Option 1: Count Subagent Dispatches (Heuristic)

**Approach:** Track Task tool invocations in PreToolUse hook

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [{
          "type": "command",
          "command": "/path/to/count-subagents.sh"
        }]
      }
    ]
  }
}
```

**count-subagents.sh:**

```bash
#!/bin/bash

# Read hook context
CONTEXT=$(cat)
SESSION_ID=$(echo "$CONTEXT" | jq -r '.session_id')

# Increment counter file
COUNTER_FILE="/tmp/subagent-count-${SESSION_ID}"
COUNT=$(($(cat "$COUNTER_FILE" 2>/dev/null || echo 0) + 1))
echo "$COUNT" > "$COUNTER_FILE"

# Warn if high
if [ "$COUNT" -gt 10 ]; then
  echo '{
    "systemMessage": "⚠️ WARNING: 10+ subagents dispatched. Token usage may be high. Consider using executing-plans mode.",
    "hookSpecificOutput": {
      "additionalContext": "Note: Heavy subagent usage detected. Monitor for token exhaustion."
    }
  }'
else
  echo '{"continue": true}'
fi
```

**Limitations:**

- Heuristic only (doesn't measure actual tokens)
- Doesn't account for varying subagent sizes
- Threshold (10) is arbitrary
- Doesn't track cache reads

### Option 2: Estimate from Transcript Size (Very Rough)

**Approach:** Check transcript file size in UserPromptSubmit

```bash
#!/bin/bash
CONTEXT=$(cat)
TRANSCRIPT=$(echo "$CONTEXT" | jq -r '.transcript_path')

# Rough estimation: 1 character ≈ 0.25 tokens
FILE_SIZE=$(wc -c < "$TRANSCRIPT")
ESTIMATED_TOKENS=$((FILE_SIZE / 4))

if [ "$ESTIMATED_TOKENS" -gt 160000 ]; then
  echo '{
    "systemMessage": "⚠️ Token budget may be near limit",
    "decision": "allow"
  }'
fi
```

**Limitations:**

- Extremely inaccurate (characters ≠ tokens)
- Doesn't account for prompt caching
- Doesn't include subagent tokens
- Transcript includes metadata, not just content
- Unreliable for decision-making

### Option 3: PreCompact Auto-Reactive Warning

**Approach:** When auto-compact fires, warn that limit was reached

```json
{
  "hooks": {
    "PreCompact": [
      {
        "matcher": "auto",
        "hooks": [{
          "type": "command",
          "command": "/path/to/warn-compaction.sh"
        }]
      }
    ]
  }
}
```

**warn-compaction.sh:**

```bash
#!/bin/bash

echo "⚠️ AUTO-COMPACTION TRIGGERED: Token limit reached" >&2
echo "If using subagent-driven-development, consider switching to executing-plans" >&2

# Log to file for tracking
echo "$(date): Auto-compaction triggered in session $SESSION_ID" >> /tmp/compaction.log

# Allow compaction to proceed
exit 0
```

**Limitations:**

- Reactive, not proactive
- Compaction already triggered (too late to prevent)
- Cannot prevent hard-stop if compaction fails
- Only logs the problem, doesn't solve it

---

## What's Actually Needed (Feature Request)

### Proposed: TokenThreshold Hook

**Trigger:** When token usage crosses configured thresholds

**Configuration:**

```json
{
  "hooks": {
    "TokenThreshold": [
      {
        "threshold": 160000,
        "percentage": 80,
        "hooks": [{
          "type": "command",
          "command": "/path/to/token-warning.sh"
        }]
      },
      {
        "threshold": 180000,
        "percentage": 90,
        "hooks": [{
          "type": "command",
          "command": "/path/to/critical-warning.sh"
        }]
      }
    ]
  }
}
```

**Context provided:**

```json
{
  "session_id": "abc123",
  "token_usage": {
    "input_tokens": 5000,
    "output_tokens": 8000,
    "cache_creation_tokens": 2000,
    "cache_read_tokens": 150000,
    "total_consumed": 165000,
    "limit": 200000,
    "remaining": 35000,
    "percentage_used": 82.5
  },
  "subagent_usage": {
    "count": 12,
    "total_tokens": 120000
  },
  "threshold_crossed": 160000,
  "threshold_percentage": 80
}
```

**Decision control:**

```json
{
  "decision": "block",
  "reason": "Token budget nearly exhausted. Switch to executing-plans mode.",
  "systemMessage": "⚠️ 80% token budget used. Recommend checkpoint."
}
```

**Use cases:**

- Warn at 80% usage (160K)
- Block Task tool at 90% usage (180K)
- Force user review before continuing
- Suggest switching execution modes
- Log usage patterns for analysis

### Proposed: TokenBudget Hook Modifier

**Add token data to existing hooks:**

```json
{
  "session_id": "abc123",
  "token_budget": {
    "used": 165000,
    "limit": 200000,
    "remaining": 35000,
    "percentage": 82.5
  },
  // ... existing hook fields
}
```

**Apply to these hooks:**

- PreToolUse (decide whether to allow based on budget)
- UserPromptSubmit (warn user before processing)
- Stop (show token summary when agent finishes)
- SubagentStop (track per-subagent consumption)

---

## Recommendations

### For Immediate Use (Superpowers Plugin)

**None of the current hooks can prevent token exhaustion proactively.**

**Best available option: PreCompact (auto) reactive logging**

```json
{
  "hooks": {
    "PreCompact": [
      {
        "matcher": "auto",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/hooks/warn-auto-compact.sh"
        }]
      }
    ]
  }
}
```

**Purpose:**

- Log when compaction occurs
- Track how often it happens
- Gather data for bug report
- Warn user after the fact

**Does NOT prevent hard-stops** - only logs when they're about to happen.

### For Feature Requests

**File these with Claude Code team:**

1. **TokenThreshold hook** (new hook type)
   - Proactive threshold-based triggers
   - Provides token usage metrics
   - Allows preventive action

2. **Token budget data in existing hooks** (enhancement)
   - Add token usage to PreToolUse context
   - Allow hooks to make informed decisions
   - Enable user-written token management

3. **Subagent token visibility** (transparency)
   - Expose subagent token consumption to parent
   - Include in TokenBudget data
   - Enable accurate monitoring

### For Superpowers Plugin Maintainers

**Document the limitation:**

```markdown
⚠️ **Token Consumption Warning**

The Claude Code hook system does not expose token usage metrics.
This means we cannot proactively warn when approaching token limits.

If using `subagent-driven-development`:
- Monitor for auto-compaction events (indicates high usage)
- Switch to `executing-plans` for large plans (>5 tasks)
- Watch for session slowdowns (may indicate approaching limits)
```

---

## Conclusion

**Direct answer to your question:**

❌ **NO** - There is no hook that can detect incipient token exhaustion at a threshold like 40% remaining (160K used).

**Why:**

- No hooks expose token usage metrics
- PreCompact (auto) only fires when context is ALREADY FULL
- Hooks are event-based, not metric-based
- Token budgets are not visible to hook scripts

**Closest option:**

- **PreCompact (auto)** - Reactive logging when context fills
- **Limitation:** Too late to prevent issues

**What's needed:**

- New **TokenThreshold** hook type
- Token usage data in existing hook contexts
- Proactive threshold-based triggers

**This limitation should be included in your bug report** as evidence that the token consumption issue cannot currently be mitigated through hooks.
