#!/usr/bin/env bash
# codex-exec.sh — Execute a task via the OpenAI Codex CLI with expert persona injection.
#
# Usage: codex-exec.sh <category> <prompt> <cwd> [sandbox]
#
#   category : code-generator | test-writer | doc-writer | refactor | format
#   prompt   : the user's original task description
#   cwd      : absolute path to the project working directory
#   sandbox  : read-only (default) | workspace-write | danger-full-access
#
# Outputs the Codex response to stdout.
# Exits non-zero on failure so callers can gracefully fall through to Claude.

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────

CATEGORY="${1:-code-generator}"
USER_PROMPT="${2:-}"
CWD="${3:-$(pwd)}"
SANDBOX="${4:-read-only}"

if [[ -z "$USER_PROMPT" ]]; then
  echo "codex-exec.sh: empty prompt" >&2
  exit 1
fi

# ── Resolve plugin root ────────────────────────────────────────────────────────

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RULES="${PLUGIN_ROOT}/settings.json"

# ── Validate codex CLI ────────────────────────────────────────────────────────

if ! command -v codex &>/dev/null; then
  echo "codex-exec.sh: 'codex' CLI not found. Install: npm install -g @openai/codex && codex auth" >&2
  exit 1
fi

# ── Select model and reasoning effort ────────────────────────────────────────

MODEL="gpt-5.3-codex"
REASONING="high"

if command -v jq &>/dev/null && [[ -f "$RULES" ]]; then
  # Single jq pass: resolve category → model-key → model name, plus reasoning effort.
  _CFG=$(jq -r --arg cat "$CATEGORY" \
    '.category_models[$cat] // "default" as $mk | "\(.models[$mk] // "gpt-5.3-codex") \(.reasoning_effort[$cat] // "high")"' \
    "$RULES" 2>/dev/null || echo "gpt-5.3-codex high")
  MODEL=$(echo "$_CFG" | cut -d' ' -f1)
  REASONING=$(echo "$_CFG" | cut -d' ' -f2)
fi

# Allow the /codex command to override the model via env var
[[ -n "${CODEX_MODEL_OVERRIDE:-}" ]] && MODEL="$CODEX_MODEL_OVERRIDE"

# ── Load expert persona ────────────────────────────────────────────────────────

EXPERT_FILE="${PLUGIN_ROOT}/scripts/experts/${CATEGORY}.md"
EXPERT_CONTEXT=$(cat "$EXPERT_FILE" 2>/dev/null || echo "You are a senior software engineer. Write clean, idiomatic, production-ready code.")

# ── Build full prompt ──────────────────────────────────────────────────────────

# Detect language/framework from CWD
LANG_HINT=""
if [[ -f "${CWD}/package.json" ]]; then
  if [[ -f "${CWD}/tsconfig.json" ]]; then
    LANG_HINT="TypeScript/Node.js project"
  else
    LANG_HINT="JavaScript/Node.js project"
  fi
elif [[ -f "${CWD}/pyproject.toml" ]] || [[ -f "${CWD}/setup.py" ]] || [[ -f "${CWD}/requirements.txt" ]]; then
  LANG_HINT="Python project"
elif [[ -f "${CWD}/go.mod" ]]; then
  LANG_HINT="Go project"
elif [[ -f "${CWD}/Cargo.toml" ]]; then
  LANG_HINT="Rust project"
elif [[ -f "${CWD}/pom.xml" ]] || [[ -f "${CWD}/build.gradle" ]]; then
  LANG_HINT="Java project"
fi

FULL_PROMPT="${EXPERT_CONTEXT}

---
PROJECT CONTEXT:
Working directory: ${CWD}
${LANG_HINT:+Language/framework: ${LANG_HINT}}
Files are available for reading to understand existing patterns before generating code.

TASK:
${USER_PROMPT}"

# ── Execute Codex ──────────────────────────────────────────────────────────────

# Timeout: 120s for codex exec (generous, complex codebases need time to read)
TIMEOUT_CMD=""
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout 120"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout 120"
fi

OUTPUT=$(
  cd "$CWD" 2>/dev/null || true
  $TIMEOUT_CMD codex exec \
    -m "$MODEL" \
    --config "model_reasoning_effort=${REASONING}" \
    --sandbox "$SANDBOX" \
    --skip-git-repo-check \
    "$FULL_PROMPT" 2>/dev/null
) || {
  EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 124 ]] || [[ $EXIT_CODE -eq 137 ]]; then
    echo "codex-exec.sh: codex exec timed out after 120s (exit code ${EXIT_CODE})" >&2
  else
    echo "codex-exec.sh: codex exec failed with exit code ${EXIT_CODE}" >&2
  fi
  exit "$EXIT_CODE"
}

if [[ -z "$OUTPUT" ]]; then
  echo "codex-exec.sh: codex returned empty output" >&2
  exit 1
fi

echo "$OUTPUT"
