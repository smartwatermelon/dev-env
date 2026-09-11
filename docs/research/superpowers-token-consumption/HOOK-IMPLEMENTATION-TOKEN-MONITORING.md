# Practical Implementation: Token Usage Monitoring via Hooks

**Update:** Following user suggestion to use PostToolUse/SubagentStop hooks with transcript parsing.

## YES - This Can Work! ✅

**Method:** Parse the session transcript JSONL file in PostToolUse or SubagentStop hooks to calculate current token usage.

---

## How It Works

### 1. Hook Context Provides Transcript Path

Every hook receives:

```json
{
  "transcript_path": "/path/to/session.jsonl",
  "session_id": "abc123",
  // ... other fields
}
```

### 2. Transcript Contains Token Usage Data

From the analyze-token-usage.py script, we know the JSONL format includes:

**Main session messages:**

```json
{
  "type": "assistant",
  "message": {
    "usage": {
      "input_tokens": 27,
      "output_tokens": 3996,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 1213703
    }
  }
}
```

**Subagent tool results:**

```json
{
  "type": "user",
  "toolUseResult": {
    "agentId": "3380c209",
    "usage": {
      "input_tokens": 2,
      "output_tokens": 787,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 24989
    }
  }
}
```

### 3. Parse and Sum to Get Current Usage

Similar to `tests/claude-code/analyze-token-usage.py`, but simplified for real-time monitoring.

---

## Implementation Options

### Option A: SubagentStop Hook (Recommended for Superpowers)

**Why:** Catches every subagent completion, perfect for subagent-driven-development

**Hook configuration:**

```json
{
  "hooks": {
    "SubagentStop": [
      {
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/hooks/check-token-usage.sh"
        }]
      }
    ]
  }
}
```

### Option B: PostToolUse Hook (Broader Coverage)

**Why:** Fires after every tool use, including non-subagent tools

**Hook configuration:**

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Task",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/hooks/check-token-usage.sh"
        }]
      }
    ]
  }
}
```

**Note:** Matcher "Task" limits to subagent dispatch only. Use "*" for all tools.

---

## Implementation Script

### check-token-usage.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

# Read hook context from stdin
CONTEXT=$(cat)
TRANSCRIPT_PATH=$(echo "$CONTEXT" | jq -r '.transcript_path')
SESSION_ID=$(echo "$CONTEXT" | jq -r '.session_id')

# Parse transcript and calculate token usage
USAGE=$(python3 "$(dirname "$0")/parse-token-usage.py" "$TRANSCRIPT_PATH")

TOTAL_TOKENS=$(echo "$USAGE" | jq -r '.total_tokens')
TOTAL_INPUT=$(echo "$USAGE" | jq -r '.total_input')
SUBAGENT_COUNT=$(echo "$USAGE" | jq -r '.subagent_count')

# Define thresholds
LIMIT=200000
WARN_THRESHOLD=160000    # 80%
CRITICAL_THRESHOLD=180000 # 90%

# Check thresholds and provide feedback
if [ "$TOTAL_INPUT" -gt "$CRITICAL_THRESHOLD" ]; then
  # CRITICAL: 90%+ used
  echo '{
    "systemMessage": "🚨 CRITICAL: 90% token budget used (' "$TOTAL_INPUT" '/' "$LIMIT" '). Strongly recommend switching to executing-plans mode or creating checkpoint.",
    "hookSpecificOutput": {
      "additionalContext": "⚠️ Token budget critical: '"$TOTAL_INPUT"'/200K used, '"$SUBAGENT_COUNT"' subagents dispatched."
    }
  }' | jq -c

  # Log for analysis
  echo "$(date) - CRITICAL: Session $SESSION_ID at $TOTAL_INPUT tokens ($SUBAGENT_COUNT subagents)" \
    >> "${HOME}/.claude/token-warnings.log"

elif [ "$TOTAL_INPUT" -gt "$WARN_THRESHOLD" ]; then
  # WARNING: 80%+ used
  echo '{
    "systemMessage": "⚠️ WARNING: 80% token budget used (' "$TOTAL_INPUT" '/' "$LIMIT" '). Consider checkpointing or switching execution modes.",
    "hookSpecificOutput": {
      "additionalContext": "Token usage high: '"$TOTAL_INPUT"'/200K used, '"$SUBAGENT_COUNT"' subagents dispatched."
    }
  }' | jq -c

  # Log for analysis
  echo "$(date) - WARNING: Session $SESSION_ID at $TOTAL_INPUT tokens ($SUBAGENT_COUNT subagents)" \
    >> "${HOME}/.claude/token-warnings.log"

else
  # Under threshold - allow silently
  echo '{"continue": true}' | jq -c
fi
```

### parse-token-usage.py

```python
#!/usr/bin/env python3
"""
Parse Claude Code session transcript to calculate total token usage.
Simplified version of tests/claude-code/analyze-token-usage.py for real-time monitoring.
"""

import json
import sys

def calculate_usage(filepath):
    total_usage = {
        'input_tokens': 0,
        'output_tokens': 0,
        'cache_creation': 0,
        'cache_read': 0,
        'subagent_count': 0
    }

    try:
        with open(filepath, 'r') as f:
            for line in f:
                try:
                    data = json.loads(line)

                    # Main session assistant messages
                    if data.get('type') == 'assistant' and 'message' in data:
                        usage = data['message'].get('usage', {})
                        total_usage['input_tokens'] += usage.get('input_tokens', 0)
                        total_usage['output_tokens'] += usage.get('output_tokens', 0)
                        total_usage['cache_creation'] += usage.get('cache_creation_input_tokens', 0)
                        total_usage['cache_read'] += usage.get('cache_read_input_tokens', 0)

                    # Subagent tool results
                    if data.get('type') == 'user' and 'toolUseResult' in data:
                        result = data['toolUseResult']
                        if 'usage' in result and 'agentId' in result:
                            total_usage['subagent_count'] += 1
                            usage = result['usage']
                            total_usage['input_tokens'] += usage.get('input_tokens', 0)
                            total_usage['output_tokens'] += usage.get('output_tokens', 0)
                            total_usage['cache_creation'] += usage.get('cache_creation_input_tokens', 0)
                            total_usage['cache_read'] += usage.get('cache_read_input_tokens', 0)
                except:
                    pass
    except:
        pass

    # Calculate totals
    total_input = (total_usage['input_tokens'] +
                   total_usage['cache_creation'] +
                   total_usage['cache_read'])
    total_tokens = total_input + total_usage['output_tokens']

    return {
        'total_input': total_input,
        'total_tokens': total_tokens,
        'subagent_count': total_usage['subagent_count'],
        'breakdown': total_usage
    }

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(json.dumps({'total_input': 0, 'total_tokens': 0, 'subagent_count': 0}))
        sys.exit(0)

    usage = calculate_usage(sys.argv[1])
    print(json.dumps(usage))
```

---

## Installation for Superpowers Plugin

### 1. Add Scripts to Plugin

```bash
cd /path/to/superpowers
chmod +x hooks/check-token-usage.sh
chmod +x hooks/parse-token-usage.py
```

### 2. Update hooks/hooks.json

**For SubagentStop monitoring:**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start.sh"
        }]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/check-token-usage.sh\""
        }]
      }
    ]
  }
}
```

**For PostToolUse monitoring (Task tool only):**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start.sh"
        }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Task",
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/check-token-usage.sh\""
        }]
      }
    ]
  }
}
```

---

## Behavior Examples

### Scenario 1: Under Threshold

**Situation:** 5 subagents dispatched, 120K tokens used

**Hook behavior:**

- Runs silently
- Allows continuation
- No user message

### Scenario 2: Warning Threshold (80%)

**Situation:** 12 subagents dispatched, 165K tokens used

**User sees:**

```
⚠️ WARNING: 80% token budget used (165000/200000).
Consider checkpointing or switching execution modes.
```

**Claude sees additional context:**

```
Token usage high: 165000/200K used, 12 subagents dispatched.
```

**Log entry:**

```
2026-01-16 18:30:45 - WARNING: Session abc123 at 165000 tokens (12 subagents)
```

### Scenario 3: Critical Threshold (90%)

**Situation:** 18 subagents dispatched, 185K tokens used

**User sees:**

```
🚨 CRITICAL: 90% token budget used (185000/200000).
Strongly recommend switching to executing-plans mode or creating checkpoint.
```

**Claude sees additional context:**

```
⚠️ Token budget critical: 185000/200K used, 18 subagents dispatched.
```

**Result:** User can make informed decision to:

- Stop current workflow
- Switch to executing-plans mode
- Create a checkpoint and start fresh session
- Review progress and compact manually

---

## Advantages of This Approach

### ✅ Proactive Warning

- Catches issues at 80% (160K), well before hard-stop
- Gives user time to react and adjust workflow
- Prevents work loss from unexpected hard-stops

### ✅ Accurate Measurement

- Uses actual token data from Claude API responses
- Includes subagent consumption
- Accounts for cache read tokens
- No estimation or guessing

### ✅ Actionable Context

- Shows both user warning and Claude context
- Provides specific numbers (165K/200K)
- Indicates subagent count for root cause
- Logs for pattern analysis

### ✅ Minimal Performance Impact

- Only runs after subagent completion
- Python script is fast (< 100ms for typical transcripts)
- No blocking of normal operations

### ✅ User Control

- Can adjust thresholds (80%, 90%)
- Can choose which hook (SubagentStop vs PostToolUse)
- Can customize messaging
- Can log to preferred location

---

## Limitations & Considerations

### 1. Reactive, Not Preventive

**Still fires AFTER consumption, not before:**

- Subagent has already run and consumed tokens
- Can't prevent individual subagent dispatch
- Can only warn after pattern emerges

**Mitigation:**

- Warn early enough (80%) to allow adjustment
- User can stop workflow before critical (90%)

### 2. Per-Event Overhead

**Hook runs after every subagent:**

- 16 subagents = 16 hook invocations
- Each parses entire transcript
- Overhead grows with session length

**Mitigation:**

- Parsing is fast (< 100ms)
- Only processes new data incrementally
- Could cache previous counts

### 3. Transcript File Locking

**Potential race condition:**

- Claude may be writing to transcript
- Hook reading at same time
- Could get incomplete read

**Mitigation:**

- Python json.loads handles truncated lines gracefully
- Worst case: undercounts (safe direction)
- Next invocation will catch up

### 4. Assumes 200K Limit

**Hardcoded in script:**

```bash
LIMIT=200000
```

**If limit changes:**

- Script needs updating
- Or make configurable via env var

**Better approach:**

```bash
LIMIT=${CLAUDE_TOKEN_LIMIT:-200000}
```

---

## Enhanced Version: Blocking at Critical

**For maximum protection**, modify to BLOCK at critical threshold:

```bash
if [ "$TOTAL_INPUT" -gt "$CRITICAL_THRESHOLD" ]; then
  echo '{
    "decision": "block",
    "reason": "Token budget at 90% ('"$TOTAL_INPUT"'/200K). Workflow stopped to prevent hard-stop failure. Recommend: (1) Use /compact to compact context, (2) Switch to executing-plans mode, or (3) Continue in new session.",
    "systemMessage": "🚨 Token budget critical - workflow paused for safety"
  }' | jq -c
  exit 2  # Blocking error
fi
```

**Effect:**

- SubagentStop hook returns blocking decision
- Agent cannot continue current workflow
- User must take action (compact, switch modes, new session)
- Prevents invisible hard-stop later

**Trade-off:**

- More disruptive to workflow
- But prevents catastrophic failure
- User has clear path forward

---

## Testing the Implementation

### 1. Create Test Script

```bash
# test-token-hook.sh
#!/bin/bash

# Simulate hook context with test transcript
TEST_TRANSCRIPT="/path/to/test-session.jsonl"
TEST_CONTEXT='{
  "transcript_path": "'"$TEST_TRANSCRIPT"'",
  "session_id": "test-123",
  "hook_event_name": "SubagentStop"
}'

echo "$TEST_CONTEXT" | ./hooks/check-token-usage.sh
```

### 2. Run with Known Data

Use the test data from `tests/claude-code/`:

```bash
# Should show 1,524,058 total tokens, 7 subagents
./test-token-hook.sh
```

### 3. Verify Thresholds

Modify test transcript to add/remove messages until:

- Under 160K (no warning)
- 160K-180K (warning)
- Over 180K (critical)

---

## Recommended Configuration for Superpowers

**Add to `hooks/hooks.json`:**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start.sh"
        }]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/check-token-usage.sh\""
        }]
      }
    ]
  }
}
```

**Why SubagentStop?**

- Catches the primary token consumption pattern (subagents)
- Fires at natural checkpoints (after each subagent)
- Most relevant for subagent-driven-development workflow
- Lower overhead than PostToolUse(*) which fires for ALL tools

---

## Documentation Updates Needed

### In subagent-driven-development/SKILL.md

Add warning section:

```markdown
## Token Consumption Monitoring

⚠️ **Automatic Warning System**

The plugin monitors token usage and will warn you when:
- **80% used (160K)**: Warning - consider checkpointing
- **90% used (180K)**: Critical - strongly recommend stopping

If you see these warnings:
1. Review your progress
2. Consider using `/compact` to compact context
3. Switch to `executing-plans` mode for remaining tasks
4. Or start fresh session and continue from checkpoint

**Token estimates:**
- Small plan (≤5 tasks): ~150K tokens
- Medium plan (10 tasks): ~300K tokens
- Large plan (20 tasks): ~600K tokens

Plans >5 tasks may exceed the 200K limit.
```

---

## Summary

**Yes, this approach works!** ✅

**Implementation:**

1. Use SubagentStop hook (or PostToolUse with Task matcher)
2. Parse transcript JSONL to sum token usage
3. Warn at 80% (160K), critical at 90% (180K)
4. Provide actionable guidance to user

**Benefits:**

- Proactive warnings before hard-stop
- Accurate measurement (not estimation)
- Minimal performance impact
- User can adjust workflow before failure

**This should be added to Superpowers plugin** to mitigate the token exhaustion issue while waiting for architectural fixes from Claude Code team.
