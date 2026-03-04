# Changelog

All notable changes to claude-codex are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-03-04

### Added
- Automatic task routing: `UserPromptSubmit` hook classifies every prompt and delegates mechanical tasks to OpenAI Codex
- Weighted pattern classifier (`scripts/classify.sh`) with DELEGATE / CLAUDE / UNSURE decisions
- Budget-aware threshold lowering: as context window fills, more tasks route to Codex
- Six expert persona prompts (`scripts/experts/`) for code-generator, test-writer, doc-writer, refactor, format, analyst categories
- `codex exec` wrapper (`scripts/codex-exec.sh`) with per-category model and reasoning-effort selection
- Token savings tracker (`scripts/token-tracker.sh`) with JSONL log at `~/.claude/plugins/claude-codex/savings.log`
- `/codex` command for manual delegation with optional model override via `CODEX_MODEL_OVERRIDE`
- `/savings` command to display lifetime delegation stats and estimated USD saved
- `codex-agent` subagent for explicit delegation via `delegate` skill
- Routing rules and model config in `settings.json`
