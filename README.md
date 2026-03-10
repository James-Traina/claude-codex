# claude-codex

Routes mechanical coding tasks to OpenAI Codex, cutting Anthropic token usage by 60–85% on eligible work. You don't change how you use Claude Code.

---

## The problem it solves

Claude Sonnet 4.6 costs ~$3/M input tokens and ~$15/M output tokens. OpenAI's Codex (via `gpt-5.3-codex`) costs a fraction of that. For tasks like "write a unit test for this function" or "add JSDoc to this class", the output quality is virtually indistinguishable, but the cost difference is 20–40x.

The tricky part is figuring out *which* tasks qualify. "Write unit tests for getUserById" clearly does. "Why is my authentication middleware slow?" clearly doesn't — it needs reasoning, context, and judgment. Most tasks fall somewhere in between, and classifying them correctly in real time (before any tokens are spent) requires a scoring approach that weighs competing signals.

That's what this plugin does. A bash hook fires on every message before Claude processes it. If the task scores high enough on mechanical-work signals and low enough on reasoning signals, it gets routed to Codex instead. Claude receives the pre-computed answer and relays it, spending maybe 5% of the tokens it would have used computing the same answer itself.

---

## How it works

### The full pipeline

```
User types a message
        │
        ▼
UserPromptSubmit hook fires (bash, zero Claude tokens)
        │
        ├── Parse hook JSON input (message, cwd, session_id)
        │
        ├── Check budget-aware threshold (is context window filling up?)
        │
        ├── Check codex CLI availability (if missing: fall through to Claude)
        │
        ├── classify.sh scores the prompt with weighted pattern matching
        │
        │     DELEGATE (score ≥ 25 AND category matched)
        │     ├── codex-exec.sh picks expert persona for the category
        │     ├── Detects project language from CWD (package.json, go.mod, etc.)
        │     ├── Builds full prompt: expert persona + project context + task
        │     ├── Runs `codex exec` with model + reasoning effort + sandbox
        │     │       (120s timeout; falls through to Claude on failure)
        │     ├── token-tracker.sh logs the delegation (fire-and-forget)
        │     └── Hook returns additionalContext with Codex output + relay instructions
        │
        │     CLAUDE (score ≤ -20, or UNSURE between -20 and 25)
        │     └── Fall through: Claude handles the task normally
        │
        ▼
Claude receives additionalContext (if DELEGATE) or the raw message (otherwise)
        │
        ▼
[DELEGATE path]: Claude reads the Codex answer and relays it with [via Codex · category] prefix
[CLAUDE path]:   Claude answers normally
```

### Why the hook approach works

Claude Code's `UserPromptSubmit` hook runs *before* the AI model is invoked. It receives the raw message as JSON and can inject `additionalContext` — extra text prepended to what Claude sees.

Classification runs entirely in bash, spending zero tokens. Codex execution runs outside the Claude inference loop. Claude's only job on delegated tasks is to clean up Markdown and add the attribution prefix: roughly 50 output tokens instead of 500–2000.

If the hook fails for any reason (codex not installed, timeout, network error), it exits without output. Claude Code treats an empty hook response as "no intervention" and falls through to Claude normally.

---

## The routing algorithm

### Scoring mechanics

`scripts/classify.sh` assigns a numeric score to every prompt. Positive scores push toward delegation; negative scores push toward Claude.

```
DELEGATE if: score ≥ 25  AND  a category was matched
CLAUDE   if: score ≤ -20
UNSURE   otherwise: Claude handles it (conservative fallback)
```

The UNSURE zone between -20 and 25 intentionally keeps borderline tasks with Claude. Routing a debugging task to Codex wastes money on a bad answer; keeping a test-writing task with Claude just costs a bit more. When in doubt, the system keeps things with Claude.

### Positive signals (add to score)

| Signal | Score | Why this weight |
|---|---|---|
| Explicit verb + code noun: "write a function", "create a class", "implement a handler" | +30 | Both intent and target are named — hard to misinterpret |
| "add/implement" + code noun | +25 | Same intent, slightly weaker verb group |
| Test writing: "write tests for", "generate unit tests for" | +30 | Test writing is pure mechanical work; model quality difference is minimal |
| Documentation: "add jsdoc to", "document this class" | +25–30 | Adding docstrings doesn't require understanding business logic |
| Short prompt (< 10 words) | +15 | Terse prompts rarely carry the implicit context that needs Claude |
| 10–20 word prompt | +8 | Still tends toward mechanical |
| Format/lint: "format this", "apply prettier" | +20 | Deterministic transformation, no judgment needed |
| Mechanical refactor: "rename X to Y", "extract this function" | +20 | Structural change, not semantic |
| Boilerplate/scaffold/CRUD | +25 | Pure generation from a known template |
| Code conversion: "convert this to TypeScript" | +20 | Translation between languages is mechanical |
| Type annotations: "add types to", "annotate with TypeScript types" | +22 | Inference from existing code without design decisions |
| Second-opinion / sanity check | +20–25 | Explicit escalation request |

### Negative signals (subtract from score)

| Signal | Score | Why this keeps tasks with Claude |
|---|---|---|
| Architecture/design: "how should I structure", "design pattern" | -40 | No correct answer; requires judgment about constraints |
| Security domain: "authentication", "vulnerability", "csrf", "injection" | -35 to -40 | Security mistakes are expensive; Claude's caution matters here |
| "Why" questions | -35 | Causal reasoning; Codex explains *how*, not *why* |
| Advisory/recommendation: "should I", "what's the best way" | -30 | Opinion and tradeoff questions need Claude's judgment |
| Debugging/broken code: "not working", "exception", "stack trace" | -30 | Diagnosis requires understanding execution state, not generation |
| Performance analysis: "bottleneck", "memory leak", "optimize" | -25 | Requires profiling context and runtime understanding |
| Code review/audit: "review my code", "find issues in" | -25 | Holistic analysis, not generation |
| Explanation requests: "explain", "how does this work" | -20 | Understanding transfer needs Claude's depth |
| "How do/can/would I X" framing | -20 | Interrogative framing usually means guidance-seeking, not just code |
| 3+ file paths in prompt | -20 | Multi-file context tasks are harder to delegate |
| Contains code blocks (```) | -15 | Pasted code means the user wants analysis, not fresh generation |
| Long prompt (> 50 words) | -10 | Specificity reduces Codex's advantage |

### How signals combine

"write a TypeScript function that validates an email address" scores:

- +30 for "write ... function" (code-generator pattern)
- +8 for being 9 words (short-prompt bonus)
- **Total: +38 → DELEGATE:code-generator**

"write a function to validate emails but also explain why you chose this regex approach" scores:

- +30 for "write ... function"
- +8 short-ish prompt
- -20 for "explain" signal
- -10 length penalty
- **Total: ~+8 → UNSURE → Claude handles it**

The "explain why" modifier flips the routing, and that's intentional. If you want both code and explanation, you want Claude.

---

## Expert personas

When a task is delegated, `codex-exec.sh` selects a system prompt from `scripts/experts/<category>.md` and prepends it to the task. Each file gives Codex a focused role with specific output conventions.

The `test-writer` persona tells Codex to:
- Write tests using the framework it can detect in the project (Jest, pytest, Go testing, etc.)
- Follow AAA structure (Arrange/Act/Assert)
- Include edge cases and error paths
- Skip prose explanations and just write the tests

The `code-generator` persona asks for production-ready code: proper error handling, idiomatic style for the detected language, no placeholders.

Edit these files freely. Adding project-specific rules (your validation libraries, naming conventions, error handling patterns) significantly improves output quality. Codex reads the files in your project before responding, so it can infer a lot already — the persona is there to tell it which conventions matter.

### Language detection

`codex-exec.sh` checks the working directory for project marker files and appends a language hint to the expert persona:

| File found | Detected as |
|---|---|
| `package.json` + `tsconfig.json` | TypeScript/Node.js |
| `package.json` (no tsconfig) | JavaScript/Node.js |
| `pyproject.toml`, `setup.py`, `requirements.txt` | Python |
| `go.mod` | Go |
| `Cargo.toml` | Rust |
| `pom.xml`, `build.gradle` | Java |

---

## The relay mechanism

When Codex returns output, `user-prompt-submit.sh` wraps it in a structured block and injects it as `additionalContext`. Claude sees something like:

```
=== CLAUDE-CODEX AUTOMATIC DELEGATION ===
Routing decision : DELEGATED (confidence score: 38)
Expert category  : code-generator
Sandbox used     : read-only (no files were modified)
Source           : OpenAI Codex via 'codex exec'

CODEX OUTPUT:
[...the actual Codex-generated code...]
=== END DELEGATION ===

CRITICAL SYSTEM INSTRUCTION:
This task was automatically pre-delegated to OpenAI Codex to conserve Anthropic tokens.
You MUST follow these rules in your response:

1. RELAY the Codex output above to the user — formatted cleanly in Markdown.
2. PREFIX your entire response with: **[via Codex · code-generator]**
3. ADD NO additional explanation, preamble, or rephrasing beyond light Markdown formatting.
...
```

The instructions keep Claude's response to roughly 50 output tokens of overhead. Claude formats and presents the answer rather than computing it, which is where the ~95% savings come from on delegated tasks.

### The correctness gate

Claude is always given an escape hatch: if the Codex output is factually wrong, incomplete, or contains a syntax error, Claude appends a corrective note prefixed with `> [Claude note]:`. You don't get silently wrong output from a delegation.

---

## Budget-aware threshold lowering

As a Claude Code session grows, the context window fills up. Longer context means more expensive inference. `user-prompt-submit.sh` detects this and automatically lowers the delegation threshold, so mechanical tasks that normally score 18 (just below 25) start getting delegated when context pressure rises.

Two detection methods, in priority order:

1. `CLAUDE_CONTEXT_WINDOW_USAGE_FRACTION` — Claude Code injects this env var (0.0–1.0) into hook processes. Above 40% usage, the threshold drops to 12. Above 70%, it drops to 4 — almost everything mechanical gets delegated.

2. Transcript file size — when the env var is absent, the hook measures the transcript file's byte size as a proxy. Above 200 KB drops the threshold to 12; above 350 KB drops it to 4.

Configure all these values in `settings.json` under `budget_aware`.

---

## Session startup

Every time you open Claude Code, `session-start.sh` runs before any messages are processed. It:

1. Creates `~/.claude/plugins/claude-codex/` if it doesn't exist
2. Checks whether `codex` and `jq` are installed
3. Increments the session counter in `state.json`
4. Injects a compact status message so Claude knows the plugin is active

If codex isn't installed, the status message tells you exactly what to run. If jq isn't installed, the hook warns you but degrades gracefully: classification still runs (classify.sh doesn't need jq), but budget-aware thresholds and savings tracking won't work.

---

## Savings tracking

Every delegated task gets logged to `~/.claude/plugins/claude-codex/savings.log` as a JSONL entry:

```json
{"ts":"2026-03-09T14:23:01Z","category":"code-generator","prompt":"write a getUserById function","savings_usd":0.006}
```

The savings estimate is based on approximate token counts and current pricing (Claude Sonnet 4.6 vs gpt-5.3-codex). It's an estimate, not a billing statement, but the order of magnitude is accurate.

`state.json` holds aggregate totals:

```json
{
  "total_delegated": 47,
  "total_claude": 203,
  "estimated_savings_usd": 0.32,
  "session_count": 12
}
```

Run `/savings` to see a formatted report.

---

## Installation

### Prerequisites

```bash
# 1. Install OpenAI Codex CLI
npm install -g @openai/codex

# 2. Authenticate (links your OpenAI account)
codex auth

# 3. Install jq (required for JSON processing in hooks)
# macOS
brew install jq
# Ubuntu/Debian
sudo apt-get install jq
```

`codex auth` opens a browser window to authenticate with your OpenAI account. The CLI uses your existing OpenAI API billing — the same account you'd use for ChatGPT or the API.

### Install the plugin

Inside Claude Code, run each command separately:

```
/plugin marketplace add James-Traina/science-plugins
```

```
/plugin install claude-codex@science-plugins
```

### Verify

Start a new Claude Code session. The session context should include:

```
claude-codex plugin ready.
Status:
  codex CLI: ACTIVE (1.x.x)
  Automatic task delegation is ENABLED
```

If codex shows as NOT FOUND, the CLI isn't installed or isn't on your PATH. Check with `which codex` in your terminal.

---

## Usage

### Automatic

Just use Claude Code normally. When you type:

```
write a TypeScript function that validates an email address
```

The hook fires automatically, Codex handles it, and Claude presents the result prefixed with `[via Codex · code-generator]`. Nothing changes about how you work.

### Manual delegation with `/codex`

For explicit control with sandbox and model options:

```
/codex write a pytest fixture for a PostgreSQL test database
/codex --sandbox workspace-write refactor the getUser function to use async/await
/codex --model capable implement a lock-free MPSC queue in Rust
```

`/codex` runs with `workspace-write` sandbox by default, meaning Codex can read and write your files. Automatic delegation uses `read-only` — it generates code for you to paste rather than making changes directly.

Sandbox options:
- `--sandbox read-only` — Codex reads files for context but makes no changes
- `--sandbox workspace-write` — Codex can read and write project files
- `--sandbox danger-full-access` — Full filesystem and network access

Model options:
- `--model fast` or `--model default` → `gpt-5.3-codex` (used for most categories)
- `--model capable` → `gpt-5.2` (more capable, slower, costs more)

### Savings report with `/savings`

```
/savings
```

Shows lifetime delegation stats, estimated USD saved, breakdown by category, and your 20 most recent delegations.

### Escalation via the `delegate` skill

The `delegate` skill triggers when you explicitly route work to Codex:

```
delegate this to codex
use codex for this
codex: implement a Redis cache wrapper with TTL and LRU eviction
```

It also activates after 2+ failed attempts on the same task. When Claude is stuck in a loop, escalating to a different model often breaks the pattern.

---

## Session resumption

Codex maintains session state between calls. You can continue a prior session explicitly:

```bash
echo "now add error handling for the Redis connection timeout" \
  | codex exec --skip-git-repo-check resume --last 2>/dev/null
```

This passes the follow-up task to Codex with full context of what it already did, so it doesn't re-read files or re-generate code that's already written.

---

## Configuration

### `settings.json`

```json
{
  "thresholds": {
    "delegate_threshold": 25,
    "claude_threshold": -20,
    "min_prompt_words": 3,
    "max_prompt_words_for_delegation": 200
  }
}
```

- `delegate_threshold` — minimum score to route to Codex. Raise to delegate less; lower to delegate more.
- `claude_threshold` — scores at or below this always go to Claude, regardless of delegate_threshold.
- `max_prompt_words_for_delegation` — prompts over this length bypass the classifier entirely and stay with Claude.

The *patterns* that generate scores are hardcoded in `scripts/classify.sh`, not in `settings.json`. Only threshold values are configurable here. To add or adjust routing patterns, edit `classify.sh` directly.

```json
{
  "budget_aware": {
    "enabled": true,
    "context_window_thresholds": {
      "medium_fraction": 0.4,
      "high_fraction": 0.7
    },
    "transcript_size_thresholds": {
      "medium_bytes": 200000,
      "high_bytes": 350000
    },
    "delegate_thresholds": {
      "medium_usage": 12,
      "high_usage": 4
    }
  }
}
```

At `high_usage` threshold of 4, almost any prompt with a positive category signal gets delegated.

### `scripts/experts/<category>.md`

These are the system prompts injected before each Codex call. Edit them to add project-specific conventions:

```markdown
## ADDITIONAL PROJECT RULES:
- This project uses Zod for all runtime validation; always validate function inputs
- All async functions must return Result<T, E> types from the neverthrow library
- Database queries go through the repository layer at src/repositories/
```

Codex reads your project files before responding, so it picks up a lot from context. The persona file is where you put the conventions that aren't obvious from the code.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No `[via Codex]` responses | `codex` not installed | `npm install -g @openai/codex` |
| No `[via Codex]` responses | Authentication expired | `codex auth` |
| `jq: command not found` in hook output | jq not installed | `brew install jq` |
| Tasks routing to Claude that seem mechanical | Score threshold too high | Lower `delegate_threshold` in `settings.json` |
| Tasks routing to Codex that seem complex | Score threshold too low | Raise `delegate_threshold` in `settings.json` |
| Codex exec times out | Large codebase, slow read | Raise the timeout in `codex-exec.sh` (the `timeout 120` call) |
| Wrong category selected | Category signal fired incorrectly | Check `classify.sh` — add negative signals or adjust weights |

### Debugging the classifier

Test any prompt directly without a full session:

```bash
bash scripts/classify.sh "write a TypeScript function that validates email"
# → DELEGATE:code-generator:38

bash scripts/classify.sh "why is my auth middleware causing a memory leak"
# → CLAUDE:security-auth:-55
```

---

## Architecture reference

```
claude-codex/
├── .claude-plugin/plugin.json   Plugin manifest (version, author, homepage)
├── settings.json                Thresholds, models, budget config
├── agents/
│   └── codex-agent.md           Explicit delegation subagent
├── hooks/
│   ├── hooks.json               Hook event definitions (SessionStart, UserPromptSubmit)
│   ├── session-start.sh         Init: check deps, update session counter, inject status
│   └── user-prompt-submit.sh    Main pipeline: classify → delegate → inject additionalContext
├── commands/
│   ├── codex.md                 /codex command: explicit delegation with sandbox/model control
│   └── savings.md               /savings command: lifetime token savings report
├── skills/
│   └── delegate/SKILL.md        Delegation skill: @codex requests, second-opinion escalation
└── scripts/
    ├── classify.sh              Weighted pattern classifier (outputs DELEGATE/CLAUDE/UNSURE)
    ├── codex-exec.sh            Codex CLI wrapper with expert persona + language detection
    ├── token-tracker.sh         JSONL savings log writer
    └── experts/
        ├── analyst.md
        ├── code-generator.md
        ├── test-writer.md
        ├── doc-writer.md
        ├── refactor.md
        └── format.md
```

Data stored at `~/.claude/plugins/claude-codex/`:
- `state.json` — aggregate stats (total_delegated, estimated_savings_usd, session_count)
- `savings.log` — JSONL record of every delegation

The only external network call is `codex exec` → OpenAI API, using your own API key. No data is sent anywhere else.

---

## Cost estimates

Based on Claude Sonnet 4.6 vs. gpt-5.3-codex pricing (approximate):

| Task type | Claude cost | Codex cost | Savings |
|---|---|---|---|
| Write a function (500 tok) | ~$0.006 | ~$0.0003 | ~95% |
| Write unit tests (800 tok) | ~$0.010 | ~$0.0005 | ~95% |
| Add JSDoc (300 tok) | ~$0.004 | ~$0.0002 | ~95% |
| Format a file (400 tok) | ~$0.005 | ~$0.0002 | ~95% |

50 delegatable tasks per day works out to roughly $1–3/day saved. The latency improvement on long sessions is sometimes the bigger win — Codex tends to return faster than Claude when the context window is heavily loaded.

---

## Extending the plugin

### Adding a new expert category

1. Create `scripts/experts/your-category.md` with the system prompt
2. Add the category under `category_models` and `reasoning_effort` in `settings.json`
3. Add delegate signal patterns to `scripts/classify.sh` (follow the existing pattern blocks)
4. Update the category fallback in `codex-exec.sh` if needed

### Adjusting routing patterns

The delegate signals section in `classify.sh` starts around line 70; Claude signals around line 190. Each block is a bash `matches_pattern` call using ERE syntax.

```bash
bash scripts/classify.sh "your test prompt"
```

Then verify against the eval suite:

```bash
bash .evals/run-evals.sh
```

---

## Inspiration

- [`eddiearc/codex-delegator`](https://github.com/eddiearc/codex-delegator) — failure-triggered delegation pattern
- [`jarrodwatts/claude-delegator`](https://github.com/jarrodwatts/claude-delegator) — expert persona system via MCP
- [`skills-directory/skill-codex`](https://github.com/skills-directory/skill-codex) — direct CLI execution with session resumption

## Updating

```
/plugin update claude-codex
```

## License

MIT. See [LICENSE](LICENSE).
