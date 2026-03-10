---
name: savings
description: Show a summary of token savings achieved by claude-codex delegation.
allowed-tools: Read, Bash
---

# /savings — Token Savings Report

Display a summary of how many tasks have been delegated to Codex and the estimated Anthropic token savings this session and lifetime.

## Read the Data

Run:
```bash
cat "${HOME}/.claude/plugins/claude-codex/state.json" 2>/dev/null || echo "{}"
```

Also read the most recent 20 log entries:
```bash
tail -20 "${HOME}/.claude/plugins/claude-codex/savings.log" 2>/dev/null || echo ""
```

## Format the Report

Present a concise report in this format:

```
## claude-codex Savings Report

**Lifetime totals**
- Tasks delegated to Codex: <total_delegated>
- Estimated Anthropic tokens saved: ~<calculated>
- Estimated USD saved: ~$<estimated_savings_usd>
- Sessions using claude-codex: <session_count>

**Recent delegations** (last 20)
| Time | Category | Prompt preview | Saved (USD) |
|------|----------|----------------|-------------|
| ... | ... | ... | ... |

**Routing rates** (from log)
- Delegation rate: <delegated / total> %
- Most common category: <most frequent category>

---
_Estimates based on Claude Sonnet 4.6 vs. gpt-5.3-codex pricing._
_Actual savings may vary based on response length and prompt complexity._
```

## Calculate Derived Metrics

If the savings log exists, calculate from the JSONL entries:
```bash
# Count delegations per category
jq -r '.category' "${HOME}/.claude/plugins/claude-codex/savings.log" 2>/dev/null \
  | sort | uniq -c | sort -rn | head -5
```

## If No Data

If the state file doesn't exist or shows zero delegations:

```
## claude-codex Savings Report

No delegations recorded yet.

The plugin automatically delegates tasks when the Codex CLI is available.
Run: npm install -g @openai/codex && codex auth

Or use /codex <task> to delegate manually.
```

## Tips Section

Always end the report with:

```
**To maximise savings:**
- Phrase generation tasks explicitly: "write a function that..." triggers automatic delegation
- Use `/codex <task>` for direct delegation when the automatic routing misses a task
- Check routing decisions in: ~/.claude/plugins/claude-codex/savings.log
```
