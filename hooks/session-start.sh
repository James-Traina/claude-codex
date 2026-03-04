#!/usr/bin/env bash
# session-start.sh — Initialise claude-codex plugin at session start.
#
# Checks dependencies, creates data directories, updates session counter,
# and injects a compact status message as additionalContext for Claude.
#
# Output: JSON { hookSpecificOutput: { hookEventName, additionalContext } }

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLUGIN_DATA_DIR="${HOME}/.claude/plugins/claude-codex"
STATE_FILE="${PLUGIN_DATA_DIR}/state.json"

# ── Ensure data directory exists ──────────────────────────────────────────────

mkdir -p "$PLUGIN_DATA_DIR" 2>/dev/null || true

# ── Check dependencies ────────────────────────────────────────────────────────

CODEX_AVAILABLE=false
CODEX_VERSION=""
if command -v codex &>/dev/null 2>&1; then
  CODEX_AVAILABLE=true
  CODEX_VERSION=$(codex --version 2>/dev/null | head -1 | tr -d '\n' || echo "unknown")
fi

JQ_AVAILABLE=false
if command -v jq &>/dev/null 2>&1; then
  JQ_AVAILABLE=true
fi

# ── Initialise or update state.json ──────────────────────────────────────────

if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" << 'STATE_EOF'
{
  "total_delegated": 0,
  "total_claude": 0,
  "estimated_savings_usd": 0,
  "session_count": 0,
  "codex_available": false,
  "last_delegation": null
}
STATE_EOF
fi

# Read all three stats in a single jq call, then write the updated session count.
# Delegation stats are read before the write since the write only touches session fields.
TOTAL_DELEGATED=0
TOTAL_SAVINGS="0.000000"

if [[ "$JQ_AVAILABLE" == "true" ]]; then
  _STATE=$(jq -r '[.session_count // 0, .total_delegated // 0, .estimated_savings_usd // 0] | map(tostring) | join(" ")' \
    "$STATE_FILE" 2>/dev/null || echo "0 0 0")
  SESSION_COUNT=$(echo "$_STATE" | cut -d' ' -f1)
  TOTAL_DELEGATED=$(echo "$_STATE" | cut -d' ' -f2)
  TOTAL_SAVINGS=$(echo "$_STATE" | cut -d' ' -f3)

  NEW_COUNT=$(( SESSION_COUNT + 1 ))
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)

  jq \
    --argjson count "$NEW_COUNT" \
    --arg codex "$CODEX_AVAILABLE" \
    --arg ts "$TIMESTAMP" \
    '.session_count = $count |
     .codex_available = ($codex == "true") |
     .last_session_start = $ts' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null \
    && mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || true
fi

# ── Build status lines ────────────────────────────────────────────────────────

if [[ "$CODEX_AVAILABLE" == "true" ]]; then
  CODEX_STATUS="ACTIVE (${CODEX_VERSION})"
  DELEGATION_STATUS="Automatic task delegation is ENABLED"
else
  CODEX_STATUS="NOT FOUND"
  DELEGATION_STATUS="Install with: npm install -g @openai/codex && codex auth"
fi

JQ_STATUS="$([ "$JQ_AVAILABLE" = "true" ] && echo "present" || echo "missing — install jq for full functionality")"

# ── Emit JSON ─────────────────────────────────────────────────────────────────

# Use printf to safely build the JSON without jq dependency in the output path
CONTEXT="claude-codex plugin ready.
Status:
  codex CLI: ${CODEX_STATUS}
  jq: ${JQ_STATUS}
  ${DELEGATION_STATUS}
Lifetime stats: ${TOTAL_DELEGATED} tasks delegated, ~\$${TOTAL_SAVINGS} saved in Anthropic tokens.

Routing rules: Tasks classified as mechanical code-generation, test-writing, documentation, refactoring, or formatting are automatically delegated to OpenAI Codex. Complex reasoning, architecture, security, debugging, and advisory tasks are always handled by Claude."

# jq is already checked above; if unavailable emit a minimal safe literal.
if command -v jq &>/dev/null 2>&1; then
  jq -cn --arg ctx "$CONTEXT" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"claude-codex: jq required for full functionality. Install: brew install jq"}}\n'
fi
