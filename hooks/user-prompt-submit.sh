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

set -uo pipefail

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

# Parse fields separately — tab-delimiter approach breaks if message contains tabs.
MESSAGE=$(echo "$HOOK_INPUT" | jq -r '.message // ""' 2>/dev/null || true)
CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // ""' 2>/dev/null || true)
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || true)

# Resolve CWD fallback
if [[ -z "$CWD" ]] || [[ ! -d "$CWD" ]]; then
  CWD="$(pwd)"
fi

# Skip empty or trivially short messages
if [[ -z "$MESSAGE" ]] || [[ ${#MESSAGE} -lt 10 ]]; then
  exit 0
fi

# ── Budget-aware threshold ─────────────────────────────────────────────────────
# Transcript size is a reliable proxy for session token usage. As the session
# grows, we lower the delegate threshold so more tasks get offloaded to Codex,
# conserving the remaining Claude budget.

DELEGATE_THRESHOLD_OVERRIDE=""
if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
  TRANSCRIPT_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d '[:space:]' || echo 0)

  RULES_FILE="${PLUGIN_ROOT}/config/routing-rules.json"
  if command -v jq &>/dev/null && [[ -f "$RULES_FILE" ]]; then
    _BUDGET=$(jq -r '
      .budget_aware as $b |
      if $b.enabled then
        [$b.transcript_size_thresholds.medium_bytes // 200000,
         $b.transcript_size_thresholds.high_bytes   // 350000,
         $b.delegate_thresholds.medium_usage         // 12,
         $b.delegate_thresholds.high_usage           // 4] | map(tostring) | join(" ")
      else "disabled" end' "$RULES_FILE" 2>/dev/null || echo "200000 350000 12 4")

    if [[ "$_BUDGET" != "disabled" ]]; then
      MEDIUM_BYTES=$(echo "$_BUDGET" | cut -d' ' -f1)
      HIGH_BYTES=$(echo "$_BUDGET"   | cut -d' ' -f2)
      MEDIUM_THRESH=$(echo "$_BUDGET" | cut -d' ' -f3)
      HIGH_THRESH=$(echo "$_BUDGET"   | cut -d' ' -f4)

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

DECISION=$(echo "$CLASSIFY_RESULT" | cut -d: -f1)
CATEGORY=$(echo "$CLASSIFY_RESULT" | cut -d: -f2)
CONF_SCORE=$(echo "$CLASSIFY_RESULT" | cut -d: -f3)

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
