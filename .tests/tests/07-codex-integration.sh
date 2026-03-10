#!/usr/bin/env bash
# 07-codex-integration — End-to-end tests that invoke the real Codex CLI.
#
# Skipped by default. To run:
#   CODEX_INTEGRATION_TESTS=1 bash .tests/run-all.sh 07
#
# These tests:
#   1. Call codex-exec.sh directly with a minimal prompt
#   2. Pipe a delegatable message through the full user-prompt-submit.sh pipeline
#
# Cost note: each run makes 1–2 real Codex API calls (fast model, read-only sandbox).

if [[ "${CODEX_INTEGRATION_TESTS:-0}" != "1" ]]; then
  skip "codex-exec: skipped (set CODEX_INTEGRATION_TESTS=1 to run)"
  skip "user-prompt-submit pipeline: skipped (set CODEX_INTEGRATION_TESTS=1 to run)"
  return 0 2>/dev/null || exit 0
fi

CODEX_EXEC="$REPO_ROOT/scripts/codex-exec.sh"
HOOK="$REPO_ROOT/hooks/user-prompt-submit.sh"

# ── Test 1: codex-exec.sh returns non-empty output ───────────────────────────

output=$(
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  bash "$CODEX_EXEC" "code-generator" \
    "Output only the single word CODEX_OK on one line with no other text." \
    "$REPO_ROOT" \
    "read-only" 2>/dev/null
) || true

if [[ -n "$output" ]]; then
  pass "codex-exec.sh: returned non-empty output"
else
  fail "codex-exec.sh: returned empty output (codex CLI may not be authenticated)"
fi

# ── Test 2: user-prompt-submit.sh outputs valid JSON for a delegatable prompt ─

HOOK_INPUT=$(jq -cn \
  --arg msg "write a bash function called hello_world that echoes Hello World" \
  --arg cwd "$REPO_ROOT" \
  '{"message":$msg,"cwd":$cwd,"transcript_path":""}')

hook_output=$(
  echo "$HOOK_INPUT" | \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  bash "$HOOK" 2>/dev/null
) || true

if [[ -z "$hook_output" ]]; then
  fail "user-prompt-submit.sh: no output (codex may have failed or classify returned non-DELEGATE)"
else
  # Must be valid JSON
  if echo "$hook_output" | jq -e '.hookSpecificOutput.additionalContext' &>/dev/null; then
    pass "user-prompt-submit.sh: output is valid JSON with additionalContext"
  else
    fail "user-prompt-submit.sh: output is not valid JSON — got: ${hook_output:0:120}"
  fi

  # Must contain the [via Codex] attribution marker
  ctx=$(echo "$hook_output" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || true)
  if echo "$ctx" | grep -q "CLAUDE-CODEX AUTOMATIC DELEGATION"; then
    pass "user-prompt-submit.sh: additionalContext contains delegation header"
  else
    fail "user-prompt-submit.sh: additionalContext missing delegation header"
  fi

  # Routing decision must be DELEGATE (not UNSURE/CLAUDE)
  if echo "$ctx" | grep -q "DELEGATED"; then
    pass "user-prompt-submit.sh: routing decision is DELEGATE"
  else
    fail "user-prompt-submit.sh: routing decision not DELEGATE in context"
  fi
fi
