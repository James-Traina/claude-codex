#!/usr/bin/env bash
# user-prompt-submit.sh — Main routing intelligence for claude-codex.
#
# Fires on every user message. Classifies the prompt, and if the task is
# mechanical enough for Codex delegation, pre-computes the answer via
# `codex exec` and injects it as additionalContext so Claude can relay it
# with minimal token usage (~80% savings vs full Claude response).
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

# Parse both fields in a single jq call; use tab as delimiter (safe: neither
# field normally contains tabs).
_PARSED=$(echo "$HOOK_INPUT" | jq -r '(.message // "") + "\t" + (.cwd // "")' 2>/dev/null || printf '\t')
MESSAGE="${_PARSED%%$'\t'*}"
CWD="${_PARSED#*$'\t'}"

# Resolve CWD fallback
if [[ -z "$CWD" ]] || [[ ! -d "$CWD" ]]; then
  CWD="$(pwd)"
fi

# Skip empty or trivially short messages
if [[ -z "$MESSAGE" ]] || [[ ${#MESSAGE} -lt 10 ]]; then
  exit 0
fi

# ── Guard: codex CLI required ─────────────────────────────────────────────────

if ! command -v codex &>/dev/null 2>&1; then
  # codex not installed — pass through silently; session-start.sh already warned
  exit 0
fi

# ── Classify the prompt ────────────────────────────────────────────────────────

# Call scripts via explicit `bash` — no need to check/set executable bit.
CLASSIFY_RESULT=$(bash "${PLUGIN_ROOT}/scripts/classify.sh" "$MESSAGE" 2>/dev/null || echo "UNSURE:classify-error:0")

DECISION=$(echo "$CLASSIFY_RESULT" | cut -d: -f1)
CATEGORY=$(echo "$CLASSIFY_RESULT" | cut -d: -f2)
CONF_SCORE=$(echo "$CLASSIFY_RESULT" | cut -d: -f3)

# Only proceed if decision is DELEGATE
if [[ "$DECISION" != "DELEGATE" ]]; then
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
# verbatim — this is what drives the ~80% token reduction.

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

Estimated token savings from this delegation: ~80% vs. a full Claude response."

# ── Emit JSON ──────────────────────────────────────────────────────────────────

jq -cn \
  --arg ctx "$ADDITIONAL_CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
