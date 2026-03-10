#!/usr/bin/env bash
set -uo pipefail  # -e omitted: sourced by run-all.sh which must not abort on test failures
source "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh"

# Agents: must have name, description, model, tools
assert_contains "$REPO_ROOT/agents/codex-agent.md" "name: codex-agent" "codex-agent has name"
assert_contains "$REPO_ROOT/agents/codex-agent.md" "description:" "codex-agent has description"
assert_contains "$REPO_ROOT/agents/codex-agent.md" "model: inherit" "codex-agent has model: inherit"
assert_contains "$REPO_ROOT/agents/codex-agent.md" "  - Bash" "codex-agent has YAML list tools"

# Commands: must have name, description, argument-hint or allowed-tools
assert_contains "$REPO_ROOT/commands/codex.md" "name: codex" "codex cmd has name"
assert_contains "$REPO_ROOT/commands/codex.md" "description:" "codex cmd has description"
assert_contains "$REPO_ROOT/commands/codex.md" "allowed-tools:" "codex cmd has allowed-tools"

assert_contains "$REPO_ROOT/commands/savings.md" "name: savings" "savings cmd has name"
assert_contains "$REPO_ROOT/commands/savings.md" "allowed-tools:" "savings cmd has allowed-tools"

# Skills: must have name, description
assert_contains "$REPO_ROOT/skills/delegate/SKILL.md" "name: delegate" "delegate skill has name"
assert_contains "$REPO_ROOT/skills/delegate/SKILL.md" "description:" "delegate skill has description"

# No CSV tools format (should be YAML list)
if grep -q "^tools: " "$REPO_ROOT/agents/codex-agent.md" 2>/dev/null; then
  fail "codex-agent uses CSV tools format (should be YAML list)"
else
  pass "codex-agent uses YAML list for tools"
fi
