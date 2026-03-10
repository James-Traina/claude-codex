#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh"

# Core files
assert_file_exists "$REPO_ROOT/.claude-plugin/plugin.json"
assert_file_exists "$REPO_ROOT/hooks/hooks.json"
assert_file_exists "$REPO_ROOT/hooks/session-start.sh"
assert_file_exists "$REPO_ROOT/hooks/user-prompt-submit.sh"
assert_file_exists "$REPO_ROOT/settings.json"
assert_file_exists "$REPO_ROOT/CLAUDE.md"
assert_file_exists "$REPO_ROOT/README.md"
assert_file_exists "$REPO_ROOT/LICENSE"
assert_file_exists "$REPO_ROOT/CHANGELOG.md"

# Scripts
assert_file_exists "$REPO_ROOT/scripts/classify.sh"
assert_file_exists "$REPO_ROOT/scripts/codex-exec.sh"
assert_file_exists "$REPO_ROOT/scripts/token-tracker.sh"

# Expert personas
assert_file_exists "$REPO_ROOT/scripts/experts/code-generator.md"
assert_file_exists "$REPO_ROOT/scripts/experts/test-writer.md"
assert_file_exists "$REPO_ROOT/scripts/experts/doc-writer.md"
assert_file_exists "$REPO_ROOT/scripts/experts/refactor.md"
assert_file_exists "$REPO_ROOT/scripts/experts/format.md"
assert_file_exists "$REPO_ROOT/scripts/experts/analyst.md"

# Commands
assert_file_exists "$REPO_ROOT/commands/codex.md"
assert_file_exists "$REPO_ROOT/commands/savings.md"

# Agents
assert_file_exists "$REPO_ROOT/agents/codex-agent.md"

# Skills
assert_file_exists "$REPO_ROOT/skills/delegate/SKILL.md"
