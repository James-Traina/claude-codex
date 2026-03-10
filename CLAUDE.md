# claude-codex Plugin

Routes mechanical coding tasks — test writing, documentation, formatting, code generation — to OpenAI Codex instead of Claude, cutting token costs on work that doesn't need deep reasoning. Fully automatic and transparent.

## Architecture

**Every prompt → classify.sh → DELEGATE or CLAUDE → codex-exec.sh → token-tracker.sh**

The `UserPromptSubmit` hook runs `classify.sh` on every prompt. The classifier outputs weighted scores for delegate/claude signals and makes a DELEGATE, CLAUDE, or UNSURE decision. For DELEGATE, `codex-exec.sh` selects an expert persona from `scripts/experts/`, runs `codex exec`, and injects the result as `additionalContext`. Attribution (`[via Codex · category]`) and correctness gate instructions are included automatically.

## Component Inventory

| Type | Name | Purpose |
|------|------|---------|
| Hook | SessionStart | Init directories, update session counter, inject status |
| Hook | UserPromptSubmit | Classify prompt and delegate to Codex if appropriate |
| Agent | `codex-agent` | Explicit Codex delegation via the `delegate` skill |
| Skill | `delegate` | Protocol for routing tasks to Codex; handles @codex requests |
| Command | `/codex` | Manually delegate a task with optional sandbox and model override |
| Command | `/savings` | Show lifetime delegation stats and estimated USD saved |

## File Structure

```
.claude-plugin/plugin.json    Plugin manifest
hooks/
  hooks.json                  Hook definitions (SessionStart, UserPromptSubmit)
  session-start.sh            Init hook
  user-prompt-submit.sh       Classification + delegation hook
scripts/
  classify.sh                 Weighted pattern classifier (DELEGATE/CLAUDE/UNSURE)
  codex-exec.sh               Codex CLI wrapper with expert persona injection
  token-tracker.sh            JSONL savings log writer
  experts/
    code-generator.md         Expert persona for code generation tasks
    test-writer.md            Expert persona for test writing
    doc-writer.md             Expert persona for documentation
    refactor.md               Expert persona for refactoring
    format.md                 Expert persona for formatting/linting
    analyst.md                Expert persona for analysis tasks
agents/
  codex-agent.md              Subagent for explicit Codex delegation
skills/
  delegate/SKILL.md           Delegation skill definition
commands/
  codex.md                    /codex command
  savings.md                  /savings command
settings.json                 Routing rules: thresholds, models, delegate/claude signal patterns
```

## Configuration (settings.json)

| Key | Purpose |
|-----|---------|
| `thresholds.delegate_threshold` | Score >= this → delegate to Codex (default: 20) |
| `thresholds.claude_threshold` | Score <= this → keep with Claude (default: -20) |
| `thresholds.min_prompt_words` | Minimum words to consider for delegation (default: 3) |
| `thresholds.max_prompt_words_for_delegation` | Long prompts stay with Claude (default: 200) |
| `models` | Model IDs for fast/default/capable tiers |
| `category_models` | Per-category model tier assignment |
| `reasoning_effort` | Per-category reasoning effort (low/medium/high) |
| `budget_aware` | Context-window-aware threshold lowering |

Routing signal patterns (DELEGATE/CLAUDE weights) are hardcoded in `scripts/classify.sh` — edit them there. They are not configurable via settings.json.

## Testing

Run: `bash .tests/run-all.sh`

Test reports go to `.tests/reports/` (gitignored).

## Evals

Automated quality evals for delegation trigger accuracy live in `.evals/`. Run manually — not part of CI.

## Critical Invariants

- **Attribution is non-negotiable** — delegated responses must be prefixed with `[via Codex · category]`. Never remove this from hooks or prompts.
- **Correctness gate** — Claude is instructed to append `[Claude note]` if Codex output is wrong. Do not remove this instruction.
- **Budget-aware thresholds** — as context window fills, `delegate_threshold` lowers automatically. Changing threshold logic in classify.sh must stay consistent with settings.json.
- **Version bumping required for updates** — Claude Code caches plugins; users only get updates if `version` in `.claude-plugin/plugin.json` is incremented.
- **Flat repo structure** — `.claude-plugin/plugin.json` must stay at repo root.
- **savings.log location** — `~/.claude/plugins/claude-codex/savings.log` (JSONL). Don't change this path without updating both token-tracker.sh and the /savings command.

## Development

### Adding a new expert category
1. Create `scripts/experts/category-name.md` with the system prompt
2. Add the category to `settings.json` under `category_models` and `reasoning_effort`
3. Add delegate signal patterns to `settings.json` under `delegate_signals`
4. Update `codex-exec.sh` to handle the new category name

### Adjusting routing thresholds
Edit `settings.json`. Increase `delegate_threshold` to delegate less; decrease to delegate more. Run `.evals/` suite to verify accuracy.

## Domain Keywords

Agent Delegation, Budget Optimization, Code Generation, Code Routing, Codex, Cost Reduction, Documentation Generation, Formatting, OpenAI, Refactoring, Task Classification, Test Writing, Token Savings.
