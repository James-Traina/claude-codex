#!/usr/bin/env bash
# 06-classify-integration — Verify classify.sh routing decisions.
#
# These tests exercise the actual classifier script (no network calls).
# They verify the weighted-scoring logic routes prompts correctly to
# DELEGATE:<category> or CLAUDE.

SCRIPT="$REPO_ROOT/scripts/classify.sh"

# ── Helper ──────────────────────────────────────────────────────────────────

# Run classifier; returns "DECISION:CATEGORY" only (drops score).
classify() {
  bash "$SCRIPT" "$1" 2>/dev/null | cut -d: -f1-2
}

assert_delegate() {
  local prompt="$1" expected_cat="$2" label="$3"
  local result
  result=$(bash "$SCRIPT" "$prompt" 2>/dev/null)
  local decision category
  IFS=: read -r decision category _ <<< "$result"
  if [[ "$decision" == "DELEGATE" && "$category" == "$expected_cat" ]]; then
    pass "classify DELEGATE:$expected_cat — $label"
  else
    fail "classify expected DELEGATE:$expected_cat, got $result — $label"
  fi
}

assert_claude() {
  local prompt="$1" label="$2"
  local decision
  decision=$(bash "$SCRIPT" "$prompt" 2>/dev/null | cut -d: -f1)
  if [[ "$decision" == "CLAUDE" ]]; then
    pass "classify CLAUDE — $label"
  else
    fail "classify expected CLAUDE, got $decision — $label"
  fi
}

# ── DELEGATE cases ────────────────────────────────────────────────────────

assert_delegate \
  "write unit tests for the parseDate function" \
  "test-writer" \
  "test-writing prompt"

assert_delegate \
  "add JSDoc comments to all exported functions in src/api.ts" \
  "doc-writer" \
  "JSDoc documentation prompt"

assert_delegate \
  "generate a Redis cache wrapper class with TTL and LRU eviction" \
  "code-generator" \
  "code generation prompt"

assert_delegate \
  "refactor the getUserById function to use async/await" \
  "refactor" \
  "refactoring prompt"

assert_delegate \
  "format" \
  "format" \
  "bare 'format' word"

assert_delegate \
  "lint" \
  "format" \
  "bare 'lint' word"

# ── CLAUDE cases ──────────────────────────────────────────────────────────

assert_claude \
  "why does my app crash when I call getUserById with null" \
  "why-question / debugging"

assert_claude \
  "should we use Redux or Zustand for this project's state management?" \
  "architecture decision"

assert_claude \
  "review this PR for security vulnerabilities before I merge it" \
  "security review"

assert_claude \
  "explain how the auth middleware in src/middleware/auth.js actually works" \
  "explain-how question"

assert_claude \
  "my tests are failing with cannot read properties of undefined — help me debug" \
  "debug help"
