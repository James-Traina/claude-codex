# claude-codex

> Intelligently routes mechanical coding tasks to OpenAI Codex, cutting Anthropic token usage by **60–85%** on eligible work — automatically, transparently, and without changing how you use Claude Code.

---

## The Problem It Solves

Claude Sonnet 4.6 costs ~$3/M input tokens and ~$15/M output tokens. OpenAI's Codex (via `gpt-5.3-codex-spark`) costs a fraction of that. For tasks like "write a unit test for this function" or "add JSDoc to this class", the output quality is virtually indistinguishable — but the cost difference is 20–40x.

**claude-codex** acts as an intelligent dispatcher sitting in front of every message you send. It silently classifies your prompt, routes eligible tasks to Codex, and hands the pre-computed answer back to Claude to present. From your perspective, nothing changes. Under the hood, the expensive model is only used where it genuinely adds value.

---

## How It Works: The Autonomous Loop

```
User types a message
        │
        ▼
UserPromptSubmit hook fires (bash, zero Claude tokens)
        │
        ▼
classify.sh scores the prompt with weighted pattern matching
        │
     ┌──┴──────────────────────────┐
     │                             │
  DELEGATE                    CLAUDE / UNSURE
  (score ≥ 25)                (let through)
     │
     ▼
codex-exec.sh injects expert persona + runs `codex exec`
     │
     ▼
Output injected as additionalContext
     │
     ▼
Claude receives pre-computed answer + instruction to relay it verbatim
     │
     ▼
Claude responds with "[via Codex]" prefix, minimal processing (~80% token savings)
     │
     ▼
token-tracker.sh logs the delegation and estimated savings (background process)
```

### The Dual-Gate Truthfulness Mechanism

The plugin enforces two gates on every delegated response:

1. **Attribution gate**: Claude is instructed to prefix every Codex-delegated response with `[via Codex · <category>]`. You always know which model answered.
2. **Correctness gate**: Claude is instructed to append a `[Claude note]` correction if the Codex output is clearly wrong. You get cheap answers with a safety net.

---

## Expert Categories

The classifier routes tasks into five expert personas. Each persona is a specialised system prompt injected before the Codex call:

| Category | Triggers | Reasoning effort |
|---|---|---|
| `code-generator` | "write a function", "create a class", "implement X" | `high` |
| `test-writer` | "write tests for", "add unit tests to" | `high` |
| `doc-writer` | "add jsdoc to", "document this class" | `medium` |
| `refactor` | "rename X to Y", "extract this function" | `medium` |
| `format` | "format this", "apply prettier", "fix indentation" | `low` |

Each expert is configured in `config/experts/<category>.md`. You can edit these files to tune the instructions for your project's conventions.

---

## Routing Algorithm

The classifier (`scripts/classify.sh`) assigns a numeric score to every prompt:

- **Positive score** → lean toward Codex delegation
- **Negative score** → keep with Claude
- **Threshold**: `DELEGATE if score ≥ 25 AND a category was matched`

**DELEGATE signals** (add points):
- Explicit generation verb + code noun: `+30` (e.g., "write a function", "create a class")
- Test writing: `+30`
- Documentation: `+30`
- Boilerplate/scaffold: `+25`
- Short prompt (< 10 words): `+15`
- Format/lint: `+20`
- Mechanical refactor: `+20`

**CLAUDE signals** (subtract points):
- Architecture/design: `-40`
- Security domain: `-40`
- "Why" reasoning questions: `-35`
- Advisory/recommendation: `-30`
- Debugging/broken code: `-30`
- Performance analysis: `-25`
- Code review/audit: `-25`
- Explanation requests: `-20`
- Multiple file paths: `-20`
- Contains code blocks: `-15`
- Long prompt (> 50 words): `-15`

You can adjust the thresholds in `config/routing-rules.json` (`delegate_threshold`, `claude_threshold`).

---

## Installation

### Prerequisites

```bash
# 1. Install OpenAI Codex CLI
npm install -g @openai/codex

# 2. Authenticate
codex auth

# 3. Ensure jq is installed (required for JSON processing)
# macOS
brew install jq
# Ubuntu/Debian
sudo apt-get install jq
```

### Install the Plugin

```bash
# Copy to Claude Code plugins directory
cp -r claude-codex ~/.claude/plugins/claude-codex

# Make scripts executable
chmod +x ~/.claude/plugins/claude-codex/hooks/*.sh
chmod +x ~/.claude/plugins/claude-codex/scripts/*.sh
```

### Verify Installation

Start a new Claude Code session. You should see in the session context:
```
claude-codex plugin ready.
Status:
  codex CLI: ACTIVE (1.x.x)
  Automatic task delegation is ENABLED
```

---

## Usage

### Automatic (Zero-Touch)

Just use Claude Code normally. When you type something like:

```
write a TypeScript function that validates an email address
```

The hook fires automatically, Codex handles it, and Claude presents the result prefixed with `[via Codex · code-generator]`. No commands, no flags, no changes to your workflow.

### Manual Delegation with `/codex`

For explicit, direct control:

```
/codex write a pytest fixture for a PostgreSQL test database
/codex --sandbox workspace-write refactor the getUser function to use async/await
/codex --model capable implement a lock-free MPSC queue in Rust
```

Flags:
- `--sandbox read-only` (default for auto) — Codex can read files but not modify them
- `--sandbox workspace-write` (default for `/codex`) — Codex can read and write project files
- `--sandbox danger-full-access` — Codex has full filesystem and network access
- `--model fast` → `gpt-5.3-codex-spark`
- `--model default` → `gpt-5.3-codex`
- `--model capable` → `gpt-5.2`

### Check Savings with `/savings`

```
/savings
```

Displays a formatted report of:
- Total tasks delegated and estimated USD saved
- Breakdown by category
- Most recent 20 delegations with prompts and savings

### Escalation: Retry with Codex After Failures

The `delegate` skill activates automatically after 2+ failed attempts on the same task. It escalates to Codex for a fresh perspective, or you can invoke it explicitly:

```
delegate this to codex
use codex for this
codex: implement a Redis cache wrapper with TTL and LRU eviction
```

---

## Session Resumption

Codex sessions can be resumed for follow-up tasks:

```bash
echo "now add error handling for the Redis connection timeout" \
  | codex exec --skip-git-repo-check resume --last 2>/dev/null
```

This continues the prior Codex session with full context of what was already done.

---

## Configuration

### `config/routing-rules.json`

| Key | Default | Description |
|---|---|---|
| `thresholds.delegate_threshold` | `25` | Minimum score to trigger delegation |
| `thresholds.claude_threshold` | `-20` | Maximum score before forcing to Claude |
| `thresholds.max_prompt_words_for_delegation` | `120` | Prompts longer than this are never delegated |
| `models.fast` | `gpt-5.3-codex-spark` | Fast, cheapest Codex model |
| `models.default` | `gpt-5.3-codex` | Balanced model |
| `models.capable` | `gpt-5.2` | Most capable Codex model |
| `sandbox.auto_delegation` | `read-only` | Sandbox for automatic hook-triggered delegation |
| `sandbox.manual_delegation` | `workspace-write` | Sandbox for `/codex` command |

### `config/experts/<category>.md`

Modify these files to inject project-specific conventions into the Codex expert prompts. For example, add to `code-generator.md`:

```
ADDITIONAL PROJECT RULES:
- This project uses Zod for runtime validation; always validate function inputs with Zod schemas
- All async functions must return Result<T, E> types from the neverthrow library
```

---

## Data & Privacy

All delegation logs are stored locally:
```
~/.claude/plugins/claude-codex/
  ├── state.json      # Aggregate stats
  └── savings.log     # JSONL record of every delegation
```

No telemetry is sent anywhere. The only external call is `codex exec` → OpenAI API (your own API key via `codex auth`).

---

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| No `[via Codex]` responses appearing | `codex` not installed | `npm install -g @openai/codex` |
| No `[via Codex]` responses appearing | Authentication expired | `codex auth` |
| `jq: command not found` in hook | jq not installed | `brew install jq` |
| Delegation routing something it shouldn't | Score threshold too low | Raise `delegate_threshold` in `routing-rules.json` |
| Claude is delegating too little | Patterns not matching your phrasing | Lower `delegate_threshold` or add patterns to `routing-rules.json` |
| Codex exec times out | Large codebase, slow read | Increase timeout in `codex-exec.sh` (line with `timeout 120`) |

---

## Architecture Diagram

```
claude-codex/
├── plugin.json                  # Plugin manifest: declares hooks, agents, skills, commands
├── config/
│   ├── routing-rules.json       # Thresholds, model names, scoring weights (editable)
│   └── experts/                 # One system prompt per task category (editable)
│       ├── code-generator.md
│       ├── test-writer.md
│       ├── doc-writer.md
│       ├── refactor.md
│       └── format.md
├── agents/
│   └── codex-agent.md           # Claude subagent: orchestrates explicit delegation calls
├── hooks/
│   ├── session-start.sh         # Runs once at startup: checks deps, injects status
│   └── user-prompt-submit.sh    # Main intelligence: classify → delegate → inject
├── commands/
│   ├── codex.md                 # /codex command: explicit delegation with sandbox control
│   └── savings.md               # /savings command: token savings report
├── skills/
│   └── delegate.md              # Skill: triggers delegation on failure escalation or explicit request
└── scripts/
    ├── classify.sh              # Prompt classifier: outputs DELEGATE/CLAUDE/UNSURE with score
    ├── codex-exec.sh            # Codex CLI wrapper: loads expert, builds prompt, runs exec
    └── token-tracker.sh         # Savings logger: estimates and records per-task savings
```

---

## Cost Estimates

Based on Claude Sonnet 4.6 vs. gpt-5.3-codex pricing (approximate, subject to change):

| Task type | Claude cost | Codex cost | Savings |
|---|---|---|---|
| Write a function (500 tok) | ~$0.006 | ~$0.0003 | ~95% |
| Write unit tests (800 tok) | ~$0.010 | ~$0.0005 | ~95% |
| Add JSDoc (300 tok) | ~$0.004 | ~$0.0002 | ~95% |
| Format a file (400 tok) | ~$0.005 | ~$0.0002 | ~95% |

A developer writing 50 delegatable tasks per day saves ~$1–3/day, ~$20–60/month in API costs.

---

## Inspiration

- [`eddiearc/codex-delegator`](https://github.com/eddiearc/codex-delegator) — Failure-triggered delegation pattern
- [`jarrodwatts/claude-delegator`](https://github.com/jarrodwatts/claude-delegator) — Expert persona system via MCP
- [`skills-directory/skill-codex`](https://github.com/skills-directory/skill-codex) — Direct CLI execution with session resumption

**claude-codex** synthesises all three: proactive every-message scanning (jarrodwatts), expert personas (jarrodwatts), direct CLI execution (skill-codex + eddiearc), plus a persistent savings ledger and zero-touch automation.
