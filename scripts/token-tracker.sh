#!/usr/bin/env bash
# token-tracker.sh — Log delegation decisions and estimate token savings.
#
# Usage: token-tracker.sh <prompt> <category> <codex_output> [decision]
#
# Appends a JSONL record to ~/.claude/plugins/claude-codex/savings.log
# Reads state from ~/.claude/plugins/claude-codex/state.json
#
# Token cost estimates (per 1M tokens, as of 2026-03):
#   Claude Sonnet 4.6:  $3.00 input  / $15.00 output
#   gpt-5.3-codex:      $0.15 input  / $0.60 output  (approx, fast model)
#   Savings ratio ≈ 94-97% per delegated task

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────

PROMPT="${1:-}"
CATEGORY="${2:-unknown}"
CODEX_OUTPUT="${3:-}"
DECISION="${4:-DELEGATE}"

# ── Paths ──────────────────────────────────────────────────────────────────────

PLUGIN_DATA_DIR="${HOME}/.claude/plugins/claude-codex"
SAVINGS_LOG="${PLUGIN_DATA_DIR}/savings.log"
STATE_FILE="${PLUGIN_DATA_DIR}/state.json"

mkdir -p "$PLUGIN_DATA_DIR"

# ── Initialise state.json if absent ──────────────────────────────────────────

if [[ ! -f "$STATE_FILE" ]]; then
  printf '{"total_delegated":0,"total_claude":0,"estimated_savings_usd":0,"session_count":0,"codex_available":false}\n' > "$STATE_FILE"
fi

# ── Token estimation ──────────────────────────────────────────────────────────
# Rough heuristic: 1 token ≈ 4 chars (English/code average)

char_to_tokens() {
  local chars="${1:-0}"
  echo $(( chars / 4 + 1 ))
}

PROMPT_CHARS=${#PROMPT}
OUTPUT_CHARS=${#CODEX_OUTPUT}

PROMPT_TOKENS=$(char_to_tokens "$PROMPT_CHARS")
OUTPUT_TOKENS=$(char_to_tokens "$OUTPUT_CHARS")

# Claude Sonnet 4.6 cost (USD per token)
CLAUDE_INPUT_COST_PER_TOKEN="0.000003"   # $3 / 1M
CLAUDE_OUTPUT_COST_PER_TOKEN="0.000015"  # $15 / 1M

# gpt-5.3-codex cost (approximate)
CODEX_INPUT_COST_PER_TOKEN="0.00000015"  # $0.15 / 1M
CODEX_OUTPUT_COST_PER_TOKEN="0.0000006"  # $0.60 / 1M

# Compute all four cost values in a single awk call (avoids 4 subprocess forks).
read -r CLAUDE_COST CODEX_COST SAVINGS SAVINGS_PCT < <(awk "BEGIN {
  claude = ($PROMPT_TOKENS * $CLAUDE_INPUT_COST_PER_TOKEN) + ($OUTPUT_TOKENS * $CLAUDE_OUTPUT_COST_PER_TOKEN)
  codex  = ($PROMPT_TOKENS * $CODEX_INPUT_COST_PER_TOKEN)  + ($OUTPUT_TOKENS * $CODEX_OUTPUT_COST_PER_TOKEN)
  diff   = claude - codex
  sav    = (diff < 0 ? 0 : diff)
  pct    = (claude > 0) ? ((claude - codex) / claude * 100) : 0
  printf \"%.6f %.6f %.6f %.1f\n\", claude, codex, sav, pct
}")

# ── Write JSONL log record (DELEGATE only — CLAUDE decisions skip the log) ────

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)

if [[ "$DECISION" == "DELEGATE" ]] || [[ "$DECISION" == "MANUAL_DELEGATE" ]]; then
  PROMPT_PREVIEW=$(echo "$PROMPT" | head -c 120 | tr '\n' ' ')

  if command -v jq &>/dev/null; then
    jq -cn \
      --arg ts "$TIMESTAMP" \
      --arg decision "$DECISION" \
      --arg category "$CATEGORY" \
      --arg preview "$PROMPT_PREVIEW" \
      --argjson prompt_tokens "$PROMPT_TOKENS" \
      --argjson output_tokens "$OUTPUT_TOKENS" \
      --arg claude_cost "$CLAUDE_COST" \
      --arg codex_cost "$CODEX_COST" \
      --arg savings "$SAVINGS" \
      --arg savings_pct "$SAVINGS_PCT" \
      '{
        timestamp:     $ts,
        decision:      $decision,
        category:      $category,
        prompt_preview: $preview,
        prompt_tokens:  $prompt_tokens,
        output_tokens:  $output_tokens,
        claude_cost_usd: ($claude_cost | tonumber),
        codex_cost_usd:  ($codex_cost  | tonumber),
        savings_usd:     ($savings     | tonumber),
        savings_pct:     ($savings_pct | tonumber)
      }' >> "$SAVINGS_LOG"
  else
    # jq not available — write minimal CSV-style record
    echo "${TIMESTAMP},${DECISION},${CATEGORY},${PROMPT_TOKENS},${OUTPUT_TOKENS},${SAVINGS}" >> "${SAVINGS_LOG}.csv"
  fi
fi

# ── Update aggregate state.json ───────────────────────────────────────────────

if command -v jq &>/dev/null; then
  CURRENT=$(cat "$STATE_FILE")

  if [[ "$DECISION" == "DELEGATE" ]] || [[ "$DECISION" == "MANUAL_DELEGATE" ]]; then
    # Read and update in one jq pass — avoids two separate jq reads of CURRENT.
    echo "$CURRENT" | jq \
      --arg savings "$SAVINGS" \
      --arg ts "$TIMESTAMP" \
      '.total_delegated = (.total_delegated // 0) + 1 |
       .estimated_savings_usd = ((.estimated_savings_usd // 0) + ($savings | tonumber)) |
       .last_delegation = $ts' > "${STATE_FILE}.tmp" \
      && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  else
    # Non-delegated task: increment total_claude for accurate delegation-rate tracking.
    echo "$CURRENT" | jq \
      '.total_claude = (.total_claude // 0) + 1' > "${STATE_FILE}.tmp" \
      && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
fi
