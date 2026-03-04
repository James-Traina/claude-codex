#!/usr/bin/env bash
# user-prompt-submit.sh — Main routing intelligence for claude-codex.
#
# Fires on every user message. Classifies the prompt, and if the task is
# mechanical enough for Codex delegation, pre-computes the answer via
# `codex exec` and injects it as additionalContext so Claude can relay it
# with minimal token usage (~95% savings vs full Claude response).
#
# Input (stdin):  JSON  { message, cwd, session_id, transcript_path }
# Output (stdout): JSON { hookSpecificOutput: { hookEventName, additionalContext } }
#   OR empty / non-zero exit to silently fall through to Claude.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── Guard: jq required ────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null 2>&1; then
  # Without jq we cannot parse the hook input — silently pass through to Claude
  exit 0
fi

# ── Read and parse hook input ─────────────────────────────────────────────────

HOOK_INPUT=$(cat 2>/dev/null || true)

if [[ -z "$HOOK_INPUT" ]]; then
  exit 0
fi

# Parse all fields in one jq call — avoids forking three subprocesses on every message.
# @sh quoting makes the eval safe for any message content including quotes and newlines.
eval "$(echo "$HOOK_INPUT" | jq -r '
  "MESSAGE=" + (.message // "" | @sh),
  "CWD=" + (.cwd // "" | @sh),
  "TRANSCRIPT_PATH=" + (.transcript_path // "" | @sh)
' 2>/dev/null || echo 'MESSAGE="" CWD="" TRANSCRIPT_PATH=""')"

# Resolve CWD fallback
if [[ -z "$CWD" ]] || [[ ! -d "$CWD" ]]; then
  CWD="$(pwd)"
fi

# Skip empty or trivially short messages
if [[ -z "$MESSAGE" ]] || [[ ${#MESSAGE} -lt 10 ]]; then
  exit 0
fi

# ── Budget-aware threshold ─────────────────────────────────────────────────────
# As the session consumes more of the context window, lower the delegate
# threshold so mechanical tasks increasingly route to Codex, preserving what
# remains for work only Claude can do.
#
# Detection priority:
#   1. CLAUDE_CONTEXT_WINDOW_USAGE_FRACTION — injected by Claude Code (0.0–1.0)
#   2. Transcript byte size — reliable proxy when env var is absent

DELEGATE_THRESHOLD_OVERRIDE=""
RULES_FILE="${PLUGIN_ROOT}/config/routing-rules.json"
if [[ -f "$RULES_FILE" ]]; then
  # Single jq call reads both fraction and byte thresholds to avoid branching jq.
  _BUDGET=$(jq -r '
    .budget_aware as $b |
    if $b.enabled then
      [$b.context_window_thresholds.medium_fraction // 0.4,
       $b.context_window_thresholds.high_fraction   // 0.7,
       $b.transcript_size_thresholds.medium_bytes   // 200000,
       $b.transcript_size_thresholds.high_bytes     // 350000,
       $b.delegate_thresholds.medium_usage          // 12,
       $b.delegate_thresholds.high_usage             // 4] | map(tostring) | join(" ")
    else "disabled" end' "$RULES_FILE" 2>/dev/null || echo "0.4 0.7 200000 350000 12 4")

  if [[ "$_BUDGET" != "disabled" ]]; then
    read -r MEDIUM_FRAC HIGH_FRAC MEDIUM_BYTES HIGH_BYTES MEDIUM_THRESH HIGH_THRESH <<< "$_BUDGET"

    if [[ -n "${CLAUDE_CONTEXT_WINDOW_USAGE_FRACTION:-}" ]]; then
      # Exact signal: context window fraction provided by Claude Code.
      if awk "BEGIN { exit !(${CLAUDE_CONTEXT_WINDOW_USAGE_FRACTION} > ${HIGH_FRAC}) }"; then
        DELEGATE_THRESHOLD_OVERRIDE="$HIGH_THRESH"
      elif awk "BEGIN { exit !(${CLAUDE_CONTEXT_WINDOW_USAGE_FRACTION} > ${MEDIUM_FRAC}) }"; then
        DELEGATE_THRESHOLD_OVERRIDE="$MEDIUM_THRESH"
      fi
    elif [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
      # Proxy: transcript file size correlates with cumulative token usage.
      TRANSCRIPT_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d '[:space:]' || echo 0)
      if [[ $TRANSCRIPT_BYTES -gt $HIGH_BYTES ]]; then
        DELEGATE_THRESHOLD_OVERRIDE="$HIGH_THRESH"
      elif [[ $TRANSCRIPT_BYTES -gt $MEDIUM_BYTES ]]; then
        DELEGATE_THRESHOLD_OVERRIDE="$MEDIUM_THRESH"
      fi
    fi
  fi
fi

# ── Guard: codex CLI required ─────────────────────────────────────────────────

if ! command -v codex &>/dev/null 2>&1; then
  # codex not installed — pass through silently; session-start.sh already warned
  exit 0
fi

# ── Classify the prompt ────────────────────────────────────────────────────────

# Call scripts via explicit `bash` — no need to check/set executable bit.
# Pass DELEGATE_THRESHOLD_OVERRIDE so budget-aware logic flows through to classify.sh.
CLASSIFY_RESULT=$(DELEGATE_THRESHOLD_OVERRIDE="${DELEGATE_THRESHOLD_OVERRIDE}" \
  bash "${PLUGIN_ROOT}/scripts/classify.sh" "$MESSAGE" 2>/dev/null || echo "UNSURE:classify-error:0")

IFS=: read -r DECISION CATEGORY CONF_SCORE <<< "$CLASSIFY_RESULT"

# Only proceed if decision is DELEGATE; otherwise count the task as Claude-handled.
if [[ "$DECISION" != "DELEGATE" ]]; then
  bash "${PLUGIN_ROOT}/scripts/token-tracker.sh" "$MESSAGE" "${CATEGORY:-unknown}" "" "CLAUDE" &>/dev/null &
  exit 0
fi

# ── Execute via Codex ──────────────────────────────────────────────────────────

# Run in a subshell so failure doesn't abort the hook; fall through on any error
CODEX_OUTPUT=""
CODEX_EXIT=0
CODEX_OUTPUT=$(
  bash "${PLUGIN_ROOT}/scripts/codex-exec.sh" "$CATEGORY" "$MESSAGE" "$CWD" "read-only" 2>/dev/null
) || CODEX_EXIT=$?

# If Codex failed or returned nothing, silently fall through to Claude
if [[ $CODEX_EXIT -ne 0 ]] || [[ -z "$CODEX_OUTPUT" ]]; then
  exit 0
fi

# ── Log the savings (fire-and-forget, never block on this) ───────────────────

bash "${PLUGIN_ROOT}/scripts/token-tracker.sh" "$MESSAGE" "$CATEGORY" "$CODEX_OUTPUT" "DELEGATE" &>/dev/null &

# ── Build additionalContext ────────────────────────────────────────────────────
#
# The injected context instructs Claude to relay the pre-computed answer
# verbatim — this is what drives the ~95% token reduction.

ADDITIONAL_CONTEXT="=== CLAUDE-CODEX AUTOMATIC DELEGATION ===
Routing decision : DELEGATED (confidence score: ${CONF_SCORE})
Expert category  : ${CATEGORY}
Sandbox used     : read-only (no files were modified)
Source           : OpenAI Codex via 'codex exec'

CODEX OUTPUT:
${CODEX_OUTPUT}
=== END DELEGATION ===

CRITICAL SYSTEM INSTRUCTION:
This task was automatically pre-delegated to OpenAI Codex to conserve Anthropic tokens.
You MUST follow these rules in your response:

1. RELAY the Codex output above to the user — formatted cleanly in Markdown.
2. PREFIX your entire response with: **[via Codex · ${CATEGORY}]**
3. ADD NO additional explanation, preamble, or rephrasing beyond light Markdown formatting.
4. NEVER claim you wrote or computed this answer yourself.
5. EXCEPTION: If the Codex output is factually incorrect, incomplete, or contains a syntax error,
   you MAY append a brief corrective note prefixed with:
   > **[Claude note]:** <your correction>
6. EXCEPTION: If the Codex output is \"NO_CHANGES_NEEDED\" for a formatting task, relay that message directly.

Estimated token savings from this delegation: ~95% vs. a full Claude response."

# ── Emit JSON ──────────────────────────────────────────────────────────────────

jq -cn \
  --arg ctx "$ADDITIONAL_CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
